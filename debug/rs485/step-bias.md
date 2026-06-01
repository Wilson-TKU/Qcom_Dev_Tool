# DTS Bias 三變體實驗（uart3 + uart4 共 8 pin）

> 目的：把 SoC pinctrl 對 F81439A 的 8 條 line（uart3 cts/rts/tx/rx + uart4 cts/rts/tx/rx）的 `bias-*` 屬性各做一版 dtb，逐版燒進去量電位，再決定 F81439A 應該設 High Active 還是 Low Active、kernel `TIOCSRS485` 該下哪一種 flag。
>
> 平台：SA8775P + F81439A multi-protocol transceiver
> **板上配置**：
> - **ttyHS1 ↔ qup_uart3（gpio28-31）↔ 上板 F81439A**（SoC GPIO 639/640/641 控 mode pins）
> - **ttyHS2 ↔ qup_uart4（gpio32-35）↔ 底板 F81439A**（TCA6408 I²C expander gpio 711/712/713 控 mode pins）

---

## 1. 目前 dtb 的 baseline（不要編，先記下來對照）

| Node | gpio | 板位 / tty | 用途 → F81439A | 現況 bias |
|---|---|---|---|---|
| qup-uart3-cts-pins | gpio28 | **上板 / ttyHS1** | CTS | `bias-pull-up` |
| qup-uart3-rts-pins | gpio29 | **上板 / ttyHS1** | **RTS → TX_EN** | `bias-disable` |
| qup-uart3-tx-pins  | gpio30 | **上板 / ttyHS1** | TX → DI | `bias-disable` |
| qup-uart3-rx-pins  | gpio31 | **上板 / ttyHS1** | RX ← RO | `bias-pull-up` |
| qup-uart4-cts-pins | gpio32 | **底板 / ttyHS2** | CTS | `bias-pull-up` |
| qup-uart4-rts-pins | gpio33 | **底板 / ttyHS2** | **RTS → TX_EN** | `bias-disable` |
| qup-uart4-tx-pins  | gpio34 | **底板 / ttyHS2** | TX → DI | `bias-disable` |
| qup-uart4-rx-pins  | gpio35 | **底板 / ttyHS2** | RX ← RO | `bias-pull-up` |

→ 這 8 個屬性就是你要改的點，每個 dtb 變體統一改成同一個值。

---

## 2. 三個 dtb 變體要做什麼

| 變體 | 8 個 bias 屬性統一改成 | 輸出檔名（建議） |
|---|---|---|
| **A) 全 disable** | `bias-disable;` | `debug/rs485/dtb/dtb-disable.bin` |
| **B) 全 pull-up**  | `bias-pull-up;`  | `debug/rs485/dtb/dtb-pullup.bin`  |
| **C) 全 pull-down**| `bias-pull-down;`| `debug/rs485/dtb/dtb-pulldown.bin`|

編 dtb 的流程沿用你原本的：
```bash
cd ~/github/Qcom_Dev_Tool/dtb
./modify_qcom_dtb.sh dtb.bin     # 開 vscode 改 combined-dtb.dts 的 8 個 bias
./save_qcom_dtb.sh               # 重編 .dtb 並 umount
cp dtb.bin ../debug/rs485/dtb/dtb-<variant>.bin   # 改名歸檔
```

⚠️ 改 dts 時只動下面這 8 行（grep 一下就能找到）：
```
qup-uart3-cts-pins / -rts-pins / -tx-pins / -rx-pins  → bias-XXX;
qup-uart4-cts-pins / -rts-pins / -tx-pins / -rx-pins  → bias-XXX;
```
**不要改 `pins =`、`function =`、`phandle =`** — 改了會 break pinmux。

---

## 3. 物理意義先講清楚（為什麼是這 3 個值）

`bias-*` 屬性的作用：當 SoC pin **沒有被任何 driver 主動驅動**（也就是 high-impedance 狀態）時，這顆電阻決定 pin 的電位。具體會發生在：

1. **POR 後到 pinctrl probe 完成之間**（boot 早期、微秒～數百毫秒）
2. **pinmux 被切走、但功能還沒接管前**
3. **suspend / 低功耗模式下** pin 被 park
4. **input pin 永遠** — 例如 RX 永遠是 input，bias 是它唯一的「預設電壓」

driver 開始主動驅動之後 (output mode)，bias 仍然在但被 push-pull 蓋過，**只影響邊緣 RC 時間**（可忽略）。

→ 所以這個實驗的本質是：**boot 早期 / pinctrl 還沒接管時，F81439A 的 TX_EN（接 RTS）會處在什麼電位？**

---

## 4. 預期結果（量測前先寫好預測）

### 4.1 boot 早期、kernel 還沒 init 完之前的 8 pin 電位預測

| 變體 | cts(28/32) | **rts(29/33)** | tx(30/34) | rx(31/35) | bus A−B idle |
|---|---|---|---|---|---|
| A) disable  | 浮接 (≈中間態，受周邊洩漏電流影響) | **浮接** | 浮接 | 浮接 → 但 F81439A RO 是 push-pull 會驅動 | 不確定 |
| B) pull-up  | ~3.3V | **~3.3V** | ~3.3V (= UART idle，OK) | ~3.3V | F81439A 內 bias 主導 |
| C) pull-down| ~0V   | **~0V**   | ~0V (= 持續 break / start bit) | ~0V → 跟 RO 對打 | F81439A 內 bias 主導 |

### 4.2 F81439A TX_EN 在 boot 早期會看到什麼

⚠️ 重點：F81439A 的 mode pin（M0/M1/M2）**boot 預設 = (0,0,1) = RS-232 mode**。在這個 mode 下 TX_EN 是 don't care，**A/B 是高阻抗**。所以「boot 早期 bus 是不是被占」要分兩段看：

| 階段 | F81439A 狀態 | RTS bias 重不重要 |
|---|---|---|
| 開機 ~ user-space 跑 `exmp-serial-ctrl-R 485 485` 之前 | RS-232 mode，A/B 高阻抗 | 不重要（IC 不在驅動 bus） |
| 切到 RS-485 mode 之後 | TX_EN 由 RTS 決定 | **超級重要** |
| 切完之後到 kernel driver 接管 RTS 的縫隙 | TX_EN = RTS 此刻電位 = bias 主導 | 決定 bus 會不會被亂占 |
| kernel `TIOCSRS485` ON 之後 | kernel auto-toggle | bias 退場 |

### 4.3 F81439A 模式選擇邏輯（量到 RTS idle 之後反查）

切到 RS-485 半雙工後，**TX_EN 在 idle（沒送資料時）必須等於「receive 模式」的電位**，否則 bus 會一直被自己占住沒人講得了話。F81439A 的兩種半雙工模式：

| F81439A mode (M0,M1,M2) | TX_EN 極性 | idle 時 TX_EN 應該 = | 對應 kernel flag |
|---|---|---|---|
| **(0,1,0) RS-485 半雙工** | **Low Active** | HIGH（驅動 OFF） | `SER_RS485_ENABLED \| SER_RS485_RTS_AFTER_SEND` |
| **(0,1,1) RS-485 半雙工** | **High Active** | LOW（驅動 OFF）  | `SER_RS485_ENABLED \| SER_RS485_RTS_ON_SEND` |
| **(1,1,0) RS-485 + 內 term/bias** | **Low Active** | HIGH | `RTS_AFTER_SEND` |
| (1,0,0) RS-422 + 內 term/bias | 持續驅動 | n/a | RS-485 flag off |

→ **規則**：RTS pin 在「沒人驅動它」時量到的電位（= bias 給的電位），決定該選 High 還是 Low Active：

| 量到 RTS idle ≈ | 選 F81439A mode | 用哪個 user-space 工具 | kernel flag |
|---|---|---|---|
| **HIGH (~3.3V)** | (1,1,0) Low Active | `exmp-serial-ctrl-R 485 485` | `rs485-toggle-R on` → `RTS_AFTER_SEND` |
| **LOW (~0V)**    | (0,1,1) High Active | `exmp-serial-ctrl 485 485`   | `rs485-toggle on`   → `RTS_ON_SEND` |
| 浮接 / 中間態     | 都不安全，建議改 bias | — | — |

---

## 5. 一個變體跑完一輪的 SOP（每個變體都做一次）

每次燒完一版 dtb，照下面這 7 步跑，把結果填進 §6 表。

### 5.0 燒錄

```bash
cd ~/github/Qcom_Dev_Tool/dtb
./flash_dtb.sh ../debug/rs485/dtb/dtb-<variant>.bin    # disable / pullup / pulldown
# 燒完拔線、重開機
```

### 5.1 開機後第一件事：**還沒跑任何 user-space rs485 script**，量 8 pin idle

示波器先擺好 4 通道（重點是這條 UART 的 TXD 跟 RTS）：

先量 **上板 (ttyHS1 / qup_uart3)**：

| 通道 | 接哪 |
|---|---|
| CH1 | gpio30（uart3 TX → 上板 F81439A DI） |
| CH2 | gpio29（uart3 RTS → 上板 F81439A TX_EN） |
| CH3 | 上板 F81439A 端的 bus A |
| CH4 | 上板 F81439A 端的 bus B，MATH = CH3 − CH4 |

底板 (ttyHS2 / qup_uart4) 也要量，把通道移到 gpio34/gpio33/底板 A/B 重做一次。

8 pin 全量一次（用三用電表也行，找對應測試點）：

```bash
# 確認 ttyHS 都起來
adb shell "dmesg | grep -iE 'ttyHS|geni.*988|99c' | head"

# 用 rts-probe 看 modem control 線狀態（這只看 RTS by software，bias 看示波器才準）
adb shell /root/rts-probe /dev/ttyHS1 get
adb shell /root/rts-probe /dev/ttyHS2 get
```

📝 **量測表（每個變體填一次）**：

```
[變體 = _________ ] boot 後、未跑 rs485 script

           上板 (ttyHS1 / uart3)            底板 (ttyHS2 / uart4)
cts        gpio28 = ____ V                  gpio32 = ____ V
rts ★     gpio29 = ____ V                  gpio33 = ____ V       ← 最關鍵
tx         gpio30 = ____ V                  gpio34 = ____ V
rx         gpio31 = ____ V                  gpio35 = ____ V

bus A-B idle 上板 = ____ mV      底板 = ____ mV
rts-probe ttyHS1 RTS = __        rts-probe ttyHS2 RTS = __
dmesg 異常？ __________________________________________
```

### 5.2 反查 F81439A 該設哪個 mode（用上面 §4.3 的對照表）

```
依 RTS idle 量到 ____ V →  F81439A 該設 (___,___,___) = ___ Active
                      →  user-space 跑：  ______________________________
                      →  kernel flag：    ______________________________
```

### 5.3 切到對應 mode

跑你查出來該下的指令（從 §4.3 對照）：

```bash
# 量到 RTS HIGH → Low Active
adb shell /root/exmp-serial-ctrl-R 485 485

# 量到 RTS LOW → High Active
adb shell /root/exmp-serial-ctrl 485 485
```

### 5.4 切完再量一次 8 pin + bus + RTS

```
[變體 = _________ ] mode 切完後 (idle)

gpio29 rts3 = ____ V    gpio33 rts4 = ____ V    (預期：跟 §5.1 相同 ± 小於 0.1V)
bus A-B idle = ____ mV   (預期 ≥ +200 mV)
dmesg 新增訊息？ ____________
```

### 5.5 跑 0x55 連續送、示波器抓四根 pin 動態

```bash
adb shell "while true; do printf '\\x55'; sleep 0.002; done > /dev/ttyHS1"
```

📝 動態觀察（示波器觸發 CH2 RTS 的對應邊緣）：

```
[變體 = _________ ]

CH1 TXD 在 RTS 啟用期間有 UART 波形？      Y / N
CH2 RTS 翻轉極性是 LOW-active 還 HIGH-active？ ____
CH3-CH4 (A-B) 跟著動，幅度 ≈ ____ Vpp
RTS 啟用 → TX 第一個 start bit 延遲 ≈ ____ µs
TX 最後 stop bit → RTS 釋放 延遲 ≈ ____ µs
```

### 5.6 端到端 loopback（ttyHS1 ↔ ttyHS2 透過 A↔A、B↔B）

```bash
adb shell "stty -F /dev/ttyHS1 115200 cs8 -parenb -cstopb -echo raw"
adb shell "stty -F /dev/ttyHS2 115200 cs8 -parenb -cstopb -echo raw"

# Terminal A
adb shell "timeout 6 cat /dev/ttyHS2 | xxd"

# Terminal B
adb shell "printf 'ABCDEFGHIJ0123456789' > /dev/ttyHS1"
```

📝 結果：

```
HS1 → HS2 收到 = ____ / 20 bytes，內容對 Y/N
HS2 → HS1 收到 = ____ / 20 bytes，內容對 Y/N
```

### 5.7 第一個 byte 是否爛掉的細查

RS-485 第一個 byte 容易被 driver enable 緩衝吃掉，特別跟 bias 設定有關（影響 idle bus 電壓 = receiver 是否認得 idle）。

```bash
adb shell "timeout 4 cat /dev/ttyHS2 | xxd > /tmp/rx.log &"
adb shell "for i in 1 2 3 4 5; do printf 'X'; usleep 200000; done > /dev/ttyHS1; wait"
adb shell "cat /tmp/rx.log"
```

```
預期：5 個 0x58 (X)
實得：________________________
第一個 byte 對嗎？ Y / N
```

---

## 6. 三變體量測總結表（做完填這張）

### 6.1 boot idle 量到的 RTS（最關鍵那欄）

| 變體 | 上板 rts (gpio29) | 底板 rts (gpio33) | 上板 tx (gpio30) | 底板 tx (gpio34) | 上板 A-B (mV) | 底板 A-B (mV) | 反推 F81439A mode | 反推 kernel flag |
|---|---|---|---|---|---|---|---|---|
| A) disable   | ____ V | ____ V | ____ V | ____ V | ____ | ____ | ____________ | ________________ |
| B) pull-up   | ____ V | ____ V | ____ V | ____ V | ____ | ____ | ____________ | ________________ |
| C) pull-down | ____ V | ____ V | ____ V | ____ V | ____ | ____ | ____________ | ________________ |

### 6.2 切到對應 mode 後的 loopback

| 變體 | 用的 IC mode | 用的 kernel flag | HS1→HS2 bytes | HS2→HS1 bytes | 第一 byte 對？ | dmesg 異常 |
|---|---|---|---|---|---|---|
| A) disable   | ____ | ____ | ____/20 | ____/20 | Y/N | ____ |
| B) pull-up   | ____ | ____ | ____/20 | ____/20 | Y/N | ____ |
| C) pull-down | ____ | ____ | ____/20 | ____/20 | Y/N | ____ |

### 6.3 開機 race condition 觀察（拔網拔 adb 重開機，**插示波器先觸發**）

| 變體 | boot 過程 A-B 是否有 garbage 訊號 | RTS 在 kernel up 之前的電位 |
|---|---|---|
| A) disable   | ____ | ____ |
| B) pull-up   | ____ | ____ |
| C) pull-down | ____ | ____ |

---

## 7. 決策邏輯（量完三個變體後選一個 final 配置）

依量測結果排優先：

1. **首選**：選一個 **boot 早期 RTS idle 穩定 = HIGH** 的 bias 設定，搭配 F81439A `(1,1,0) Low Active` + `RTS_AFTER_SEND`。
   - 理由：boot 早期 bus 一定處於「沒人講話」狀態，RTS HIGH = TX_EN HIGH = 驅動 OFF = 不占線；其他節點可以正常收送。
   - 對應你的三變體：**B) pull-up** 最有可能拿這張票。

2. **次選**：若 pull-up 變體某個別功能壞掉，才考慮 pull-down + `(0,1,1) High Active` + `RTS_ON_SEND`。
   - 風險：boot 早期 RTS LOW，但 F81439A 在 boot 預設模式是 RS-232（A/B 高阻抗），所以**短暫**不會占 bus。重點是切到 485 mode 那一瞬間到 kernel 接管 RTS 中間的縫隙會占 bus。

3. **不選**：disable 的不確定性最大，除非 pull-up / pull-down 都壞才回頭考慮。

最終把選定的 bias 設定 + IC mode + kernel flag 三件事一起 commit，並把 `rs485-init.service` 裝起來確保 reboot 後 user-space mode 也會自動回到 485。

---

## 8. 不踩雷清單

- [ ] 改 dts 只動 `bias-*`，不要動 `pins`、`function`、`phandle`
- [ ] 三份 dtb 各備份原始檔，編完馬上改名歸檔到 `debug/rs485/dtb/`
- [ ] 燒任一版前先 `cat dtb-<variant>.bin | sha256sum` 留個 hash，避免燒錯版本對不上結果
- [ ] 每變體量完 §5.1 boot idle **再切 mode**；不要先切了 mode 再回頭量 idle（電位會被 kernel 蓋掉）
- [ ] 量 idle 時 adb 還沒進入也可以靠 UART console / 三用電表，不必等 OS 完全 up
- [ ] dmesg 出現 `Direct firmware load for qcom/sa8775p/qupv3fw.elf failed` 是已知的，可忽略，不是 bias 引發的
- [ ] 換 dtb 時記得**斷電 cold boot**，避免上次 kernel 留下的 pin state 干擾本次量測
