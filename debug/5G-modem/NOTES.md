# EM060K-GL 5G Modem Debug Notes

## Target
- Platform: SA8775P (LeMans), Qualcomm Linux 1.8-ver.1.1
- Kernel: 6.6.119-qli-1.8-ver.1.1-06201-g380a343250d3-dirty
- Modem: Quectel EM060K-GL, USB attached (M.2)
- USB VID:PID = `2c7c:030b`
- USB path: Bus 003 (SuperSpeed) → hub 3-1 → port 3-1.4

## Symptom
Card enumerates on USB but no kernel driver binds. No `/dev/ttyUSB*`, no `wwan0`, no `/sys/class/wwan/`.

## Key Observations (via `adb shell`)

### 1. Modem only exposes ONE interface, all vendor-specific
```
/sys/bus/usb/devices/3-1.4
  idVendor:        2c7c
  idProduct:       030b
  manufacturer:    Quectel
  product:         EM060K-GL
  bNumInterfaces:  1     <-- 應該要 5~7 個
  bConfigurationValue: 1

/sys/bus/usb/devices/3-1.4:1.0
  bInterfaceClass:    ff
  bInterfaceSubClass: ff
  bInterfaceProtocol: ff   <-- vendor-specific
  driver:             (none — NOT BOUND)
```

### 2. Driver modules are present but not auto-loaded
`/lib/modules/$(uname -r)/` 內有：
- `option.ko`, `usbserial.ko`, `usb_wwan.ko`
- `qmi_wwan.ko`, `cdc_mbim.ko`, `cdc_ether.ko`, `cdc_ncm.ko`, `usbnet.ko`
- `wwan.ko`

`lsmod` 完全沒載入 → udev 沒觸發 modprobe，因為當前 interface 的 modalias 不在任何 driver 的 alias 表內。

### 3. option.ko 對 PID 030B 的 alias 是 ip30 / ip40，不是 ipFF
```
alias usb:v2C7Cp030Bd*dc*dsc*dp*icFFiscFFip40in* option   <- AT/DM
alias usb:v2C7Cp030Bd*dc*dsc*dp*icFFiscFFip30in* option   <- NMEA
alias usb:v2C7Cp030Bd*dc*dsc*dp*icFFisc00ip40in* option
```
`qmi_wwan.ko` **完全沒有** 030B 的 alias（這個 driver 對 EM060K-GL 用的是 RmNet/MHI 路徑，
但 EM060K-GL 一般是 cdc_mbim 或 qmi over USB；新 kernel 對 030B 的 RmNet 通常用 cdc_mbim）。

### 4. dmesg 沒任何 driver 嘗試 bind 的記錄
```
[ 42.207607] usb 3-1.4: new SuperSpeed USB device number 3 using xhci-hcd
```
之後就沒了 — 沒有 `option`, `qmi_wwan`, `usb_modeswitch` 嘗試。

## Root Cause (已確認 — 參考 OpenWrt issue #16165)

**`qmi_wwan.ko` 的 PID table 漏掉 `0x030b`，導致它不認 EM060K-GL。** Modem 本身是正常的 application mode。

### USB descriptor 解析 (`/sys/bus/usb/devices/3-1.4/descriptors`)
```
bcdUSB        = 3.00
VID:PID       = 2c7c:030b
numInterfaces = 1                     <-- single-interface QMI composition (Quectel AT+QCFG 可設定)
bMaxPower     = 0x01 (~8mA)           <-- M.2 modem 從 slot 拿電，不靠 USB VBUS，所以這麼低
Interface 0   = class FF / subClass FF / protocol FF   <-- 標準 QMI/RmNet 簽章
Endpoints     = EP 0x81 IN bulk 1024 / EP 0x01 OUT bulk 1024
```

42 秒才列舉是 cellular modem cold boot 的正常時間 (20~50s)。
沒有 reset/disconnect loop，狀態穩定。

### 為何沒 bind？
- `qmi_wwan.c` 用 `QMI_MATCH_FF_FF_FF(vid, pid)` macro 來 match `class=FF/subClass=FF/protocol=FF` 的 QMI interface
- in-kernel `qmi_wwan.ko` (kernel 6.6.119-qli) 的 PID table **沒有 `0x030b`**
- `modules.alias` 內 `2c7c:030b` 只有 `option` 的 alias，且只對 `ip30` / `ip40`，不對 `ipFF`
- 所以 udev 自動載入也不會觸發，手動 `modprobe qmi_wwan` 後它也不會 bind 這個 interface

### 對照 OpenWrt #16165
完全一樣症狀。修復就是在 `drivers/net/usb/qmi_wwan.c` 加一行：
```c
{QMI_MATCH_FF_FF_FF(0x2c7c, 0x030b)},   /* Quectel EM060K-GL */
```
插在 `{QMI_MATCH_FF_FF_FF(0x2c7c, 0x0306)}` (EP06/EG06/EM06) 與
`{QMI_MATCH_FF_FF_FF(0x2c7c, 0x0512)}` (EG12/EM12) 之間。

## Device Tree 檢查 (不是問題)

`dtb/vfat/combined-dtb.dts` 內未找到 M.2 modem / wwan / W_DISABLE / modem-power 相關 node。
搜尋到的 `wlan-en` 是 SoC 內建 WLAN，`mhi` 是 PCIe controller reg name，`rt-cdm2` 是 camera node。

M.2 USB modem 不需要 DT power control — slot 直接給電 + W_DISABLE# 預設 pull-up 即可。
事實上 modem 列舉成功就代表上電 OK，DT 沒問題。

## 修復方式

### A. 動態 ID 注入 (驗證用，重開機失效)
```bash
modprobe qmi_wwan
echo "2c7c 030b" > /sys/bus/usb/drivers/qmi_wwan/new_id
# 預期：/sys/class/net/wwan0 與 /dev/cdc-wdm0 出現
```

### B. 永久 kernel patch
1. 在 kernel source `drivers/net/usb/qmi_wwan.c` 加一行：
   ```c
   {QMI_MATCH_FF_FF_FF(0x2c7c, 0x030b)},   /* Quectel EM060K-GL */
   ```
2. 重編 `qmi_wwan.ko`，scp 到 target 取代 `/lib/modules/$(uname -r)/kernel/drivers/net/usb/qmi_wwan.ko`
3. `depmod -a`，reboot 或重 modprobe

### C. Quectel 官方 driver
- Quectel Linux & Android QConnectManager package
- 內含 patched `option.c` / `qmi_wwan.c`，多家 modem 都涵蓋
- 注意要避免跟 in-kernel driver 衝突 (blacklist or 卸除 in-kernel module)

可能原因：
1. **Modem firmware 異常 / 卡在 boot loader**
2. **PMU 上電 sequence 不對**：M.2 slot 的 `W_DISABLE1#` / `W_DISABLE2#` / `FULL_CARD_POWER_OFF#` / `PERST#` 沒正確拉
3. **Device Tree 沒設定 modem power 控制 node**，所以 modem 在開機後沒被 release reset

## Suggested Next Steps (need user approval before writes)

### 唯讀進一步檢查
- [ ] `dmesg` 全量看是否有 reset/disconnect/reconnect 循環
- [ ] `cat /sys/bus/usb/devices/3-1.4/power/wakeup` 與 autosuspend 狀態
- [ ] 找 device tree 中 M.2 slot 的 modem-power / regulator / gpio-hog node
- [ ] `cat /sys/kernel/debug/gpio` 看 W_DISABLE / RESET 線狀態
- [ ] 看 `/sys/bus/usb/devices/3-1.4/descriptors` 原始 USB descriptor

### 嘗試動作（需確認）
- [ ] `echo 0 > /sys/bus/usb/devices/3-1.4/authorized; sleep 1; echo 1 > ...` — 軟性重新 enumerate
- [ ] `usb_modeswitch` 強制切換（若有對應 mode-switch rule）
- [ ] 物理拔插 modem
- [ ] 透過 GPIO 拉 W_DISABLE# 重置 modem
- [ ] 換用 Quectel 官方 driver patch（Quectel_Linux&Android_QConnectManager），它會 patch option.c / qmi_wwan.c 增加 ipFF 支援



## Reference
- Quectel EM060K-GL 預期 USB composition (PID 0x030B):
  if0: DM (vendor) — option ipFF? or ip40
  if1: NMEA — option ip30
  if2: AT — option ip40
  if3: AT — option ip40
  if4: QMI/RmNet — qmi_wwan in04 (但 030B 在 in-tree qmi_wwan 沒登錄)
- 030B 在某些 firmware 版本是 MBIM-only — 那會是 cdc_mbim 接管

---

## 🔌 Hardware GPIO 排查清單 — M.2 B Key Pins Worth Checking

> **背景**：driver patch 完成後 modem 仍卡在 diagnostic-only mode (`bNumEndpoints==2`)，
> 觸發 `qmi_wwan.c:1575` ENODEV 拒絕。問題很可能在 **M.2 B Key 控制腳的 GPIO 預設狀態不對**，
> 讓 modem 沒進入 application composition。
>
> 模組裝在 carrier 板 **M2B1 connector (sheet 21)** — 2280 form factor，M.2 B Key。

### Priority 1 — ⭐ 最可疑 (power / radio enable)

| M.2 pin | 訊號名稱 | Carrier net (3.3V side) | Carrier net (1.8V SOC side) | 預期狀態 | 備註 |
|---|---|---|---|---|---|
| **6** | `FULL_CARD_POWER_OFF#` | `CARD_POWER_OFF_3V3` | `CARD_POWER_OFF` | **HIGH** (=power on) | ⭐ 最可疑。LOW 會把整張卡關電/降規格 |
| **8** | `W_DISABLE1#` | `WWAN_DISABLE#_3V3` | `WWAN_DISABLE#` | **HIGH** (=radio on) | 廠商常見 default LOW 害 RF block disable |
| **22** | `DPR` / `SAR_DPR1` | (直接 1.8V) | `EIP503_M2B1_SAR_DPR1` | 依設計 | SAR sensor; LOW 通常 = reduce TX power |

> ⚠️ `CARD_POWER_OFF_3V3` 經過 Q24 MOSFET 才到 M.2 connector，**SOC 端 (1.8V `CARD_POWER_OFF`) 讀值較可靠**。

### Priority 2 — reset / link 控制

| M.2 pin | 訊號名稱 | Carrier net | 預期狀態 | 備註 |
|---|---|---|---|---|
| 50 | `PERST#` | `PLTRST_M2B1#` ← `SLP_S3#` | HIGH (=de-asserted) | PCIe 模式才有意義；USB 模式仍要 de-asserted |
| 67 | `RESET#` | `M2B1_RESET#` ← `EIP503_M2B1_1V8_RESET#` | HIGH (=de-asserted) | LOW = modem held in reset → 不會 enumerate；但我們已 enum 成功，所以多半 OK |

### Priority 3 — configuration (host 讀)

| M.2 pin | 訊號 | 備註 |
|---|---|---|
| 1, 21, 69, 75 | `CONFIG_0..3` | 模組端 pull，host 讀來判斷模組類型；通常不會是問題，但值得 dump |

### 訊號鏈速查 (carrier sheet 21 → U58 level shifter → COMHPC → SOC sheet 51)

```
M.2 pin 6  FULL_CARD_POWER_OFF#   ← CARD_POWER_OFF_3V3 ← (U58)  ← CARD_POWER_OFF      (1.8V)
M.2 pin 8  W_DISABLE1#            ← WWAN_DISABLE#_3V3  ← (U58)  ← WWAN_DISABLE#       (1.8V)
M.2 pin 67 RESET#                 ← M2B1_RESET#       (1.8V)   ← EIP503_M2B1_1V8_RESET#
M.2 pin 50 PERST#                 ← PLTRST_M2B1#               ← SLP_S3#
M.2 pin 22 DPR                    ← (1.8V 直通)                ← EIP503_M2B1_SAR_DPR1
```

### TODO — 等使用者找完 SOC GPIO 對應
- [ ] carrier sheet 28 (COMHPC connector) → 哪根 pin 走 `CARD_POWER_OFF` / `WWAN_DISABLE#` / `EIP503_M2B1_1V8_RESET#` / `EIP503_M2B1_SAR_DPR1`
- [ ] SOC module sheet 51 (EXMP-Q911) → 同名 net 走到 QCS9075 哪根 `GPIO_xx`
- [ ] 拿到 GPIO 號後寫個 read script (sysfs `/sys/kernel/debug/gpio` 或 `gpioget`) 驗預期值
- [ ] 若 `CARD_POWER_OFF` 或 `WWAN_DISABLE#` 被拉錯，找 DT (`gpio-hog` / `regulator-fixed` / `modem-power` node) 或 userland boot script 改正

### 排查順序建議
1. 先 `cat /sys/kernel/debug/gpio | grep -iE 'modem|wwan|m2|disable|power_off'` 看有沒有現成 label
2. 對應 SOC GPIO 號出來後 `gpioget` 或 `cat /sys/class/gpio/...` 比對預期值
3. 任何 GPIO 拉錯 → 找 DT 來源 (`grep` `gpio-hog` 或 `output-high/low` in dtb decompile)
4. 若 GPIO 都對但仍 diagnostic-only → 是 **modem firmware** 問題，走 QFirehose reflash 或找 Quectel FAE

---

## 📡 Modem 撥號能力的「七層分級」 (硬體上來、軟體下去都看這張)

每一層卡住要看不同地方。**先確認自己卡在哪一層再對症**。

| 層 | 名稱 | 驗證指令 | 卡住代表 |
|---|---|---|---|
| L0 | USB enumerate | `lsusb \| grep 2c7c` | 上電 / W_DISABLE / RESET GPIO 異常；或卡 EDL (1 interface + 2 bulk EP) |
| L1 | Driver bind | `ls /dev/cdc-wdm0 /dev/ttyUSB*` | driver alias 沒涵蓋 PID；class 對不上 |
| L2 | AT 控制通道 | `echo ATI > /dev/ttyUSB2` 看回應 | 沒有 AT port、port-type 標錯 |
| L3 | SIM 解鎖 | `mmcli -m 0` 看 unlock retries / sim path | PIN 鎖住、SIM 接觸不良 |
| L4 | Network registration | `mbimcli ... --query-registration-state` → `home/roaming` | 訊號弱、漫遊未授權、APN 帳單問題 |
| L5 | Packet service attach | `mbimcli ... --query-packet-service-state` → `attached` | 核網拒絕 attach、APN 鎖區 |
| L6 | Bearer / PDP context | MBIM `--connect` OK / `mmcli --simple-connect` | 韌體 vendor init 沒做（如 EM060K-GL NotInitialized）／APN 錯 |
| L7 | Data plane (real packets) | `ip a show wwan0\|ppp0` 有真實 IP + `ping` 通 | wwan0 / ppp0 沒拉、route 沒設、DHCP 沒跑、**或 PPP 沒人 spawn** |

### 本案 EM060K-GL 卡在哪？

```
L0 ✓ → L1 ✓ → L2 ✓ → L3 ✓ → L4 ✓ → L5 ✓ → L6 ⚠️ → L7 ❌
                                                    ↑
                              MM 說 connected 是假象、實際 PPP/MBIM 沒人接手
```

L6 表面通，L7 完全死。**這正是「SIM 認得到但撥不上網」的標準病徵**。

---

## 🏆 突破 (2026-05-29) — EM060K-GL 在現 BSP 撥通了

**用 `mbim-network` wrapper（libmbim 官方撥號腳本）打通**，BSP 不用動：

```
wwan0: inet 10.233.74.136/28  ← 中華電信真實 IP
default via 10.233.74.137 dev wwan0
DNS 168.95.1.1
ping 8.8.8.8: 4/4, ~110ms
DNS resolve google.com: OK
下載 5MB / 21s ≈ 1.9 Mbps (訊號弱不是協定問題)
```

### `NotInitialized` 真正原因 — **不是 firmware bug，是我們自己留下的爛攤子**

之前手刻 `mbimcli -p --connect --no-close` 失敗後，**半開的 MBIM session (TRID=4 卡住)** 一直在 mbim-proxy 內部。後續任何 `--connect` 都繼承這個壞 state → `NotInitialized`。`mmcli --disable/--enable` 不會清這層底層 session。

`mbim-network` 做對的事：**嚴格按 sequence 一次跑完，不留半開狀態**
```
query-subscriber-ready  →  query-registration  →  attach-packet-service  →  --connect
```

### 操作流程（已驗證可重複）

```bash
# Target 上：
echo -e "APN=internet\nPROXY=yes" > /etc/mbim-network.conf
mbim-network /dev/cdc-wdm0 start    # 撥號
ip link set wwan0 up
udhcpc -i wwan0 -q -n -t 5          # 取 IP
# ping 8.8.8.8 → 通

mbim-network /dev/cdc-wdm0 stop     # 斷線
```

→ 已封裝為 [`mbim.sh`](./mbim.sh)（含 MM 自動避讓、EXIT 還原）。

---

## 🧱 BSP 補丁 — 從「必要」降為「升級體驗用」 (重新評估)

⚠️ **下面這節是「升級到 MM/NM 自動化」用的，不是「能不能撥」**。手動 mbim.sh 走 mbim-network 路徑已經可以撥通。

### 補了會多得到什麼

| 部件 | 補完的好處 |
|---|---|
| ModemManager 加 `--with-mbim` `--with-qmi` | MM 可以自己呼 MBIM/QMI 連線，不用手 script |
| `ppp` 套件 | 老 modem (3G dongle) 的 PPP fallback path 可用 |
| `networkmanager-plugin-wwan` | nmcli con add type gsm + 自動 monitor / auto-reconnect |
| udev rule for PID 030B | （已決定不做）純優化、應屬 upstream MM |

### 不補的影響

| 場景 | 不補也能用？ |
|---|---|
| 一次性測試撥號 | ✅ `mbim.sh` (mbim-network 路徑) |
| 自動 boot 起來就撥 | ⚠️ 要寫 systemd unit 包 mbim.sh |
| Plug-and-play (插不同 modem 都通) | ❌ 沒 MM-MBIM 還是要手選撥號方式 |
| 漫遊自動切換 / SIM 熱插拔 | ❌ 需要 MM auto-management |
| Carrier-grade 體驗 | ❌ 需要 MM + NM-wwan plugin |

### 哪些模組會卡到要這套 BSP 補丁？

| 類型 | 例子 | 走得通的方式 | 需要本次 BSP 補丁？ |
|---|---|---|---|
| 「合作型」MBIM (standalone `mbimcli --connect` 直接成功) | EM7595、MV31W | 走 mbim.sh + udhcpc，**完全不靠 MM/NM/pppd** | ❌ 不需要（但裝了更穩） |
| 「合作型」QMI (vendor 提供 raw IP) | 部分 Sierra、舊 Quectel EC25 | `qmicli --wds-start-network=` + udhcpc | ❌ 不需要 |
| 「需要 vendor init」 MBIM (`--connect` 回 NotInitialized) | **EM060K-GL、MV32W-A** | 必須走 ModemManager 的 quectel/telit plugin 做 init | ✅ **必須** |
| 純 PPP-only 模組 | 老 3G dongle、AT-only modem | 必須 pppd + chat | ✅ **必須 pppd** |

> 判斷規則：
> 1. 先試 `mbim.sh` (或 `qmicli --wds-start-network`)
> 2. 過了 → 模組屬於「合作型」、目前 BSP 夠用、可忽略本節
> 3. 撞到 `NotInitialized` 或 modem 卡 L6/L7 → 必須補 BSP

### BSP 修法（給多客戶共用 image，只動三件套）

```bitbake
IMAGE_INSTALL:append = " ppp networkmanager-plugin-wwan"
PACKAGECONFIG:append:pn-modemmanager = " mbim qmi"
```

> **不加** vendor-specific udev rule 進 BSP — 那是優化不是必要件，且為單一 PID 寫死規則不適合多客戶 image。
> 本目錄的 [`77-mm-quectel-em060k-030b.rules`](./77-mm-quectel-em060k-030b.rules) 留作 **target 上手動測試** 用（先丟 `/etc/udev/rules.d/` 看 MM 行為有沒有變好），確認有用再考慮要不要送 upstream MM。

完整 BSP prompt（給另一個 Claude session 寫 .bb 用）見 [bsp-prompt.md](./bsp-prompt.md)。

詳細的 stack / 協議 / debug flow 看 [modem-guide.md](./modem-guide.md)。
