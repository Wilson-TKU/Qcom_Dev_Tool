# Linux Modem 上層軟體架構完整解析

> 從 kernel driver 到 nmcli 之間的所有層，每層在幹嘛、為何存在、互相怎麼講話。
> 看完應該能回答：「我這台要撥號為什麼要選 mbim-network 而不是 mmcli？」

---

## 1. 整體分層圖

```
                          ┌──────────────────────────┐
        Application      │ 你的測試 script / 瀏覽器 │
                          └────────────┬─────────────┘
                                       │ TCP/IP socket
   ─────────────────────────────────── │ ───────────────────────────
                                       │
                          ┌────────────▼─────────────┐
        系統服務         │     ModemManager (MM)    │ ← 自動撥號 / 漫遊 / 多 modem 管理
        (daemons)        │   - quectel/sierra plugin │
                          │   - DBus API              │
                          └────────────┬─────────────┘
                                       │ DBus
                          ┌────────────▼─────────────┐
                          │   NetworkManager (NM)    │ ← IP / route / DNS / DHCP
                          │   - gsm connection profile│
                          └────────────┬─────────────┘
                                       │
   ─────────────────────────────────── │ ───────────────────────────
                          ┌────────────▼─────────────┐
        CLI 工具         │  mmcli / nmcli           │ ← human-facing 操作
                         │  mbimcli / qmicli        │ ← raw MBIM/QMI 命令
                         │  mbim-network / qmi-network │ ← 撥號 wrapper
                          └────────────┬─────────────┘
                                       │ libmbim / libqmi C API
   ─────────────────────────────────── │ ───────────────────────────
                          ┌────────────▼─────────────┐
        Library (.so)    │  libmbim-glib            │
                         │  libqmi-glib             │
                          └────────────┬─────────────┘
                                       │
                          ┌────────────▼─────────────┐
        Multiplexer      │  mbim-proxy / qmi-proxy  │ ← /dev/cdc-wdm0 一次只能一人開
        (daemons)        │  (libmbim/libqmi spawn)  │   proxy 解決多 client 共用
                          └────────────┬─────────────┘
                                       │ ioctl + read/write
   ─────────────────────────────────── │ ───────────────────────────
                          ┌────────────▼─────────────┐
        Kernel drivers   │  cdc_mbim  qmi_wwan      │
                         │  option / usb_wwan       │
                         │  cdc_wdm  usbnet          │
                          └────────────┬─────────────┘
                                       │ USB
                                       ▼
                              Modem (Quectel EM060K-GL)
```

---

## 2. Kernel Driver 層

USB 上跑的 modem driver 在 kernel 內負責「把 USB endpoint 變成 char/net device」。

### 2.1 三組主要 driver

| Driver | 接哪種 interface | 提供出什麼 | 怎麼 match |
|---|---|---|---|
| **`cdc_mbim`** | USB class=02/0E/00 | `/dev/cdc-wdm0` + `wwan0` net device | **USB class 簽章** — 不需 PID |
| **`qmi_wwan`** | Qualcomm vendor-specific QMI | `/dev/cdc-wdm0` + `wwan0` net device | **PID 表** — driver 源碼裡要列 PID |
| **`option`** | USB serial (AT/DM/NMEA) | `/dev/ttyUSB[0-3]` | **PID alias** in modules.alias |

### 2.2 為什麼這分類重要？

碰到新 modem 撥不上時，**先看 driver 有沒有 bind**：

```bash
for i in /sys/bus/usb/devices/*:*.* ; do
    name=$(basename $i)
    drv=$(readlink $i/driver 2>/dev/null | xargs basename)
    cls=$(cat $i/bInterfaceClass)/$(cat $i/bInterfaceSubClass)/$(cat $i/bInterfaceProtocol)
    echo "$name  drv=${drv:-NONE}  class=$cls"
done
```

- **`drv=NONE`** = driver 沒接上 → 新 PID 沒在 driver table；解法：
  - `qmi_wwan` 沒認 → patch 加 PID + 重編 .ko (詳見 `qmi_wwan.patch`)
  - `cdc_mbim` 沒認 → 罕見，因為它靠 class match；通常是 modem 沒進 MBIM composition
  - `option` 沒認 → `echo "VID PID" > /sys/bus/usb-serial/drivers/option1/new_id`

### 2.3 wwan framework (新)

新 kernel (6.x+) 有 `/sys/class/wwan/` 框架，把 cellular modem 抽象成標準 device。但 QLI 1.8 (kernel 6.6) 上沒看到實際 wwan device 註冊。

---

## 3. 三種 Modem 控制協議 — PPP vs MBIM vs QMI

這三條是 host 跟 modem 講「**怎麼撥號、怎麼開 data session**」的協定。modem 韌體決定它支援哪幾個，host 決定要走哪一條。

### 3.1 PPP (Point-to-Point Protocol)

```
你 → /dev/ttyUSB2 → AT+CGDCONT → ATD*99# → pppd 接管 → ppp0 net device
```

- **特點**：1981 年的協定，跑在 RS-232/USB serial 上
- **速度**：受 serial bulk EP 限制，max ~12 Mbps
- **優點**：所有 modem 都支援；不挑韌體
- **缺點**：4G/5G 全速跑不出來；需要 `pppd` + `chat` 套件
- **適用**：老 3G dongle、PPP-only modem、低速備援

### 3.2 MBIM (Mobile Broadband Interface Model)

```
你 → mbimcli/mbim-network → /dev/cdc-wdm0 (control) → modem
                                      ↓ 撥通後
                              wwan0 net device → DHCP → 拿 IP
```

- **特點**：USB-IF 標準（2012），開放規格
- **驅動**：`cdc_mbim`
- **協議**：MBIM message (binary)，message 名叫 CID (Command ID)
- **速度**：全速 LTE/5G，沒上限
- **優點**：vendor-agnostic、cdc_mbim 靠 class 自動接
- **缺點**：MBIM message state 比 QMI 複雜，半開 session 容易出錯
- **適用**：現代 4G/5G modem 標準（EM060K-GL / MV32W-A / 多數新模組）

關鍵 CID：
| CID | 用途 |
|---|---|
| `device-caps` | modem 能力 (LTE band, IP type) |
| `subscriber-ready-status` | SIM ready 與否 |
| `register-state` | 電信註冊狀態 |
| `packet-service` | PS attach |
| `connect` | **撥號開 bearer**，撥號核心 |
| `ip-configuration` | 拿到 modem 端 IP/gateway/DNS |

### 3.3 QMI (Qualcomm MSM Interface)

```
你 → qmicli/qmi-network → /dev/cdc-wdm0 (control) → modem
                                  ↓ 撥通後
                              wwan0 net device → DHCP / raw-ip
```

- **特點**：Qualcomm proprietary（後來開源 libqmi），vendor-specific
- **驅動**：`qmi_wwan`
- **協議**：QMI message 拆成多個 service (WDS / DMS / NAS / WMS …)，每個 service 有自己的命令集
- **速度**：全速 LTE/5G
- **優點**：對 Qualcomm 系 modem 最原生、訊息穩定
- **缺點**：driver 要列 PID 才會接；vendor-locked
- **適用**：Sierra / 舊 Quectel EC25 等走 QMI composition 的模組

### 3.4 三條協議比較

| | PPP | MBIM | QMI |
|---|---|---|---|
| 標準化 | 老但開放 | USB-IF 標準 | Qualcomm，後 libqmi 開源 |
| Driver | usbserial+option+pppd | cdc_mbim | qmi_wwan |
| Char device | `/dev/ttyUSB*` | `/dev/cdc-wdm0` | `/dev/cdc-wdm0` |
| Net device | `ppp0` (pppd 起) | `wwan0` (driver 帶) | `wwan0` |
| 撥號工具 | `pppd` + chat | `mbimcli` / `mbim-network` | `qmicli` / `qmi-network` |
| Driver match | PID alias | USB class | PID 表 |
| 速度 | < 12 Mbps | full speed | full speed |

---

## 4. Library 層 — libmbim / libqmi

C library，把 MBIM/QMI binary protocol 包成好用的 API。

| Library | 提供 | 用它的工具 |
|---|---|---|
| `libmbim-glib` | MBIM message build/parse + transport | mbimcli, ModemManager (if `--with-mbim`) |
| `libqmi-glib` | QMI service handling | qmicli, ModemManager (if `--with-qmi`) |

**重要實測**：QLI 1.8 雖然 install 了 `libmbim` / `libqmi` 套件，**但 MM 二進位沒 link 它們**（`ldd /usr/sbin/ModemManager | grep -iE "mbim|qmi"` 是空的）。所以 MM 在這 BSP 上不能用 MBIM/QMI，只能下 AT 走 PPP。詳見 [`bsp-prompt.md`](./bsp-prompt.md)。

---

## 5. CLI 工具 — 五個常用兵器

### 5.1 `mbimcli` (libmbim 套件)

```bash
# 範例：查註冊狀態
mbimcli -d /dev/cdc-wdm0 -p --query-registration-state

# 撥號
mbimcli -d /dev/cdc-wdm0 -p --connect="access-string=internet,ip-type=ipv4"
```

- `-p` = 透過 mbim-proxy（建議永遠帶）
- 一次一個 CID。手刻整套撥號流程容易留半開 state（**我們踩過這坑**）

### 5.2 `mbim-network` (libmbim-utils 套件) ⭐

libmbim 官方撥號 wrapper script，**強烈推薦撥號用這支**：

```bash
echo -e "APN=internet\nPROXY=yes" > /etc/mbim-network.conf
mbim-network /dev/cdc-wdm0 start    # 撥號
mbim-network /dev/cdc-wdm0 stop     # 斷線
```

它把 `query-subscriber-ready → query-registration → attach-packet-service → connect` 嚴格按 sequence 跑完，**不會留半開 session**。

→ 這就是為何 `mbim.sh` 走 `mbim-network` 而不是手刻 `mbimcli`。

### 5.3 `qmicli` / `qmi-network` (libqmi-utils 套件)

對照 mbimcli/mbim-network，但走 QMI。EM060K-GL 在 MBIM composition 用不到，留作其他 QMI 模組備用。

### 5.4 `mmcli` (ModemManager 套件)

ModemManager 的 CLI：

```bash
mmcli -L                            # 列出 modem
mmcli -m 0                          # 看 modem 詳細
mmcli -m 0 --enable                 # 啟用
mmcli -m 0 --simple-connect="apn=internet"  # 撥號（透過 MM）
mmcli -m 0 -b 0                     # 看 bearer
mmcli -m 0 --command='AT+CSQ'       # 下 AT (要 MM debug-mode)
```

走 MM 是「**高階介面**」：你不直接碰 MBIM/QMI message，MM 幫你抽象掉。

### 5.5 `nmcli` (NetworkManager 套件)

NetworkManager 的 CLI，管 IP/route/DNS：

```bash
nmcli con add type gsm con-name 5g apn internet
nmcli con up 5g
nmcli con show --active
```

理論上 NM 會 talk to MM，MM 撥通，NM 配 IP。要求 NM build 時有 wwan plugin（QLI 1.8 沒含）。

---

## 6. Proxy 層 — mbim-proxy / qmi-proxy

### 6.1 為什麼需要 proxy

`/dev/cdc-wdm0` 是 char device，**一次只允許一個 process open**。

但實際情境常常多人想用：
- ModemManager 開機就在 monitor
- 你的 mbim.sh 要撥號
- 你想 mbimcli query 狀態看訊號

如果直接 open `/dev/cdc-wdm0`，第二個人就會被拒。

### 6.2 Proxy 怎麼解決

```
          ┌───────────────┐
          │ ModemManager  │──┐
          └───────────────┘  │
                              │
          ┌───────────────┐  │     ┌──────────────┐    ┌──────────────┐
          │ mbimcli -p    │──┼──→  │ mbim-proxy   │──→ │/dev/cdc-wdm0 │
          └───────────────┘  │     │ (1 個 open) │    └──────────────┘
                              │     └──────────────┘
          ┌───────────────┐  │
          │ mbim-network  │──┘
          └───────────────┘
```

- `/usr/libexec/mbim-proxy` 由 libmbim 自動 spawn
- 任何 `mbimcli -p` / `mmcli` 都連 proxy，**不直接 open device**
- proxy 替每個 client 維護獨立 session 但共享 transport

### 6.3 Proxy 的副作用

mbim-proxy 是常駐 daemon，**它有 state**。如果某個 client 的 session 出問題（如 `--no-close` 後 process 死掉），proxy 內可能殘留半開 session。

清掉 proxy state：
```bash
pkill -f mbim-proxy
# 下次 mbimcli -p 會自動 spawn 新的
```

---

## 7. Daemon 層 — ModemManager / NetworkManager

### 7.1 ModemManager (MM)

systemd 服務，**modem 的全自動經紀人**：
- 偵測新 modem (透過 udev) → 自動 enable
- 透過 plugin 識別 vendor (Quectel / Sierra / Telit ...)
- 自動處理 SIM PIN / 註冊 / packet attach / 撥號
- 提供 DBus API 給上層（NM / mmcli / 應用程式）使用

#### MM Plugin 機制

`/usr/lib/ModemManager/libmm-plugin-*.so` — 每家廠商一個 plugin，處理 vendor 特殊命令。例如 quectel plugin 知道：
- EM060K-GL 用 MBIM 撥號
- 需要的 AT init 序列
- AT+QCFG / AT+QGPS 等 Quectel 私有命令

→ 這是「**MM 比手刻 mbimcli 強**」的本質：它已經幫你處理 vendor 怪癖。

#### MM 在 QLI 1.8 的限制

`ldd /usr/sbin/ModemManager | grep -iE "mbim|qmi"` 空 → **MM 沒 link libmbim/libqmi** → 不能走 MBIM/QMI，只能 AT。MM 想撥就只能 PPP，但又沒 pppd。**結果 MM 在這 BSP 上撥不通**。

### 7.2 NetworkManager (NM)

systemd 服務，**IP 層的管家**：
- 看到 net device → 自動配 IP（DHCP / 靜態 / link-local）
- 維護 connection profile（gsm / ethernet / wifi）
- talk to ModemManager 處理 cellular（透過 wwan plugin）

#### NM-WWAN Plugin

`networkmanager-plugin-wwan` 提供 `libnm-device-plugin-wwan.so`：
- NM 透過它 talk to MM
- 提供 `type=gsm` connection profile
- `nmcli con up gsm-xxx` → NM 找到 modem → 叫 MM 撥號 → NM 配 IP/route

#### NM 在 QLI 1.8 的限制

`nmcli general status` 顯示 `WWAN-HW: missing` → **NM 沒含 wwan plugin** → 看不到 modem，`nmcli con up gsm-xxx` 比對到 `lo` 報錯。

---

## 8. 兩條撥號路徑完整對比

### Path A：手動 — `mbim.sh` (本案目前用這條)

```
你 ─── ./mbim.sh
        │
        ├─ mmcli -m 0 --disable           ← 請 MM 放手
        │
        └─ mbim-network /dev/cdc-wdm0 start
                │
                ├─ mbimcli --query-subscriber-ready -p
                ├─ mbimcli --query-registration-state -p
                ├─ mbimcli --attach-packet-service -p
                └─ mbimcli --connect=apn=internet -p
                        │
                        └─ libmbim-glib
                                │
                                └─ mbim-proxy
                                        │
                                        └─ /dev/cdc-wdm0
                                                │
                                                └─ cdc_mbim driver
                                                        │
                                                        └─ Quectel EM060K-GL
```

✅ **優點**：
- 不依賴 MM / NM
- 適用所有 BSP（不需要重編 image）
- script 邏輯透明，好 debug

⚠️ **限制**：
- 手動跑（要寫 systemd unit 才能 boot 自動）
- 多 modem 環境要自己 select
- 沒漫遊自動處理 / SIM 熱插拔監控

### Path B：自動 — ModemManager + NetworkManager (BSP 升級後可用)

```
你 ─── nmcli con up 5g
        │
        └─ NetworkManager (DBus)
                │
                ├─ libnm-device-plugin-wwan.so
                │
                └─ ModemManager (DBus)
                        │
                        ├─ libmm-plugin-quectel.so   ← vendor magic
                        │
                        └─ libmbim-glib
                                │
                                └─ mbim-proxy
                                        │
                                        └─ (相同的 kernel/modem path)
```

✅ **優點**：
- 全自動：boot 起來自動撥
- 漫遊 / SIM 熱插拔 / 訊號掉了自動重連
- 多 modem 環境自動 select

⚠️ **需求**：
- MM build 含 `--with-mbim --with-qmi`
- 裝 `ppp` 套件（PPP fallback 用）
- 裝 `networkmanager-plugin-wwan`

QLI 1.8 預設 image 三項都缺，要重 build BSP 才能走 Path B。詳見 [`bsp-prompt.md`](./bsp-prompt.md)。

### 怎麼選

| 你的需求 | 走哪條 |
|---|---|
| 開發 / 測試 / 一次性撥號 | **Path A (`./mbim.sh`)** |
| 給多客戶用的產品 image | Path B（升級 BSP） |
| 一張 modem 寫死 APN 跑到底 | Path A + 寫 systemd unit |
| 多 SIM / 多 modem / 漫遊切換 | Path B |
| 想自己包成產品的 fallback | Path A 為主 + 加 systemd timer 自動重試 |

---

## 9. 各 modem 廠商實戰建議

| 廠商/型號 | 主流 composition | 建議走 |
|---|---|---|
| Quectel EM060K-GL | MBIM | **Path A (mbim.sh)** 已驗證 |
| Quectel MV32W-A | MBIM | Path A (預期同 EM060K-GL) |
| Quectel EC25 (舊) | QMI / AT | qmi-network (Path A 變體) |
| Sierra EM7595 | QMI / MBIM | Path A 通 |
| Telit MV31W | MBIM | Path A 通 |
| Telit FN980 | MBIM | Path A 預期通 |
| 3G dongle (老) | PPP-only | 需 ppp 套件，目前 BSP 沒裝 |

通用判斷流程：

```
1. lsusb 看 modem 在
       ↓
2. ls /dev/cdc-wdm0 → 有 → 走 MBIM/QMI
   沒有但有 /dev/ttyUSB* → 走 PPP (需 pppd)
       ↓
3. mbim.sh 試撥
       ↓ 通 → 收工
       ↓ 不通 → 看 modem-guide.md §10 cheat sheet
```

---

## 10. 關鍵設計問題 Q&A

**Q1: 為什麼 `--connect` 會 NotInitialized？這次學到什麼？**

A: 上一個 mbimcli `--no-close` 後 session 半開，mbim-proxy 內部 state 卡住。後續 `--connect` 繼承壞 state。**修法**：用 `mbim-network` 一次跑完不留半開；或 `pkill mbim-proxy` 清掉。

**Q2: 為什麼 cdc_mbim 能無痛接 EM060K-GL 但 qmi_wwan 要 patch？**

A: cdc_mbim 用 USB CDC class match（class=02/0E/00 自動接），qmi_wwan 用 PID match table。MBIM 是標準、QMI 是 vendor-specific。

**Q3: mbim-proxy 跟 mbim-proxy daemon 是同一個嗎？**

A: 是。`/usr/libexec/mbim-proxy` 是 libmbim 自動 spawn 的常駐 daemon。一台機器只跑一份。

**Q4: ModemManager 跟 NetworkManager 是必要的嗎？**

A: 都不必要。MM 是「modem 自動管理」、NM 是「IP 自動管理」。你完全可以手刻撥號 + 手動 `ip addr add`，完全不裝 MM/NM 也能上網。

**Q5: 為什麼 modem 撥通後是 wwan0，但有時是 ppp0？**

A: 看走哪條協議：
- MBIM / QMI → wwan0（kernel net device，driver 直接帶出來）
- PPP → ppp0（pppd 跑起來才動態建立）

---

## 11. 延伸閱讀

- libmbim 官方文件: https://gitlab.freedesktop.org/mobile-broadband/libmbim
- libqmi 官方文件: https://gitlab.freedesktop.org/mobile-broadband/libqmi
- ModemManager: https://modemmanager.org
- MBIM v1.0 spec: USB-IF MBIM Revision 1.0
- 3GPP TS 27.007 (AT command set)
- 本目錄：
  - 操作面 → [`README.md`](./README.md)
  - 完整技術參考 → [`modem-guide.md`](./modem-guide.md)
  - 本案 debug 紀錄 → [`NOTES.md`](./NOTES.md)
  - BSP 升級指南 → [`bsp-prompt.md`](./bsp-prompt.md)
