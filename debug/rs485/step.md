# RS-485 逐步驗證 + 量測紀錄表（exmp-q911 / SA8775P / F81439A）

> 規則：**從上往下做、做完一步把結果寫進「📝 觀察」欄、不要跳級**。
> 卡住就停在那一步把 `🔧 如果不過怎麼辦` 跑完再往下。
>
> 平台：Innodisk exmp-q911，Qualcomm SA8775P，kernel 6.6.119-qli，transceiver = **F81439A** (mode-selectable RS-232/422/485)
> 目標：`/dev/ttyHS1` (UART1，SoC GPIO 控 M0/M1/M2) 與 `/dev/ttyHS2` (UART2，TCA6408 I²C expander 控 M0/M1/M2)

---

## 參考表（先記住，後面一直用）

### F81439A mode pin → 模式

| M0 | M1 | M2 | 模式 | TX_EN 極性 |
|---|---|---|---|---|
| 0 | 0 | 0 | RS-422 全雙工 | — |
| 0 | 0 | 1 | **Pure RS-232（power-on 預設）** | — |
| 0 | 1 | 0 | RS-485 半雙工 | **Low Active** |
| 0 | 1 | 1 | RS-485 半雙工 | **High Active** |
| 1 | 0 | 0 | RS-422 + 內建 term/bias | — |
| 1 | 0 | 1 | RS-232 與 RS-485 共存 | — |
| **1** | **1** | **0** | **RS-485 + 內建 term/bias** | **Low Active** ← 本機選這個 |
| 1 | 1 | 1 | Shutdown (高阻抗) | — |

### GPIO 對應

| UART | TTY | M0 GPIO | M1 GPIO | M2 GPIO | 控制器 |
|---|---|---|---|---|---|
| UART1 | `/dev/ttyHS1` | 639 | 640 | 641 | SoC tlmm (pin 79/80/81) |
| UART2 | `/dev/ttyHS2` | 711 | 712 | 713 | TCA6408 I²C expander |

### 工具一覽（/root 下）

| 工具 | 做什麼 |
|---|---|
| `exmp-serial-ctrl <m1> <m2>`   | 設 mode pins + 開 kernel RS-485 (RTS_ON_SEND，**High Active**) |
| `exmp-serial-ctrl-R <m1> <m2>` | 設 mode pins **(1,1,0)** + 開 kernel RS-485 (RTS_AFTER_SEND，**Low Active**) ← 我們要用這個 |
| `rs485-toggle <tty> <on/off>`   | 只切 kernel `TIOCSRS485` flag (High Active)，不動 mode pins |
| `rs485-toggle-R <tty> <on/off>` | 只切 kernel `TIOCSRS485` flag (Low Active)，不動 mode pins |
| `rs485-manual <tty> <hi/lo> <baud> <payload>` | **繞過 kernel RS-485**、手動把 RTS 鎖在 hi/lo 後寫資料 → 用來證明 RTS 真的能拉動 TX_EN |
| `rts-probe <tty> <get/set-high/set-low/pulse N>` | 看 / 切 / 脈衝 RTS，配示波器 |

### 你 host 端的 DTS pin 可動旋鈕（先擺著）

```dts
&qup_uart3_cts { bias-pull-up; };   // → 對 F81439A 的 CTS 腳
&qup_uart3_rts { bias-disable; };   // → 對 F81439A 的 TX_EN 腳（最關鍵！）
&qup_uart3_tx  { bias-disable; };
&qup_uart3_rx  { bias-pull-up; };
```

⚠️ 確認一下：DTS 裡這 4 個是 `qup_uart3_*`，但板子上跑起來是 `ttyHS1` / `ttyHS2`，**Step 0** 要先對上是不是同一條。

---

## 設備檢查清單（開工前）

```
[ ] adb 連得到板子          adb devices
[ ] 示波器 4 通道，差動探棒或兩支單端探棒做 MATH = CH3-CH4
[ ] 對端 USB-RS485 dongle（host PC），或拿 ttyHS1 ↔ ttyHS2 互打
[ ] 找到原理圖上 TXD / RTS / A / B 的測試點
```

---

# STEP 0 — 先確認手上的 DTS 改的是哪一條 UART

**目的**：你 host 端在改的 `qup_uart3_*` 到底對到板子的哪個 `ttyHS?`，先綁好。

```bash
adb shell dmesg | grep -iE "geni.*ttyHS|qup.*uart|988|98c|990|994|998|99c" | head -20
adb shell "ls -l /sys/class/tty/ttyHS1/device /sys/class/tty/ttyHS2/device"
adb shell "cat /sys/class/tty/ttyHS1/device/of_node/name 2>/dev/null; echo ---; cat /sys/class/tty/ttyHS2/device/of_node/name 2>/dev/null"
```

預期看到類似 `988000.serial → ttyHS1`、`98c000.serial → ttyHS2` 之類的對應。

📝 觀察（填）：
```
ttyHS1 = ____________  (e.g. 988000.serial = qup_uart?)
ttyHS2 = ____________
你改的 qup_uart3_* 對應到 = ____________
```

🔧 如果不過：dmesg 沒看到 ttyHS → driver 沒起來，往 dts status / pinctrl 找；先別動硬體。

---

# STEP 1 — 讀目前的「靜態狀態」（不改任何東西，純拍照）

**目的**：記下「現在這一刻」的 mode pin、RS-485 flag、RTS 線，後面變動才有對照。

```bash
# 1.1 mode pin (六個 GPIO 都看)
adb shell "for g in 639 640 641 711 712 713; do
  [ -d /sys/class/gpio/gpio$g ] || echo $g > /sys/class/gpio/export 2>/dev/null
  printf 'gpio%-4s value=%s direction=%s\n' \"$g\" \"$(cat /sys/class/gpio/gpio$g/value 2>/dev/null)\" \"$(cat /sys/class/gpio/gpio$g/direction 2>/dev/null)\"
done"

# 1.2 kernel RS-485 flag
adb shell "cat /sys/class/tty/ttyHS1/rs485* 2>/dev/null; echo ---; cat /sys/class/tty/ttyHS2/rs485* 2>/dev/null"

# 1.3 RTS / CTS 等 modem control 線
adb shell /root/rts-probe /dev/ttyHS1 get
adb shell /root/rts-probe /dev/ttyHS2 get

# 1.4 dmesg 有沒有錯誤連發
adb shell "dmesg | tail -50"
```

📝 觀察（填）：
```
UART1 mode pins: M0=__ M1=__ M2=__  →  推測模式 = __________
UART2 mode pins: M0=__ M1=__ M2=__  →  推測模式 = __________
ttyHS1 rs485 flags = __________
ttyHS2 rs485 flags = __________
ttyHS1 RTS = __  ttyHS2 RTS = __
dmesg 有無 framing / overrun / break ? ____
```

🔧 預期：剛開機通常 mode = (0,0,1) = **RS-232**，這就是上一輪 debug 的 root cause。

---

# STEP 2 — 控制組：先用 RS-232 loopback 證明「tty 上層 + 線都活的」

**目的**：把 ttyHS1 跟 ttyHS2 拉成 RS-232 模式，互相收送。**通**了才能說「問題只剩 RS-485 那段」；不通就是更基本的問題。

```bash
# 2.1 兩條都切到 RS-232 (M=0,0,1)，kernel RS-485 off
adb shell /root/exmp-serial-ctrl 232 232

# 2.2 確認真的切過去
adb shell "for g in 639 640 641 711 712 713; do
  printf 'gpio%-4s = %s\n' \"$g\" \"$(cat /sys/class/gpio/gpio$g/value)\"
done"
# 預期：639=0 640=0 641=1   711=0 712=0 713=1
```

接線：把 **ttyHS1 的 TX 接到 ttyHS2 的 RX，ttyHS2 的 TX 接到 ttyHS1 的 RX**（RS-232 TTL 端，不是 A/B 那邊）。

```bash
# 2.3 設 baud + 開接收 terminal (背景)
adb shell "stty -F /dev/ttyHS1 115200 cs8 -parenb -cstopb -echo raw"
adb shell "stty -F /dev/ttyHS2 115200 cs8 -parenb -cstopb -echo raw"

# 2.4 HS2 接收 (在 host 開一個 adb shell)
adb shell "timeout 5 cat /dev/ttyHS2 | xxd"

# 2.5 另一個 host terminal，HS1 發送
adb shell "printf 'HELLO485\\n' > /dev/ttyHS1"
```

📝 觀察（填）：
```
HS1 → HS2 收到 = ____________  (預期: HELLO485)
HS2 → HS1 收到 = ____________
gpio639/640/641/711/712/713 = _________________
```

🔧 不過：
- 收到亂碼 → baud 設錯，或 stty 沒生效 (`stty -F /dev/ttyHS1 -a` 看一下)
- 完全收不到 → 線接錯（TX 對 TX 是錯的，要 TX→RX 交叉）
- 一邊通一邊不通 → 該邊的 TX or 對邊的 RX 有問題

---

# STEP 3 — 切到 RS-485 + 量測 GPIO 狀態

**目的**：用 `-R` 版本切到 mode (1,1,0) = RS-485 with internal term/bias, TX_EN Low Active。

```bash
# 3.1 兩條都切 RS-485
adb shell /root/exmp-serial-ctrl-R 485 485

# 3.2 驗 GPIO 全部翻
adb shell "for g in 639 640 641 711 712 713; do
  printf 'gpio%-4s = %s\n' \"$g\" \"$(cat /sys/class/gpio/gpio$g/value)\"
done"
# 預期：639=1 640=1 641=0   711=1 712=1 713=0

# 3.3 驗 kernel RS-485 flag
adb shell "cat /sys/class/tty/ttyHS1/rs485*"
adb shell "cat /sys/class/tty/ttyHS2/rs485*"
# 預期：flags 包含 SER_RS485_ENABLED + RTS_AFTER_SEND
```

📝 觀察（填）：
```
gpio 639/640/641 = ___ ___ ___    (預期 1 1 0)
gpio 711/712/713 = ___ ___ ___    (預期 1 1 0)
ttyHS1 rs485 flags = ____________
ttyHS2 rs485 flags = ____________
```

🔧 不過：
- 某 GPIO 沒翻 → `echo`/`export` 失敗，看 dmesg 有沒有 expander I²C 失敗 (`i2cdetect -y 0` 找 0x20)
- flag 沒上 → `rs485-toggle-R` 沒 build / 路徑錯

---

# STEP 4 — 示波器接好 + 量靜態（bus idle）

**目的**：開工前先記空閒狀態，這是 fail-safe biasing 是否生效的指標。

把示波器擺：

| 通道 | 接點 | 觸發 |
|---|---|---|
| CH1 | ttyHS1 的 SoC TXD pin（QUP UART TX） | — |
| CH2 | ttyHS1 的 SoC RTS pin（→ F81439A TX_EN） | falling edge (因為 Low Active) |
| CH3 | bus 上 A (D+) | — |
| CH4 | bus 上 B (D-)，MATH = CH3 − CH4 | — |

時間軸：先設 200 µs/格看 idle，等量到訊號再改 20 µs/格。

```bash
# 此時不送任何東西，只是 idle
adb shell /root/rts-probe /dev/ttyHS1 get
```

📝 觀察（idle）：
```
CH1 TXD idle 電壓     = ______ V  (預期 ~3.3 V high)
CH2 RTS idle 電壓     = ______ V  (Low Active：idle 應為 HIGH=未送)
CH3 A 對 GND          = ______ V
CH4 B 對 GND          = ______ V
MATH (A-B)            = ______ V  (預期 ≥ +200 mV 才有 fail-safe)
```

🔧 不過：
- A-B 在 0 V 附近抖 → 內建 bias 沒上 (mode 沒切到 1,1,0)，回 Step 3
- A、B 浮接 (∞)  → transceiver 沒供電或 mode 進了 shutdown (1,1,1)
- RTS idle 是 LOW (應該 HIGH) → kernel rs485 flag 設錯極性，回 Step 3 看 flag

---

# STEP 5 — 開始打資料 + 量「動態波形」

**目的**：產生連續 0x55 (`0101_0101`)，量四根 pin 的時序。0x55 在 UART 8N1 下會產生 50% duty 接近方波，最好量。

```bash
# 5.1 持續送 0x55 到 ttyHS1，直到你按 Ctrl-C
adb shell "while true; do printf '\\x55'; sleep 0.002; done > /dev/ttyHS1"
```

示波器設定：
- 觸發：CH2 RTS 下降邊（Low Active：RTS 拉 LOW 才開始送）
- 時間軸：20 µs/格（115200 → 一個 bit ≈ 8.68 µs）
- CH1/CH2/CH3/CH4 都打開

📝 觀察（動態，每格時間 = 8.68 µs / bit）：
```
[A] CH2 RTS：是否在送資料前一刻拉 LOW？      Y / N
[B] CH1 TXD：在 RTS=LOW 期間有 UART 位元串？  Y / N  bit-width = ____ µs
[C] CH3-CH4 (A-B)：跟著 TXD 翻？             Y / N  幅度 ≈ ____ V
[D] RTS 收尾：最後一個 stop bit 之後才拉 HIGH？ Y / N
[E] RTS LOW → TXD 第一個 start bit 的延遲 = ____ µs
[F] TXD 最後 stop bit → RTS HIGH 的延遲    = ____ µs
```

🔧 對照表：
| 看到 | 結論 / 下一步 |
|---|---|
| CH1 動、CH2 動、CH3-CH4 不動 | F81439A 的 DI 沒進、或 IC 沒切到 485；回 Step 3 確認 GPIO |
| CH1 動、CH2 **不動** | kernel RS-485 沒開、或 RTS pinmux 沒給 GENI 控；下 Step 6 |
| CH1 動、CH2 在 TXD 之**後**才動 | 極性錯：你目前是 High Active，但 IC 是 Low Active；換 `exmp-serial-ctrl-R`（或反之） |
| CH3-CH4 有訊號但有大振鈴 | 終端電阻沒裝/裝太多；mode 1,1,0 已內建 120Ω + bias，這時 bus 上**不要**再外接 120Ω |
| RTS 比 stop bit 早收掉 | 對方會掉最後 1 bit；設 `delay_rts_after_send`，或改用 `rs485-manual` 印證 |

---

# STEP 6 — 如果 RTS 不動：用 rs485-manual 證明 RTS 線本身是活的

**目的**：繞過 kernel rs485 自動控制，**手動**把 RTS 鎖 HIGH 或 LOW 後寫資料，看示波器 CH2 是否真的會動。

```bash
# 6.1 手動 RTS 拉 LOW、送 4 個 0x55
adb shell /root/rs485-manual /dev/ttyHS1 lo 115200 UUUU

# 6.2 手動 RTS 拉 HIGH、送 4 個 0x55
adb shell /root/rs485-manual /dev/ttyHS1 hi 115200 UUUU

# 6.3 純脈衝 RTS（不送資料），方便慢慢量
adb shell /root/rts-probe /dev/ttyHS1 pulse 10
```

📝 觀察：
```
6.1 期間 CH2 = ____ V (預期 LOW，~0 V)
6.2 期間 CH2 = ____ V (預期 HIGH，~1.8 或 3.3 V)
6.3 期間 CH2 = 方波 Y/N，週期 = ____ ms (預期 200 ms)
```

🔧 推論：
- 6.1 / 6.2 都會動 → **RTS pinmux 沒問題**，是 kernel rs485 框架沒自動接管，回去確認 `rs485_enabled` 跟 toggle script 真的 on。
- 都不動 → **RTS pin 本身有問題**：dts pinctrl 沒給 RTS function，或 GENI 沒掛上；改 dts 的 `qup_uart3_rts` 看是不是被 bias 鎖住。

---

# STEP 7 — RS-485 端到端 loopback（兩個 ttyHS 互打）

**目的**：軟體 + 硬體 + bus 一起確認。把 ttyHS1 的 A↔ttyHS2 的 A、B↔B 接起來（同一條 bus 上兩個節點）。

```bash
# 7.1 雙方都 RS-485
adb shell /root/exmp-serial-ctrl-R 485 485

# 7.2 baud
adb shell "stty -F /dev/ttyHS1 115200 cs8 -parenb -cstopb -echo raw"
adb shell "stty -F /dev/ttyHS2 115200 cs8 -parenb -cstopb -echo raw"

# 7.3 HS2 開接收（terminal A）
adb shell "timeout 8 cat /dev/ttyHS2 | xxd"

# 7.4 HS1 送 48 bytes（terminal B）
adb shell "printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%%^&*()' > /dev/ttyHS1"

# 7.5 反向
adb shell "timeout 8 cat /dev/ttyHS1 | xxd &"
adb shell "printf 'abcdefghijklmnopqrstuvwxyz0123456789!@#\$%%^&*()' > /dev/ttyHS2"
```

📝 觀察：
```
HS1 → HS2  收到 = ____ / 48 bytes    內容是否正確 Y/N
HS2 → HS1  收到 = ____ / 48 bytes    內容是否正確 Y/N
dmesg 有 framing/break/overrun？ ____
```

🔧 不過：
- 0/48 → 整段不通；回 Step 5 看波形是不是真有到 A-B
- 部分通 → 噪聲 / bias 問題；加長線測；驗 fail-safe
- 收到反向資料 → A/B 接反

---

# STEP 8 — 改 DTS 4 個 pin 的 bias，量差異（你提的旋鈕）

**目的**：你提到 host 端 DTS 可改：
```dts
&qup_uart3_cts { bias-pull-up; };
&qup_uart3_rts { bias-disable; };
&qup_uart3_tx  { bias-disable; };
&qup_uart3_rx  { bias-pull-up; };
```
換每個組合都會影響「SoC pin 在重置 / 浮接時的預設電壓」。Step 7 通了之後，逐項試改下表，每改一次 **重新 build dtb → flash → boot → 回 Step 1 重做**。

| 試驗 | cts | rts | tx | rx | Step 7 結果 | idle A-B (mV) | TXD idle (V) | RTS idle (V) | 備註 |
|---|---|---|---|---|---|---|---|---|---|
| baseline | pull-up | disable | disable | pull-up | ____ | ____ | ____ | ____ | (你目前) |
| A | disable | disable | disable | disable | ____ | ____ | ____ | ____ | 全部不偏 |
| B | pull-up | pull-up | pull-up | pull-up | ____ | ____ | ____ | ____ | 全部上拉 |
| C | disable | pull-up | disable | pull-up | ____ | ____ | ____ | ____ | RTS 上拉（Low Active 比較穩） |
| D | pull-up | pull-down | disable | pull-up | ____ | ____ | ____ | ____ | RTS 下拉（reset 時 TX_EN 預設=on，會吵 bus，預期變糟） |

🔧 預期判斷：
- **RTS 上拉**（DTS bias-pull-up） + Low Active TX_EN → reset 時 TX_EN=HIGH=未送，**安全**
- **RTS 下拉** → reset 時 TX_EN=LOW=送，會「占線」，bus 上其他人講不了話
- TX bias 不影響運作中，只影響 idle / reset 瞬間
- RX 上拉幫助 SoC 端避免懸空

---

# STEP 9 — 持久性測試（reboot survives）

**目的**：之前的歷史教訓 — 改完當下會通、過一週又壞，因為 GPIO 預設值在 reboot 後跳回 (0,0,1) = RS-232。

```bash
# 9.1 不裝 service，先看 reboot 後狀態
adb shell reboot          # ⚠️ 確認手邊工作存檔
# 等 60 秒...
adb wait-for-device
adb shell "for g in 639 640 641 711 712 713; do
  printf 'gpio%-4s = %s\n' \"$g\" \"$(cat /sys/class/gpio/gpio$g/value)\"
done"
# 預期(壞掉)：638/640=0, 641=1 (= RS-232 mode)
```

📝 觀察：
```
reboot 後 gpio639/640/641 = ___ ___ ___
reboot 後 gpio711/712/713 = ___ ___ ___
是否回到 RS-232 預設？ Y / N
```

裝 systemd unit 讓它每次 boot 自動切：

```bash
# 9.2 安裝
adb shell "cp /root/rs485-init.service /etc/systemd/system/"
adb shell "systemctl daemon-reload"
adb shell "systemctl enable --now rs485-init.service"
adb shell "systemctl status rs485-init.service"

# 9.3 再 reboot 一次
adb shell reboot
adb wait-for-device
adb shell "for g in 639 640 641 711 712 713; do
  printf 'gpio%-4s = %s\n' \"$g\" \"$(cat /sys/class/gpio/gpio$g/value)\"
done"
# 預期：1 1 0  1 1 0
```

📝 觀察：
```
裝 service 後 reboot gpio639/640/641 = ___ ___ ___  (預期 1 1 0)
裝 service 後 reboot gpio711/712/713 = ___ ___ ___  (預期 1 1 0)
重做 Step 7 loopback = ____ / 48 bytes
```

🔧 如果還是壞：
- `systemctl status` 看 ExecStart 有沒有跑
- `journalctl -u rs485-init.service` 看 log
- ExecStart 跑了但 GPIO 沒翻 → 路徑錯或 expander 還沒上線；在 unit 加 `After=` 等 i2c

---

# 最終結論欄（做完填）

```
[ ] tty 上層 OK         (Step 2 通)
[ ] mode pin 真的會動    (Step 3 GPIO 全翻 + Step 4 idle bias 正確)
[ ] RTS 線真的會動       (Step 5 波形 OR Step 6 manual)
[ ] RS-485 bus loopback (Step 7 兩向都 48/48)
[ ] DTS bias 已選定組合 = ___________ (Step 8)
[ ] Reboot 後仍正常      (Step 9)

Root cause（如有）：__________________________________________
最終 work-around / fix：________________________________________
```

---

## 附：常用單行指令速查

```bash
# 一鍵全切 RS-485 (Low Active, term+bias)
adb shell /root/exmp-serial-ctrl-R 485 485

# 一鍵切回 RS-232
adb shell /root/exmp-serial-ctrl 232 232

# 看現在 6 個 mode GPIO
adb shell "for g in 639 640 641 711 712 713; do printf 'gpio%-4s = %s\n' \"$g\" \"$(cat /sys/class/gpio/gpio$g/value)\"; done"

# 看 kernel rs485 flag
adb shell cat /sys/class/tty/ttyHS1/rs485*
adb shell cat /sys/class/tty/ttyHS2/rs485*

# 看 RTS / CTS
adb shell /root/rts-probe /dev/ttyHS1 get

# 連續送 0x55 (示波器抓波形)
adb shell "while true; do printf '\\x55'; sleep 0.002; done > /dev/ttyHS1"

# 手動鎖 RTS=LOW 送資料
adb shell /root/rs485-manual /dev/ttyHS1 lo 115200 UUUUUUUU
```
