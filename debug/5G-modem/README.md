# 5G/LTE Modem 接手指南

> 給接手這個專案、不熟 5G modem 的人。從零講到能跑通。
> 看完 30 分鐘內你應該能：知道這是什麼、知道怎麼測、知道遇到問題去哪查。

---

## 0. TL;DR — 我現在到底要做什麼

```bash
# Target 板子上：
./mbim.sh
```

撥號通了 → 完工。
撥號沒通 → 往下看 §7「排查流程」對症下藥。

```
新人接手 →  README.md
   ├─ 想深入軟體層  →  software-stack.md
   ├─ 想查完整技術  →  modem-guide.md
   ├─ 想看 debug 過程  →  NOTES.md
   ├─ 想看 EDL 復原  →  REPORT.md
   └─ 想升級 BSP  →  bsp-prompt.md
```

---

## 1. 這個資料夾在幹嘛

平台 SA8775P (LeMans) + QLI 1.8 上，把 **M.2 B-Key 5G modem** 打通的所有檔案、筆記、工具。

主用模組是 **Quectel EM060K-GL**(USB VID:PID `2c7c:030b`,走 MBIM)。實測 mbim.sh 對其他 MBIM-composition 模組也通(MV31W / EM7595 都驗證過)。**真正不通的是當 modem 韌體走 QMI composition(例如 AIW-356/FM160),要改用 qmi 工具**。完整測過的模組對照表在 §7.5。

---

## 2. 5G/LTE Modem 是什麼

不是「網卡」，是個**獨立的 SoC**，內含：

```
┌─────────────────────────────────────┐
│  Modem M.2 卡 (e.g. EM060K-GL)      │
│                                     │
│  ┌──────────┐    ┌─────────────┐   │
│  │ Baseband │←──→│ RF 收發 + PA│←──→ 天線
│  │ (跑自己的 │    └─────────────┘   │
│  │ 高通 RTOS)│           ↕            │
│  └──────────┘    ┌─────────────┐   │
│       ↕           │   SIM 卡    │   │
│  ┌──────────┐    └─────────────┘   │
│  │ DDR/Flash│                       │
│  └──────────┘                       │
└──────────────┬──────────────────────┘
               │ USB (透過 M.2 B-Key)
               ▼
            Host (SA8775P)
```

對 host 來說：插上去 → `lsusb` 看到一個 USB device → 跑 driver 接它 → 開始講話。

---

## 3. 硬體層 — 天線、Pin、訊號鏈

### 3.1 天線（最少 2 根，最好 4 根）

| 天線 | 必要？ | 用途 |
|---|---|---|
| **Main**（主收發） | ✅ 一定要 | 主要 TX + RX |
| **Diversity**（分集接收） | ⚠️ 強烈建議 | 降噪、提高訊號穩定度。少了它收訊會明顯變爛 |
| **GNSS** | 視需求 | GPS / GLONASS / Galileo / 北斗 |
| **MIMO 4×4 第 3/4 根** | 高速場景 | 5G NR 全速時用，沒它也能跑 |

天線用 **U.FL / IPEX MHF1** 接頭接到 M.2 卡上的 receptacle。50Ω impedance。

### 3.2 M.2 B-Key 關鍵 Pin（共 75 根，只列必管的）

| Pin | 訊號 | 方向 | 預期狀態 | 為什麼重要 |
|---|---|---|---|---|
| 2/4/70/72/74 | VCC (3.7V) | host→modem | always on | 主供電 |
| **6** | `FULL_CARD_POWER_OFF#` | host→modem | **HIGH** | LOW 整張卡關機 |
| **8** | `W_DISABLE1#` | host→modem | **HIGH** | LOW 進飛航模式（無線關） |
| **26** | `W_DISABLE2#` | host→modem | HIGH | GNSS 開關 |
| **67** | `RESET#` | host→modem | HIGH | LOW = 強制 reset |
| 25 | `DPR` (SAR) | host→modem | HIGH | LOW = 降 TX 功率 (SAR sensor) |
| 7/9 | USB 2.0 D+/D- | bi | | 撥號用這對（除非 USB 3.0） |
| 29/31/35/37 | USB 3.0 SS Tx/Rx | bi | | 全速時走這 |
| 36/30/32/34/66 | SIM 1 (VCC/RST/CLK/DATA/DET) | bi | | SIM 介面 |
| 50 | `PERST#` | host→modem | HIGH | PCIe 模式才用 |

⚠️ **Pin 6 跟 Pin 8 是最常見的「裝起來不動」原因**。本專案之前就在這吃過虧（preset pin 沒拉對導致 modem 卡 EDL）。詳見 [`NOTES.md`](./NOTES.md) §「Hardware GPIO 排查清單」。

### 3.3 boot 起來會經歷的硬體狀態

```
T0   power-on (VCC 上電)
     ↓
T+ms FULL_CARD_POWER_OFF# = HIGH  → modem 開始 boot
     ↓
T+s  modem internal boot (RTOS / RF init / SIM init)
     ↓
T+~20-40s USB enumerate (host 看到 lsusb device)
     ↓
T+...    multiple USB interface 出現 (composition)
     ↓
T+...    SIM ready → registration → idle
```

冷開機到 USB 出現大約 20~40 秒是正常 cellular modem 行為。

---

## 4. Modem 在 Linux 上看起來怎樣

modem 是個「**多面向的 USB 裝置**」。一張卡會同時跑出多個 USB interface，每個做不同事。

### 4.1 EM060K-GL 的 USB composition (MBIM mode)

跑 `cat /sys/bus/usb/devices/2-1.4/bNumInterfaces` 會看到 6+ 個。各 interface 與對應 driver：

| Interface | Class | Linux driver | 出現為 | 給誰用 |
|---|---|---|---|---|
| 1.0 | ff/ff/30 | `option` | `/dev/ttyUSB0` | NMEA (GPS 串口) |
| 1.1 | ff/00/40 | `option` | `/dev/ttyUSB1` | DM (diagnostic) |
| 1.2 | ff/ff/40 | `option` | `/dev/ttyUSB2` | **AT 主 port** |
| 1.3 | ff/ff/40 | `option` | `/dev/ttyUSB3` | AT 副 port |
| 1.8 | **02/0e/00** | **`cdc_mbim`** | `/dev/cdc-wdm0` | **MBIM 控制通道** |
| 1.9 | 0a/00/02 | `cdc_mbim` | `wwan0` 網卡 | **MBIM data 通道** |

對 host 來說真正會用到的就三個：
- **`/dev/ttyUSB2`** — 下 AT 命令
- **`/dev/cdc-wdm0`** — MBIM 撥號（透過 mbimcli / mbim-network）
- **`wwan0`** — 撥通後 IP 流量走這

### 4.2 為什麼分這麼多 interface？

3GPP 規定一張 cellular modem 至少要能：
- 收 AT 命令做設定
- 走 packet data（MBIM 或 QMI 或 PPP）
- 輸出 GPS NMEA
- 提供 DM/diag port 給 vendor 工具

所以 modem 韌體把這些功能拆成獨立的 USB interface，host 各自接 driver。

### 4.3 異常 composition (要警覺!)

如果你看到 modem 只出 **1 個 interface + 2 個 bulk EP + class FF/FF/FF**：

```
bNumInterfaces=1
bNumEndpoints=2 (Bulk IN + Bulk OUT)
class=FF/subclass=FF/protocol=FF
```

**這是 Qualcomm Sahara/EDL 緊急燒錄模式**，韌體壞了。要走 QFirehose / qdl 重灌韌體。本專案之前就遇過，過程在 [`REPORT.md`](./REPORT.md)。

---

## 5. AT 命令是什麼

AT (ATtention) 是 1981 年 Hayes modem 留下來的命令格式，所有 cellular modem 都還支援。透過 ttyUSB AT port 下，就能設定 modem。

### 5.1 怎麼下

```bash
# Target 板子上：
stty -F /dev/ttyUSB2 115200 raw -echo
printf 'AT\r\n' > /dev/ttyUSB2 &
cat /dev/ttyUSB2 &
# → 應該看到 OK
```

或用更好的工具：`microcom -t 5000 /dev/ttyUSB2` (但 QLI 沒裝)。

### 5.2 常用 AT 命令一覽

| 命令 | 用途 |
|---|---|
| `AT` | 測試是否回應 (回 OK) |
| `ATI` | modem 資訊（廠牌、型號、firmware） |
| `AT+CPIN?` | SIM 解鎖狀態 |
| `AT+CSQ` | 訊號強度 (0-31) |
| `AT+COPS?` | 已註冊電信商 |
| `AT+CREG?` | network registration 狀態 |
| `AT+CGDCONT=1,"IP","apn"` | 設 PDP context (APN) |
| `AT+QCFG="usbcfg"` | (Quectel) 看當前 USB composition |
| `AT+QCFG="usbnet",0/1/2` | (Quectel) 切換 ECM/MBIM/RmNet |
| `AT+CFUN=1` | 開機全功能 / `=4` 飛航 / `=0` 關 |

完整列表查 modem 廠商的 AT command manual。

### 5.3 透過 ModemManager 下 AT（不用自己開 serial）

```bash
mmcli -m 0 --command='AT+CSQ'
# (需要 MM 開 debug-mode 才能下任意 AT)
```

---

## 6. 撥號的「7 層」流程

每打通一張 modem，從插下去到能上網要依序通過 7 層：

```
L0  USB enumerate ────────────────  lsusb 看得到？
L1  Driver bind ──────────────────  /dev/cdc-wdm0 / ttyUSB* 出現？
L2  AT 控制通道 ───────────────────  AT → OK ?
L3  SIM 解鎖 ──────────────────────  AT+CPIN? → READY
L4  Network registration ─────────  AT+CREG? → 0,1 (home) 或 0,5 (roaming)
L5  Packet service attach ────────  LTE PS attached
L6  Bearer / PDP context ─────────  MBIM CONNECT 或 QMI WDS Start
L7  Data plane real packets ──────  wwan0 有真實 IP + ping 通
```

「**SIM 認得到但撥不上網**」= 卡 L6 / L7。

詳細排查指令對照表看 [`modem-guide.md`](./modem-guide.md) §6 跟 §8。

---

## 7. 怎麼測撥號

### 7.1 主要工具:`mbim.sh`

**只對「合作型 MBIM」模組有效**(EM060K-GL 已驗證)。原本以為通吃所有 MBIM,實測 Telit 系 / Fibocom 系都不行,請先對 §7.5 表確認 modem 屬哪一派再決定要跑哪支。

```bash
# Target 板子上:
./mbim.sh
```

內部做:釋放 MM → mbim-network 撥號 → udhcpc 取 IP → ping 驗證 → 還原 MM。

⚠️ **腳本卡死 = 協議對不上**。`/dev/cdc-wdm0` 跟 `wwan0` 不論 MBIM 或 QMI 都會建,光看 device node **無法**判斷。要看 interface class:
- `02/0e` + `0a` (CDC standard) → MBIM → 用 mbim.sh
- `ff/ff/50` 或類似 vendor-class + `qmi_wwan` bind → QMI → 用 qmicli / qmi-network

判斷指令:
```bash
for i in /sys/bus/usb/devices/*/2*:1.*; do
  [ -d "$i" ] || continue
  printf "%s class=%s/%s/%s drv=%s\n" \
    "$(basename $i)" \
    "$(cat $i/bInterfaceClass)" \
    "$(cat $i/bInterfaceSubClass)" \
    "$(cat $i/bInterfaceProtocol)" \
    "$(ls $i/driver/module 2>/dev/null | head -1 || echo NONE)"
done
```

詳細工作原理跟為何走 `mbim-network` 不是手刻 `mbimcli`,看 [`software-stack.md`](./software-stack.md) §6。

### 7.2 想直接斷線

```bash
mbim-network /dev/cdc-wdm0 stop
ip link set wwan0 down
```

### 7.3 想換 APN

```bash
APN=internet.iot ./mbim.sh
```

### 7.4 對比工具:`mm-connect.sh`

走 ModemManager 路徑,**目前在 QLI 1.8 上撥不通**(因 MM 沒含 MBIM 支援、沒 pppd),但腳本內有 `preflight_bsp_check()` 會告訴你缺什麼。等 BSP 升級到含 MM-MBIM + pppd 後這條會自動 work。

### 7.5 測過的 modem 對照表(2026-05-29 實測)

> **重點**:不是看品牌,是看 modem 韌體當前的 USB composition(MBIM vs QMI)。同款模組換韌體 / 切 `AT+QCFG="usbcfg"` 也可能改變協議。

| Modem | M.2 品牌 | VID:PID | 當前 composition | mbim.sh 結果 | 詳情 |
|---|---|---|---|---|---|
| **EM060K-GL** | Quectel | `2c7c:030b` | **MBIM** | ✅ 通 | 中華電信 LTE,IP `10.233.74.136`(HW preset 拔阻後才通) |
| **MV31W** | Quectel | (待補) | **MBIM** | ✅ 通 | 中華電信 **5G-NSA**,IP `10.234.195.120`,DL 400Mbps |
| **EM7595** | Sierra | (待補) | **MBIM** | ✅ 通 | 中華電信 LTE,IP `10.202.214.241` |
| **MV32W-A** | Telit | (待補) | MBIM | ❌ `RadioPowerOff` | **L4 註冊失敗** — SIM OK 但 Provider `unknown`,RF 關著,**不是 mbim 路徑問題** |
| **AIW-356** | Fibocom (FM160) | `2cb7:0104` | **QMI** | ❌ 協議不同(mbim.sh 會 bail) | ✅ **`qmi.sh` 撥通**:中華電信 LTE,IP `10.235.146.208/27`,ping 19ms |

⭐ **校正過去誤判**:
- 之前把 MV31W、EM7595 標成「QMI 系」是**錯的** — 它們在這台機器上的韌體預設就是 MBIM composition,mbim.sh 一打就過。**廠商品牌不等於協議**,要看實際 USB iface class。
- MV32W-A 之前標成「需 vendor init」也**錯了** — 看實際 log 是 `RadioPowerOff` + `deregistered`,卡在 L4(註冊網路),根本沒走到 L6(MBIM CONNECT)。換什麼撥號工具都沒用,要先讓 RF / 註冊那層動起來(查 antenna / SIM authorization / `AT+CFUN=1`)。

⭐ **mbim.sh 實際覆蓋率比原本以為的廣**:目前實測 4/5 個 MBIM 模組都通,失敗的那台是 RF 層問題,不是腳本問題。
- ✅ 適用:任何進 MBIM composition 的模組(EM060K-GL / MV31W / EM7595 已驗證)
- ❌ 不適用:走 QMI composition 的模組(AIW-356 → 要 qmi.sh,⏳ TODO);RF / 註冊有問題的模組(MV32W-A → 要先排 L3/L4)

### 7.6 採購 / 接新 modem 時,怎麼判定它走哪個協議

> 核心觀念:**協議是「韌體當下的 USB composition」決定的,跟廠牌沒關係**。同一顆模組可能 MBIM/QMI 都支援,出廠預設誰看 vendor 心情。

四種辨識方法,從最快到最完整:

**(1) lsusb + interface class** — 卡已經插在 Linux 機器上時最快

```bash
# 看 USB tree + interface class
lsusb -t
# 或更精確
for i in /sys/bus/usb/devices/*/*:1.*; do
  [ -d "$i" ] || continue
  drv="(NONE)"; [ -L "$i/driver" ] && drv=$(readlink "$i/driver" | sed 's,.*/,,')
  printf "%s class=%s/%s/%s drv=%s\n" \
    "$(basename $i)" \
    "$(cat $i/bInterfaceClass)" \
    "$(cat $i/bInterfaceSubClass)" \
    "$(cat $i/bInterfaceProtocol)" \
    "$drv"
done
```

判讀:

| 看到 | 結論 |
|---|---|
| 有 interface `02/0e/00` + `0a/00/02`,被 `cdc_mbim` bind | **MBIM** → 用 `mbim.sh` |
| 有 interface `ff/ff/50` 或類似 vendor-class,被 `qmi_wwan` bind | **QMI** → 用 `qmi.sh` |
| 只有 ttyUSB,沒 cdc-wdm / wwan | **PPP only**(老 3G dongle) |
| 只有 1 interface + 2 EP + class `ff/ff/ff` | 異常(EDL/Sahara,韌體壞) |

**(2) `mmcli` 一行確認** — 如果 ModemManager 認得到

```bash
mmcli -m 0 | grep -i "ports:"
# cdc-wdm0 (mbim)  → MBIM
# cdc-wdm0 (qmi)   → QMI
```

**(3) AT command 問模組韌體** — 接 AT port 後

| 廠商 | 看當前 USB composition |
|---|---|
| Quectel | `AT+QCFG="usbcfg"` |
| Sierra  | `AT!USBCOMP=?`(可能要 `AT!ENTERCND` unlock) |
| Telit   | `AT#USBCFG?` |
| Fibocom | `AT+GTUSBMODE?` |
| SIMCom  | `AT+CUSBPIDSWITCH?` |

回的 PID/composition 數值再查 vendor datasheet 表對應到 MBIM / QMI / RmNet / NDIS / ECM。

**(4) Datasheet 關鍵字** — 還沒下單前

| Datasheet 寫… | 大概率是 |
|---|---|
| "MBIM" / "Mobile Broadband" / "NDIS 6.30" | MBIM |
| "QMI" / "RmNet" / "GobiNet" / "Qualcomm MSM Interface" | QMI |
| "PPP only" / "AT-only data" / "RAS" | PPP(避開) |
| "Multiple USB compositions" / "User configurable" | 可切,deploy 後還能用 AT cmd 救 |
| "Microsoft MBIM Compliance" | MBIM 標準 |

⭐ **採購心得**:**MBIM 是業界共通標準**(Microsoft + 3GPP 推、Linux mainline `cdc_mbim` 直接支援、libmbim 任何 distro 都有);QMI 是高通家原生協議,**現代 4G/5G modem 大多兩種都支援、可 AT 切換**。問 FAE 「預設 USB composition 是什麼、能不能切到 MBIM」,懂的會立刻給你 PID 表跟切換 SOP。

⭐ **快速結論**:**選「可切換 + 預設 MBIM」的,deploy 後出 bug 還能用 AT command 救;盡量避開 PPP-only(沒 hardware offload,效能差)**。

### 7.7 MV32W-A `RadioPowerOff` 排查方向(待跑)

實際 log:`SIM initialized` ✅、`Register state: deregistered`、`Provider: unknown`、`data classes: none`、`attach-packet-service: RadioPowerOff`。
這是 modem RF 子系統處於關閉狀態(等同飛航模式),要排:

- `AT+CFUN?` — 若回 `+CFUN: 4` 或 `0`,送 `AT+CFUN=1` 打開 RF
- `AT+CPIN?` / `AT+CSQ` — 確認 SIM ready + 訊號強度
- `AT+COPS=?` — 看 modem 找不找得到電信商
- 天線是否接好(Main + Diversity)
- B-Key Pin 26 (`W_DISABLE2#`) / Pin 8 (`W_DISABLE1#`) 預設電位 — Pin 8 LOW = 飛航
- Telit 系是否有 `AT+CFUN=1,1` reset 後重試的 quirk

---

## 8. 排查流程速查

| 症狀 | 對應層 | 第一步去看 |
|---|---|---|
| `lsusb` 看不到 modem | L0 | Pin 6/8 GPIO 狀態 + EDL composition 檢查 |
| lsusb 看到，但只 1 interface 2 EP | L0/L1 | 卡 EDL，要 QFirehose 重灌 |
| 沒 `/dev/cdc-wdm0` / `ttyUSB*` | L1 | driver alias、`modprobe cdc_mbim option` |
| AT 不回 OK | L2 | port 對嗎？baud rate？ |
| SIM 不 READY | L3 | SIM PIN / 接觸不良 |
| `AT+CREG?` 不是 0,1 / 0,5 | L4 | 訊號 / 漫遊權限 / SIM 帳單 |
| MBIM CONNECT 失敗 | L6 | **這次主因 = 半開 session，改用 `mbim-network`** |
| wwan0 拿到 169.254.x.x | L7 | DHCP fail；bearer 沒真撥起；NM 在搶 |
| ping 不通但 IP 有 | L7 | route / DNS / firewall |

更完整 cheat sheet 在 [`modem-guide.md`](./modem-guide.md) §10。

---

## 9. 想深入學習 — 各文件指南

| 我想了解... | 看哪個 |
|---|---|
| 「修這台板子要怎麼測」 | **本檔 + 跑 `mbim.sh`** |
| 「上層軟體 (libmbim / MM / NM) 整個架構長怎樣、為什麼這樣選？」 | [`software-stack.md`](./software-stack.md) |
| 「PPP / MBIM / QMI 差在哪？什麼時候用哪個？」 | [`software-stack.md`](./software-stack.md) §3 |
| 「每個 driver 怎麼接到 modem 的？PID match vs class match？」 | [`modem-guide.md`](./modem-guide.md) §7 |
| 「給多客戶用的 BSP image 要怎麼補才能讓 MM 自動撥？」 | [`bsp-prompt.md`](./bsp-prompt.md) |
| 「之前 modem 卡 EDL 怎麼救回來的？」 | [`REPORT.md`](./REPORT.md) + `build_qmi_wwan.sh` |
| 「Pin 6/8 GPIO 怎麼追到 SoC 端的？」 | [`NOTES.md`](./NOTES.md) §「Hardware GPIO 排查清單」 |
| 「完整 debug 時序紀錄（從第一天到 cellular 通）」 | [`NOTES.md`](./NOTES.md) |

---

## 10. 本目錄完整檔案清單

```
debug/5G-modem/
├── README.md                          ← 本檔，接手入口
├── software-stack.md                  ← 上層軟體架構深入
├── modem-guide.md                     ← 全面技術參考
│
├── NOTES.md                           ← 時序 debug log (歷史)
├── REPORT.md                          ← EDL 復原報告 (歷史)
│
├── mbim.sh                            ← ⭐ MBIM 模組撥號(EM060K-GL/MV31W/EM7595 已驗證)
├── qmi.sh                             ← ⭐ QMI 模組撥號(AIW-356/FM160 已驗證)
├── mm-connect.sh                      ← 對照組 / 未來 BSP 升級後可用
│
├── qmi_wwan.patch                     ← qmi_wwan driver 加 030B PID 的 patch
├── build_qmi_wwan.sh                  ← 交叉編譯 patched qmi_wwan.ko
├── deploy_qmi_wwan.sh                 ← 推 .ko 到 target
│
├── 77-mm-quectel-em060k-030b.rules    ← udev rule (測試用，不進 BSP)
├── bsp-prompt.md                      ← 給 BSP repo 寫 Yocto recipe 的 prompt
└── (PDFs)                             ← Quectel datasheet / 客戶 schematic
```

---

## 11. 一句話總結

**5G modem = 自帶 baseband + RF 的 USB SoC,host 透過 driver + control device (`/dev/cdc-wdm0`) 講協議撥號,撥通後 `wwan0` 跑 IP 流量。**

**MBIM 模組跑 `./mbim.sh`;QMI 模組跑 `./qmi.sh`;協議分派看 §7.5,新模組怎麼分辨看 §7.6。**
