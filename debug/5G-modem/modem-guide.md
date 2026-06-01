# 5G/LTE Modem 完整指南 — Linux 端從 USB 到撥號

> 為了讓你成為 modem 大師。寫給「會用 Linux、會 adb、但對 modem 內部 stack 不熟」的人。
> 本文以 SA8775P + QLI 1.8 + Quectel EM060K-GL 的實戰經驗整理，但 stack 大致通用。

---

## 1. Modem 是什麼

一張 cellular modem (LTE/5G) 本質上是一個獨立的 SoC，內含：

- **Baseband processor**：跑 modem 自己的 RTOS / QuRT（高通系平台），實作 3GPP protocol stack
- **RF transceiver + PA + 天線**：實體層
- **Memory**：modem 自己的 RAM/Flash，跟 host CPU 完全分離
- **(可選) GNSS engine**

對 host 來說它就是個 **USB（或 PCIe）周邊**。Host 跟 modem 講話**都要透過 USB descriptor 上「某個介面 + 某個協議」**。

```
┌─────────── Host (QLI / Linux) ───────────┐         ┌──── Modem (EM060K-GL) ───┐
│                                          │         │                          │
│  app → NM → MM → libmbim → /dev/cdc-wdm0 │ ←USB→  │  baseband (3GPP stack)   │
│                          → /dev/ttyUSB*  │ ←USB→  │  RTOS                    │
│                          → wwan0 (net)   │ ←USB→  │  RF / SIM                │
│                                          │         │                          │
└──────────────────────────────────────────┘         └──────────────────────────┘
```

---

## 2. USB Composition — modem 出現幾根 interface？

modem 韌體會決定它在 USB 上「長幾根介面、各做什麼事」，這叫 **USB composition**。一顆 EM060K-GL 正常 composition 長這樣：

| Interface | Class | EP | Linux driver | 用途 |
|---|---|---|---|---|
| 1.0 | FF/FF/30 | 2 | `option` | **NMEA**（GPS sentence 輸出） |
| 1.1 | FF/00/40 | 3 | `option` | DM (diagnostic) |
| 1.2 | FF/FF/40 | 3 | `option` | **AT 主 port**（撥號 / 控制） |
| 1.3 | FF/FF/40 | 3 | `option` | AT 副 port |
| 1.8 | **02/0E/00** | 1 | **`cdc_mbim`** | **MBIM control** → `/dev/cdc-wdm0` |
| 1.9 | 0A/00/02 | 2 | `cdc_mbim` | **MBIM data** → `wwan0` net device |
| 1.12 | FF/FF/70 | 1 | (none) | QDSS aux trace（正常沒 driver） |

對應出現的 char device：
- `/dev/ttyUSB0~3`（option driver）
- `/dev/cdc-wdm0`（cdc_mbim 或 qmi_wwan）
- `wwan0`（kernel net device）

composition 透過 modem AT command 設定：
- Quectel：`AT+QCFG="usbcfg",...`
- Sierra：`AT!UDUSBCOMP=N`
- Telit：`AT#USBCFG=N`

> ⚠️ 不同 composition 開出的 interface **完全不同**。例如 MBIM mode 跟 RmNet/QMI mode 是互斥的，要選一個。

### 異常 composition

| composition | bNumInterfaces | bNumEndpoints | 意義 |
|---|---|---|---|
| 正常 application | 5~7 | 多種 | 可以撥號 |
| **Sahara / QDLoader (EDL)** | **1** | **2 Bulk** | **韌體掛了 / 卡 recovery，只能 QFirehose 重灌** |
| 只 DM (diagnostic-only) | 1 | 2 | 通常還是要 QFirehose |

這就是我們之前的「卡 EDL」事件 —— 看到 1 interface / 2 bulk EP / class=FF/FF/FF 就是這個。

---

## 3. 控制協議 — PPP / QMI / MBIM 三選一

modem 跟 host 講 data session 有三套常見協議，**用哪一套由 modem composition + driver 決定**：

### 3.1 PPP over AT (老派、慢、相容性最好)
- 通道：USB serial 上的 AT port (`/dev/ttyUSB*`)
- 撥號方式：`AT+CGDCONT=1,"IP","apn"` → `ATD*99#` → `pppd` 接管
- 速度：**受 USB serial bulk 限制，大約 < 12 Mbps**
- 軟體：`pppd`, ModemManager 在 cdc_mbim 不可用時會 fallback 到這條
- 優點：任何老 modem 都通；缺點：4G/5G 在這條根本跑不出速度

### 3.2 QMI (Qualcomm MSM Interface) — Qualcomm 專屬
- 通道：`/dev/cdc-wdm0` (control) + `wwan0` (data)
- Driver：`qmi_wwan` (kernel) + `libqmi`/`qmicli` (user)
- ID match 方式：**靠 vendor PID 表** (`QMI_MATCH_FF_FF_FF(VID, PID)` macro)
- 撥號方式：透過 QMI Service WDS (`qmicli --wds-start-network=...`)
- 速度：**全速 LTE/5G**
- ⚠️ **PID 沒在 driver table 內就不會 bind** → 要 patch `qmi_wwan.c` 加 PID + 重編 (詳見 `build_qmi_wwan.sh`)

### 3.3 MBIM (Mobile Broadband Interface Model) — USB-IF 標準
- 通道：同上，`/dev/cdc-wdm0` + `wwan0`
- Driver：`cdc_mbim` (kernel) + `libmbim`/`mbimcli` (user)
- ID match 方式：**靠 USB CDC class 簽章** (class=0x02 / subclass=0x0E / protocol=0x00)
- 撥號方式：MBIM_CID_CONNECT message
- 速度：全速
- ✅ **不需要 PID 在 driver table** — class 對就自動接，所以 EM060K-GL 一進 MBIM composition 就被 `cdc_mbim` 接走

> 💡 實測結果:EM060K-GL / MV31W / EM7595 / MV32W-A 在本機都是 MBIM composition。AIW-356(Fibocom FM160) 是 QMI composition。**廠商品牌 ≠ 協議**,要看 USB iface class 才算。同款模組改 firmware / 切 `AT+QCFG="usbcfg"` 也可能變協議。

---

## 4. Linux Modem 軟體 Stack

```
┌──────────────────────────────────────────────────────────────┐
│  Application                                                 │
│  (your test script / browser / curl)                         │
└────────────────┬─────────────────────────────────────────────┘
                 │
┌────────────────▼─────────────────┐   ┌──────────────────────┐
│  NetworkManager (nmcli)          │←─▶│  ModemManager (mmcli)│
│  - 管 IP / route / DNS / DHCP    │   │  - per-vendor plugin │
│  - 走 nmcli con add gsm ...      │   │  - quectel / sierra  │
└──────────────────────────────────┘   │  - mbim-proxy 客戶端 │
                 ▲                     │  - 自動撥號 + reg    │
                 │                     └──────────┬───────────┘
                 │ DBus                            │
                 └─────────────────────────────────┤
                                                   │
                            ┌──────────────────────┴───────────┐
                            ▼                                  ▼
              ┌──────────────────────┐         ┌─────────────────────────┐
              │  libmbim + mbim-proxy│         │  libqmi + qmi-proxy     │
              │  (mbimcli)           │         │  (qmicli)               │
              └──────────┬───────────┘         └────────────┬────────────┘
                         │                                  │
                         ▼                                  ▼
                  /dev/cdc-wdm0                      /dev/cdc-wdm0
                  (MBIM control)                     (QMI control)
                                                                         
              ┌──────────────────────────────────────────────────┐
              │  Kernel drivers                                  │
              │  - cdc_mbim  (claim MBIM control + data)         │
              │  - qmi_wwan  (claim QMI interface)               │
              │  - option / usb_wwan / usbserial (claim AT)      │
              │  - usbnet (provides wwan0)                       │
              └────────────────────┬─────────────────────────────┘
                                   │
                                   ▼
                           xhci-hcd / dwc3 USB host controller
                                   │
                                   ▼
                            Physical USB Link
                                   │
                                   ▼
                              Modem hardware
```

### 4.1 為什麼有 `mbim-proxy` / `qmi-proxy`

`/dev/cdc-wdm0` 一次只能讓**一個 process open**。但你可能想要：
- ModemManager 在跑
- 又想自己跑 `mbimcli` 看狀態

mbim-proxy 就是中間人：MM 連 proxy、你的 `mbimcli -p` 也連 proxy，proxy 統一跟 device 溝通。**任何 `mbimcli -p` / `qmicli -p` 都會自動 spawn proxy**。

---

## 5. 撥號流程 — 不管哪條協議都要做這些

1. **modem boot + USB enumerate**（host 看到 USB device）
2. **driver 把 interface 接走**（cdc_mbim / qmi_wwan / option）
3. **建立 control session**（MBIM_OPEN / QMI device open）
4. **確認 SIM ready**（PIN 解鎖 / IMSI 讀到）
5. **註冊網路**（attach to home PLMN，state = home/roaming）
6. **PS attach** (Packet Service Attach — LTE/5G data 必要前置)
7. **Create bearer / Activate PDP context**（用 APN 跟核網要 IP）
8. **拿到 modem 端 IP / Gateway / DNS**
9. **OS net interface (wwan0) 拉 up + 套 IP**（DHCP 或 static）
10. **設 default route**

省略任何一步都會撐不起資料流。

---

## 6. ⭐ 本案釐清：EM060K-GL 撥號的兩條路徑

### Path A — Standalone MBIM (`mbim.sh`)

```
你的腳本 ─ mbimcli --connect ─ /dev/cdc-wdm0 ─ modem
```

| 模組 | 結果(2026-05-29 實測) | 備註 |
|---|---|---|
| EM060K-GL | ✅ 通(HW preset 拔阻後) | IP `10.233.74.136`,中華電信 LTE |
| MV31W | ✅ 通 | IP `10.234.195.120`,中華電信 **5G-NSA**,下行 400Mbps — 本機韌體預設 MBIM composition |
| EM7595 | ✅ 通 | IP `10.202.214.241`,中華電信 LTE — 本機韌體預設 MBIM composition |
| **MV32W-A** | ❌ `RadioPowerOff` | SIM OK 但 **L4 註冊失敗**(`deregistered` / provider `unknown` / data classes `none`),RF 關著 — **不是 mbim.sh 問題**,要先排 `AT+CFUN` / 天線 / W_DISABLE pin |
| **AIW-356 (FM160)** | ❌ 卡死 → 加 protocol detect 後直接 bail | Fibocom 走 QMI composition,腳本不適用,要 `qmicli` / `qmi-network` |

⭐ **2026-05-29 重新校正**:
- 「EM060K-GL `NotInitialized` 是韌體要 vendor init」**錯了** — 實際是 **B-Key Pin 6 preset 0R 拉 high 把 modem 打進異常狀態**(詳見 [REPORT.md](REPORT.md))。HW rework 後 mbim-network 直接撥通。
- 「MV31W / EM7595 走 QMI」**錯了** — 它們在這台機器上的韌體**就是 MBIM**,mbim.sh 直接通。廠商品牌跟協議是兩件事,要看 USB iface class 才算數。
- 「MV32W-A 需 vendor init」**錯了** — log 顯示卡在 L4 `RadioPowerOff`,根本沒走到 L6 MBIM CONNECT,跟 vendor init 無關,要排 RF 層。

> 結論:mbim.sh 對任何 **MBIM composition** 模組都通(目前 4/4 hit rate,只有 RF 出問題的 MV32W-A 失敗 — 但那不是路徑問題)。**真正不適用的是 QMI composition**(AIW-356/FM160),那派要寫 qmi.sh。詳見 §9 對照表。

### Path B — ModemManager + NetworkManager (`mm-connect.sh`) ✅ 推薦

```
你的腳本 ─ mmcli ─ ModemManager ─ quectel plugin ─ MBIM/AT ─ modem
                       ↑
                 (MM 知道要送 Quectel vendor init)
```

| 步驟 | 動作 |
|---|---|
| 1 | `systemctl start ModemManager NetworkManager` |
| 2 | 等 MM 探測完 modem (~20s) |
| 3 | `mmcli -m 0 --enable` |
| 4 | `mmcli -m 0 --simple-connect="apn=xxx,ip-type=ipv4"` |
| 5 | `nmcli con add type gsm ifname '*' con-name 5g-mm apn xxx` |
| 6 | `nmcli con up 5g-mm` |

實測 EM060K-GL 結果：✅ **`state: connected`**，但 `interface: ttyUSB2 / method: ppp`。

#### ⚠️ EM060K-GL 走 MM 時的「PPP fallback」

```
mmcli -m 0 顯示：ports: ttyUSB2 (at), ttyUSB3 (at), wwan0 (ignored)
                                                          ^^^^^^^
```

`wwan0 (ignored)` 表示這份 QLI ModemManager build **沒開 MBIM 支援**，所以 MM 看到 MBIM 介面也跳過、改用 PPP via AT。功能 OK 但速度上限大約幾 Mbps。

**要拿到 MBIM 全速**有三條路：
1. **重 build ModemManager** 加 `--with-mbim` flag + libmbim-glib 連結
2. 看 ModemManager 是否需要 udev rule 強制 `ID_MM_DEVICE_MBIM_PROXY=1`
3. **暫時忍受 PPP**（控制流量沒問題，速度需求高的場景才痛）

---

## 7. Driver 怎麼接到 modem 的？

理解 driver bind 機制能省下大量 debug 時間。

### 7.1 USB driver 接 device 的兩種 match 方式

```c
// 方式 A：用 vendor/product ID 表 (PID match)
static const struct usb_device_id qmi_wwan_id_table[] = {
    {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0306)},   // EP06/EG06/EM06
    {QMI_MATCH_FF_FF_FF(0x2c7c, 0x030b)},   // ← 沒這行 EM060K-GL 就被無視
    ...
};

// 方式 B：用 USB class 簽章 (class match)
static const struct usb_device_id mbim_devs[] = {
    {USB_INTERFACE_INFO(USB_CLASS_COMM, USB_CDC_SUBCLASS_MBIM, USB_CDC_PROTO_NONE)},
    ...
};
```

### 7.2 各 driver 用哪種

| Driver | 主要 match 方式 | PID 沒列在 driver 內怎辦 |
|---|---|---|
| `qmi_wwan` | **PID match** | 必須 patch driver 源碼加 PID + 重編，或執行階段 `echo "VID PID" > /sys/bus/usb/drivers/qmi_wwan/new_id` |
| `cdc_mbim` | **Class match** (CDC subclass 0x0E) | 不用管 PID — 任何符合 spec 的 MBIM device 都自動接 |
| `option` | PID alias + interface protocol | modules.alias 內每組 PID+protocol 都要列；不在的話 `echo "VID PID protocol" > /sys/bus/usb-serial/drivers/option1/new_id` |
| `cdc_acm` | Class match (USB_CLASS_COMM, ACM subclass) | 不用管 PID |

### 7.3 怎麼看誰接走哪個 interface

```bash
for i in /sys/bus/usb/devices/*:*.* ; do
    name=$(basename $i)
    [ -f $i/bInterfaceClass ] || continue
    drv=$(readlink $i/driver 2>/dev/null | xargs basename)
    cls=$(cat $i/bInterfaceClass)
    sub=$(cat $i/bInterfaceSubClass)
    prot=$(cat $i/bInterfaceProtocol)
    nep=$(cat $i/bNumEndpoints)
    echo "$name  drv=${drv:-NONE}  class=$cls/$sub/$prot  EP=$nep"
done
```

### 7.4 modules.alias 怎麼看

```bash
grep -i "v2C7Cp030B" /lib/modules/$(uname -r)/modules.alias
# alias usb:v2C7Cp030Bd*dc*dsc*dp*icFFiscFFip40in* option   ← AT/DM
# alias usb:v2C7Cp030Bd*dc*dsc*dp*icFFiscFFip30in* option   ← NMEA
# alias usb:v2C7Cp030Bd*dc*dsc*dp*icFFisc00ip40in* option
```

格式：`v<VID>p<PID>d<bcdDevice>dc<DevClass>dsc<DevSubclass>dp<DevProtocol>ic<IfClass>isc<IfSubclass>ip<IfProtocol>in<IfNum>`

---

## 8. Debug 排查流程圖

```
撥號失敗
   │
   ├─[1]─→ lsusb 看到 modem 嗎？
   │       │ NO  → 排查 USB 上電 / W_DISABLE# / RESET# GPIO
   │       │       (詳見 NOTES.md「Hardware GPIO 排查清單」)
   │       │       特別注意：1 interface + 2 bulk EP = EDL 卡死，要 QFirehose
   │       │ YES → 下一步
   │       ▼
   ├─[2]─→ /sys/.../bInterfaceClass + 每個 interface 的 driver
   │       │ class=FF/FF/FF + EP=2  → EDL，去 QFirehose
   │       │ 1.8 是 02/0E/00 → MBIM mode；cdc_mbim 該接
   │       │ 有 RmNet / GobiNet → QMI mode；qmi_wwan 該接
   │       │ 只有 ttyUSB* → 純 AT/PPP mode
   │       ▼
   ├─[3]─→ /dev/cdc-wdm0 + /dev/ttyUSB* 出現了嗎？
   │       │ NO  → driver 沒 bind，新增 new_id 或 patch driver
   │       │ YES → 下一步
   │       ▼
   ├─[4]─→ SIM ready 嗎？
   │       │   mbimcli -d /dev/cdc-wdm0 -p --query-subscriber-ready-status
   │       │   或 mmcli -m 0 後看 sim
   │       │ unlocked 才能繼續
   │       ▼
   ├─[5]─→ 註冊網路？
   │       │   mbimcli ... --query-registration-state
   │       │   要 home 或 roaming
   │       │ NO  → 訊號 / 天線 / SIM 有效性 / 漫遊權限
   │       ▼
   ├─[6]─→ packet-service attached？
   │       │   mbimcli ... --query-packet-service-state
   │       │ NO  → mbimcli ... --attach-packet-service
   │       ▼
   ├─[7]─→ --connect 過嗎？
   │       │ 報 NotInitialized → 嘗試 Path B (mm-connect.sh)
   │       │ 過了            → 下一步
   │       ▼
   ├─[8]─→ wwan0 拿到 IP 嗎？
   │       │ 169.254.x.x → APIPA，DHCP 失敗，可能 NM 在搶 / bearer 沒真撥
   │       │ 沒 IP        → udhcpc 沒跑 / wwan0 沒 up
   │       ▼
   ├─[9]─→ default route 有了嗎？
   │       │   ip route 看 wwan0 是不是 default gateway
   │       ▼
   └─[10]→ ping 8.8.8.8 透過 wwan0 ?
```

---

## 9. 各 modem 的「該走哪條路」對照表

> ⚠️ 此表 2026-05-29 用實測 log 重新校正過(舊版本有兩處誤判:把 MV31W/EM7595 標 QMI、把 MV32W-A 失敗歸成 vendor init,實測都不是)。

| 模組 | M.2 品牌 | VID:PID | **實測當前 composition** | 該走的 path | 已驗證 | 備註 |
|---|---|---|---|---|---|---|
| **EM060K-GL** | Quectel | `2c7c:030b` | **MBIM** | `mbim.sh` | ✅ 中華電信 LTE,IP `10.233.74.136` | HW preset 拔阻後通 |
| **MV31W** | Quectel | (待補) | **MBIM** | `mbim.sh` | ✅ 中華電信 **5G-NSA**,IP `10.234.195.120`,DL 400Mbps | 之前誤標 QMI |
| **EM7595** | Sierra | (待補) | **MBIM** | `mbim.sh` | ✅ 中華電信 LTE,IP `10.202.214.241` | 之前誤標 QMI |
| **MV32W-A** | Telit | (待補) | MBIM | `mbim.sh` 路徑正確,但**目前 RF 層失敗** | ❌ L4 卡 `RadioPowerOff` / `deregistered` | **不是路徑問題**,要排 `AT+CFUN` / 天線 / W_DISABLE pin |
| **AIW-356** | Fibocom (FM160) | `2cb7:0104` | **QMI** | `qmi.sh` (qmi-network + raw-IP) | ✅ 中華電信 LTE,IP `10.235.146.208/27`,RTT 19ms | mbim.sh 走 protocol detect 後 bail;raw-IP 是現代 QMI 必備 |

⭐ **以協議分派、不以 device node 分派**:

| 屬性 | MBIM 派 | QMI 派 |
|---|---|---|
| 代表模組 | EM060K-GL(合作型)、MV32W-A(需 init) | AIW-356/FM160、MV31W、EM7595 |
| Data iface class | `02/0e` + `0a` | `ff/ff/50` 之類 vendor-class |
| Driver | `cdc_mbim` | `qmi_wwan` |
| /dev/cdc-wdm0 | ✅ (但是 MBIM control) | ✅ (但是 QMI control,**同名不同協議**) |
| wwan0 | ✅ | ✅ |
| 撥號 CLI | `mbim-network` / `mbimcli` | `qmi-network` / `qmicli` |
| 一鍵腳本 | `mbim.sh` ⭐ | `qmi.sh` (⏳ TODO,規劃中) |
| 走 MM 路徑 | `mm-connect.sh` (要 MM 有 mbim plugin) | `mm-connect.sh` (要 MM 有 qmi plugin) |

> **新模組來怎麼判**:先看 `/sys/bus/usb/devices/.../bInterfaceClass`。看到 `02/0e + 0a` → MBIM → 試 mbim.sh;看到 vendor-class 被 `qmi_wwan` bind → QMI → 用 qmicli。**不要看 cdc-wdm0 有沒有出來就直接跑 mbim.sh,會卡死。**

---

## 10. 常見故障 cheat sheet

| 症狀 | 主要原因 | 解法 |
|---|---|---|
| modem 不出 USB | 上電 / W_DISABLE# / RESET# GPIO 異常 | 查 GPIO（NOTES.md） |
| USB 出，1 interface 2 EP, FF/FF/FF | 卡 EDL/Sahara | QFirehose 灌韌體 |
| qmi_wwan 沒接 | PID 不在 driver table | patch driver 加 PID（build_qmi_wwan.sh） |
| cdc_mbim 沒接但 interface 有 | MBIM 介面 class 不對 / driver 沒 load | `modprobe cdc_mbim`，看 dmesg |
| /dev/cdc-wdm0 顯示 device is closed | 別人占著 (通常 MM) | `mmcli -m 0 --disable` 或 stop MM |
| mbimcli --connect: NotInitialized | 韌體需要 vendor-specific init | 改走 MM (mm-connect.sh) |
| wwan0 拿到 169.254.x.x | DHCP 失敗 / NM 自動配 APIPA | bearer 沒真撥成功，往上查 |
| NETDEV WATCHDOG: transmit queue timed out | wwan0 被 up 但 bearer 沒建好 | 先撥再 ip link up |
| mmcli -L: No modems found | MM 還在偵測 / udev rule 把 modem blacklist | 等 30s；查 /usr/lib/udev/rules.d/*ModemManager* |
| mmcli 顯示 wwan0 (ignored) + 改走 PPP | MM build 沒含 MBIM 支援 | 重 build MM with `--with-mbim` |

---

## 11. 工具速查

| 工具 | 用途 |
|---|---|
| `lsusb -t` | USB 樹狀結構 |
| `cat /sys/bus/usb/devices/*/idVendor + idProduct` | 找 modem VID:PID |
| `dmesg \| grep -iE 'usb 2-1.4\|cdc_mbim\|qmi\|option'` | kernel 接 modem 訊息 |
| `mbimcli -d /dev/cdc-wdm0 -p --help-...` | MBIM 操作 |
| `qmicli -d /dev/cdc-wdm0 -p --help-...` | QMI 操作 |
| `mmcli -L / -m 0 / -m 0 -b 0` | ModemManager 看 modem / bearer |
| `nmcli c / c add type gsm / c up` | NetworkManager profile |
| `ip a / ip link / ip route` | net interface 狀態 |
| `udhcpc -i wwan0 -q -n` | DHCP client（QLI busybox 內建） |
| `pgrep -af mbim-proxy` | proxy 是否還活著 |
| `fuser /dev/cdc-wdm0` | 誰開著 control device |

---

## 14. ⚠️ QLI 1.8 BSP 缺件 (本次實戰最重要發現)

實測 QLI 1.8-ver.1.1 image 對 cellular data 的支援 **不完整**：

### 14.1 已確認缺件清單

| 部件 | 狀態 | 影響 |
|---|---|---|
| `ModemManager` 二進位 | **沒含 `--with-mbim` `--with-qmi`** | MM 不能用 MBIM/QMI 通道，只能 fallback PPP。檢查：`ldd /usr/sbin/ModemManager \| grep -iE "mbim\|qmi"` → 空輸出 |
| `pppd` + `chat` | feed 內**沒這套件** | MM fallback PPP 後沒人能 spawn pppd → 整條 PPP 路斷掉 |
| `networkmanager-plugin-wwan` | feed 內**沒這套件** | NM 看不到 modem (`WWAN-HW: missing`)、`nmcli con up gsm-xxx` 找不到 device |
| ~~udev port-types rule for PID 030B~~ | （**非必要**，見下方說明） | 純優化，不影響撥號 |

> **udev rule 為何被我們刻意排除在 BSP 補丁外**：
> - 純優化（讓 MM 跳過 DM port 的 AT 探測），**沒它 modem 還是能撥**
> - 實測 MM 已自己 generic-detect 出 `ttyUSB2 (at), ttyUSB3 (at)` — 已經夠用
> - 給多客戶共用的 image 不該為單一 vendor PID 寫死 rule
> - 真要做的對的方式：bump MM 到 upstream 已涵蓋的版本，或送 PR 到 freedesktop/ModemManager 上游

### 14.2 結果（已找到 workaround）

✅ **2026-05-29 更新：EM060K-GL 在現 BSP 撥通了**，方法是用 `mbim-network` (libmbim 官方 wrapper)，**完全不靠 MM/NM/pppd**。

之前手刻 `mbimcli --connect` 失敗的 `NotInitialized` **不是 firmware bug**，是我們用 `--no-close` 留下半開 MBIM session 造成；`mbim-network` 按正確 sequence 一次跑完就過。

| 路徑 | 狀態 | 備註 |
|---|---|---|
| `mbim-network` standalone（[`mbim.sh`](./mbim.sh)） | ✅ 通 | 不需要任何 BSP 改動 |
| MM `--simple-connect` → MBIM/QMI | ❌ MM 沒連 libmbim/libqmi | 想要 → 補 BSP |
| MM → PPP via AT | ❌ 沒 pppd | 想要 → 補 BSP |
| NM `nmcli con up gsm-xxx` | ❌ NM 沒 wwan plugin | 想要 → 補 BSP |

→ **EM060K-GL 在原廠 QLI 1.8 不改 image 就能撥**，但 **MM/NM 自動化體驗要補 BSP**。

### 14.3 BSP 補丁清單（**升級到自動化** 用，不是必要）

不改也能撥（用 mbim.sh），但加上去之後 MM/NM 才能自動 monitor / auto-reconnect / 漫遊切換：

```bitbake
# image.bb / local.conf
IMAGE_INSTALL:append = " ppp networkmanager-plugin-wwan"
PACKAGECONFIG:append:pn-modemmanager = " mbim qmi"
```

完整給 BSP repo 用的 prompt 在 [`bsp-prompt.md`](./bsp-prompt.md)。

### 14.4 短期 workaround = 主用方案（不重 build BSP）

✅ 跑 [`mbim.sh`](./mbim.sh) 就行，已驗證端到端拿到真實 IP + ping + DNS 通。

若只需 signaling 測試（拿 IMEI、確認註冊、簡訊收發），用 `mmcli` 也足夠：

```bash
mmcli -L                                    # 列 modem
mmcli -m 0                                  # 看詳細
mmcli -m 0 --messaging-list-sms             # 看簡訊
mmcli -m 0 --location-status                # GPS 狀態
mmcli -m 0 --command='AT+CSQ'               # 下任意 AT（要 MM 開 debug-mode）
```

~~要真的拿到 data path，**沒有純 userland 解法**，必須改 BSP。~~  
**~~已推翻~~**：mbim.sh (mbim-network 路徑) 就是 userland 解法，已驗證可用。BSP 補丁是給「自動化體驗」用。

---

## 12. 本目錄檔案說明

```
debug/5G-modem/
├── modem-guide.md                          ← 本文
├── NOTES.md                                ← 即時 debug 筆記（EDL → MBIM → 撥號 → BSP）
├── REPORT.md                               ← 第一階段「卡 EDL」結案報告
│
├── mbim.sh                                 ← 走 standalone MBIM/QMI (EM7595/MV31W OK)
├── mm-connect.sh                           ← 走 ModemManager (含 BSP preflight 檢測)
│
├── 77-mm-quectel-em060k-030b.rules         ← udev rule patch (補 PID 030B 進 MM port hints)
│
├── build_qmi_wwan.sh                       ← 交叉編譯 patched qmi_wwan.ko (含 030B PID)
├── deploy_qmi_wwan.sh                      ← 推 .ko 到 target /opt/
└── qmi_wwan.patch                          ← 加 EM060K-GL PID 的 driver patch
```

---

## 13. 名詞快速對照

| 縮寫 | 全名 | 一句話解釋 |
|---|---|---|
| MBIM | Mobile Broadband Interface Model | USB-IF 標準的 4G/5G control 協議 |
| QMI | Qualcomm MSM Interface | Qualcomm 私有的 4G/5G control 協議 |
| PPP | Point-to-Point Protocol | 走 AT 撥的老式撥號 |
| PDP | Packet Data Protocol | 3GPP 的 data session 概念，含 APN/IP |
| APN | Access Point Name | 電信商給的 data 接入點名稱 |
| PS attach | Packet Service Attach | LTE/5G 開始 data 前的必要步驟 |
| EDL | Emergency Download | Qualcomm modem 韌體掛了時的 recovery USB 模式 (PID 9008) |
| QDLoader / Sahara | Qualcomm 的 USB protocol | EDL 模式跑的協定，用來灌韌體 |
| QFirehose | Qualcomm 灌韌體工具 | 透過 Sahara 灌 modem image |
| bearer | data 連線會話 | MM 把每條 data 連線抽象成 bearer |
| CID | MBIM Command ID | MBIM 上每種操作有自己的 CID |
| TRID | Transaction ID | MBIM 訊息序號，用來配對 request/response |
