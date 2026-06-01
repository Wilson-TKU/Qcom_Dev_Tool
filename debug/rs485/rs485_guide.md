# RS485 從 0 到 1：原理 × 波形 × 逐步 Debug 手冊

> 目標讀者：在 SA8775P (LeMans) / QLI Linux 平台上要把 RS485 串列介面跑起來、或正在懷疑 RS485 不會通的人。
> 使用方式：**從第 1 章開始，做完每一個「✅ 確認」與「🔧 Debug」框，再進下一章**。每一章卡住就停在原地查，不要往後跳。

---

## 0. 名詞先對齊（避免越查越亂）

| 名詞 | 意思 | 備註 |
|---|---|---|
| RS485 / TIA-485 | 一種**電氣層**規範 (EIA/TIA-485-A) | 只規定「電壓、線、收發機」，不規定資料格式 |
| UART | 非同步串列資料格式（Start/Data/Parity/Stop） | RS485 線上跑的資料**通常**就是 UART frame |
| Transceiver | RS485 收發 IC（例：MAX485、SP3485、ADM2483、ISL3082） | SoC 跟銅線之間的橋 |
| A / B (或 D+ / D-) | 差動線對 | A = 非反相、B = 反相；空閒時 V(A) − V(B) > +200 mV |
| Y / Z | 全雙工時的另一對線 | 4 線 RS485 才有 |
| DE | Driver Enable | 高 = 允許發送 |
| /RE | Receiver Enable | 低 = 允許接收（常與 DE 短接） |
| Termination | 末端終端電阻 | 通常 120 Ω，跨在 A/B 之間 |
| Fail-safe biasing | 偏壓電阻 | 沒人講話時把 A 拉高、B 拉低，避免假資料 |

> RS485 ≠ UART。UART 是「協定的資料層」，RS485 是「物理層」。同一段 UART 訊號可以走 TTL、RS232、RS485 三種電氣層，**波形長相完全不一樣**。

---

## 1. 系統架構：訊號從 CPU 到銅線怎麼走

```
                ┌──────────────────────────┐
   SoC (SA8775P)│ QUP/UART controller      │   Transceiver (MAX485 類)
                │                          │   ┌────────────┐
                │  TXD ───────────────────►│ DI│            │A ───►──┐
                │  RXD ◄───────────────────│ RO│            │        │  ┌─── 120Ω
                │  GPIO_DE ───────────────►│ DE│            │        │  │   終端
                │  GPIO_/RE ──────────────►│/RE│            │B ───►──┼──┘
                │                          │   └────────────┘        │
                │  GND ────────────────────│ GND ─── GND ─── GND ────┘
                └──────────────────────────┘
                                              ▲           ▲
                                              │           │
                                          (常見：DE 與 /RE 直接接在一起)
```

四個你需要量的 pin（**這就是你要看的四根波形**）：

1. **TXD** （SoC → Transceiver 的 DI）：CPU 要送出的 UART 位元流
2. **RXD** （Transceiver 的 RO → SoC）：從線上接收下來的 UART 位元流
3. **DE/RE** （SoC 的 GPIO → Transceiver）：方向控制
4. **A − B** （差動電壓，用示波器數學運算 CH1 − CH2）：銅線上的真正訊號

---

## 2. 預期波形（一次完整的「送 0x55，然後接收 0xAA」）

時間軸：t0 ── 半字元前置 ── 送 0x55 (8N1, 115200) ── 半字元 ── 切回收 ── 接收 0xAA ──→

0x55 = `0101 0101`、0xAA = `1010 1010`。UART 8N1 線上順序：**Start(0) → LSB → ... → MSB → Stop(1)**，所以 0x55 線上看到的 bit 序列是 `0,1,0,1,0,1,0,1,0,1`（含 start/stop）。

```
              ┌── 我方傳送 0x55 ──┐                 ┌── 對方傳送 0xAA ──┐
              │                   │                 │                   │
DE  ─────────┐│                   │┐               │                   │
  (GPIO)     ││                   ││               │                   │
   0 ────────┘└───────────────────┘└───────────────┴───────────────────┴───────
       (idle)      driver ON          driver OFF         driver still OFF

/RE ─────────────────────────────────┐                                    ┌───
   1                                 │                                    │
   0 ───────────────────────────────┘└────────────────────────────────────┘
              (Rx 關閉，避免聽到自己)         Rx 打開

TXD (DI)
  3.3V ──┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─────────────────────────────────────────────
         │ │ │ │ │ │ │ │ │ │
  0 V    └─┘ └─┘ └─┘ └─┘ └─┘   (idle high)
        S  1 0 1 0 1 0 1 0 P    ← UART 位元 (start/stop 含在內，LSB first)

A − B  (差動)
  +2V ──┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌────────────────┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐──────
        │ │ │ │ │ │ │ │ │ │                │ │ │ │ │ │ │ │ │ │
  -2V   └─┘ └─┘ └─┘ └─┘ └─┘                └─┘ └─┘ └─┘ └─┘ └─┘
        ↑ idle = +200mV (有 bias) 或浮接（沒 bias 就有風險）
        marking(=1) = A>B (正)、spacing(=0) = A<B (負)

RXD (RO)
  3.3V ────────────────────────────────────┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─────
                                           │ │ │ │ │ │ │ │ │ │
  0 V                                      └─┘ └─┘ └─┘ └─┘ └─┘
                                           S  0 1 0 1 0 1 0 1 P   ← 0xAA
        (傳送時 Rx 被關，看不到自己；切換後才看到對方資料)
```

關鍵時序規則（**這幾條沒對，幾乎一定壞**）：

- **DE 拉高 → 開始送 TXD 第一個 start bit**，中間要有「driver enable setup time」，通常幾 µs 即可，但有些隔離型 transceiver 需要 1 ms 以上。
- **TXD stop bit 結束 → DE 拉低**：必須等到最後一個 stop bit **完全**送完才放手；早放會把 stop bit 截掉，對方看到 framing error。Linux kernel 的 `rs485.delay_rts_after_send` 就是控這個。
- **DE 放掉之後 → /RE 才能拉低**：自己嘴巴沒閉就先開耳朵 = 聽到自己（會 echo）。
- **bus idle 時必須 fail-safe 偏壓** A>B 至少 +200 mV，否則接收端會亂跳，dmesg 會噴一堆 break / framing error。

---

## 3. 硬體層

### 3.1 接線清單

| 訊號 | 走向 | 注意 |
|---|---|---|
| A (D+) | bus | 跟所有節點的 A 接在一起 |
| B (D-) | bus | 跟所有節點的 B 接在一起 |
| GND   | bus | **必須拉**，不是「差動就不用接地」，至少要有共地參考；長距離建議經 100 Ω 限流電阻接 |
| Shield | 機殼 | 單點接地，避免地迴路 |

### 3.2 終端電阻 (Termination)

- **拓樸只允許 daisy-chain**，不可以 star。
- **頭尾兩端各一顆 120 Ω** 跨 A/B，中間節點不要裝。
- 短距離 (<5 m) 且低速 (<9600 bps) 時可以省略，但只要出問題第一個就是它。

### 3.3 Fail-safe biasing

- 常見：A 經 680 Ω 上拉到 +3.3V/5V，B 經 680 Ω 下拉到 GND。
- 整條 bus 只裝**一組**（通常裝在 master 端）。

### ✅ 硬體確認檢查表

```
[ ] A、B 是不是真的差動（不是把單端訊號當差動接）
[ ] GND 有沒有共接
[ ] 終端電阻 120 Ω 只在頭尾，量測：bus 斷電下用三用電表量 A-B ≈ 60 Ω（兩顆並聯）
[ ] 偏壓電阻有沒有裝（bus idle 量 A-B 應 > +200 mV）
[ ] DE / /RE 走線到 SoC 對的 GPIO（看原理圖、看 dts）
[ ] Transceiver Vcc 量 3.3V 或 5V 在規格內
```

### 🔧 硬體 Debug

| 症狀 | 量哪裡 | 期望 | 不對就 |
|---|---|---|---|
| 完全收不到 | A-B (idle) | > +200 mV | 沒有 → 加 / 修偏壓 |
| 偶爾收到亂碼 | A-B 切換邊緣 | 漂亮的方波，無振鈴 | 振鈴 → 補 120 Ω；overshoot → 加 TVS |
| 收到自己的資料 (echo) | DE 與 RXD | DE 拉高時 RXD 應為 high (被靜音) | 收到 → /RE 沒關，或 transceiver 不支援靜音，用 GPIO 強制關 RX |
| 對方完全收不到 | DE 波形 | 送資料前先拉高、stop bit 後才拉低 | 時序錯 → 調 `delay_rts_before_send` / `delay_rts_after_send` |

---

## 4. 軟體層（Linux / QLI）

### 4.1 確認 kernel / dts 端有把 RS485 接好

SA8775P 平台一般是某個 QUP UART 加上 GPIO 作為 RTS（DE）控制。在 device tree 裡常見：

```dts
&qupv3_se5_2uart {
    status = "okay";
    linux,rs485-enabled-at-boot-time;
    rs485-rts-active-high;
    rs485-rts-delay = <0 0>;   /* before, after (ms) */
};
```

### ✅ 確認 kernel 支援 RS485

```bash
adb shell zcat /proc/config.gz | grep -i SERIAL_8250_RS485
adb shell grep -i rs485 /sys/kernel/debug/tty
adb shell ls /sys/class/tty/
```

期望：
- `CONFIG_SERIAL_8250_RS485=y` 或對應 driver (`CONFIG_SERIAL_MSM_GENI`) 有支援
- `/dev/ttyHS*` 或 `/dev/ttyMSM*` 出現你掛的 UART 節點

### 4.2 找出你的 RS485 是哪一個 tty

```bash
adb shell dmesg | grep -iE "uart|geni|rs485"
adb shell ls -l /dev/ttyHS* /dev/ttyMSM* 2>/dev/null
```

從 dmesg 找像這樣的行：
```
msm_serial_geni 988000.serial: ttyHS1 at MMIO ...
```

### 4.3 開啟 RS485 模式（user space）

最直接：寫一個小工具用 `TIOCSRS485` ioctl。常用做法：

```bash
# 1. 在板子上有沒有 picocom / stty / minicom
adb shell which stty picocom minicom

# 2. 用 stty 把 baud 設好
adb shell stty -F /dev/ttyHS1 115200 cs8 -parenb -cstopb -echo raw

# 3. 開 RS485（如果你的 driver 支援 sysfs / ioctl）
#    sysfs (新核心)：
adb shell ls /sys/class/tty/ttyHS1/rs485*  2>/dev/null
adb shell "echo 1 > /sys/class/tty/ttyHS1/rs485_enabled"
```

如果沒有 sysfs，就要小程式：

```c
// rs485_set.c — push 到板子上 cross-compile，或用 host x-tool
#include <linux/serial.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdio.h>
int main(int argc, char**argv){
    int fd = open(argv[1], O_RDWR);
    struct serial_rs485 rs = {0};
    rs.flags = SER_RS485_ENABLED | SER_RS485_RTS_ON_SEND;
    rs.delay_rts_before_send = 0;
    rs.delay_rts_after_send  = 0;
    if (ioctl(fd, TIOCSRS485, &rs) < 0) perror("TIOCSRS485");
    return 0;
}
```

### 4.4 收送測試

開兩個 adb shell：

```bash
# Terminal A: 監聽
adb shell "stty -F /dev/ttyHS1 115200 cs8 -parenb -cstopb -echo raw; \
           cat /dev/ttyHS1 | xxd"

# Terminal B: 發送
adb shell "printf '\x55\xAA' > /dev/ttyHS1"
```

對端如果是 PC（USB-RS485 dongle）：

```bash
# 在 host
sudo stty -F /dev/ttyUSB0 115200 cs8 -parenb -cstopb -echo raw
cat /dev/ttyUSB0 | xxd            # 看板子送的
printf '\xAA\x55' > /dev/ttyUSB0  # 送給板子
```

### ✅ 軟體確認檢查表

```
[ ] /dev/ttyHSx 有出現
[ ] stty -F /dev/ttyHSx -a 看到的設定就是你要的 (baud / data / parity / stop)
[ ] dmesg 沒有「framing error / break / overrun」連發
[ ] sysfs 或 ioctl 把 RS485 mode 真的打開（不開的話 DE 永遠不會動！）
```

### 🔧 軟體 Debug 指令

```bash
# 看 driver 統計
adb shell cat /proc/tty/driver/* 2>/dev/null

# 看 GENI / UART 中斷有沒有在跳
adb shell "cat /proc/interrupts | grep -iE 'geni|uart'"
# 連按兩次看數字有沒有增加；發資料時 tx 中斷應該增加，收資料時 rx 應該增加

# 即時 dmesg
adb shell dmesg -w | grep -iE "tty|geni|uart|rs485"

# 看 GPIO（DE pin）狀態 — 先從 dts 找出 GPIO 編號
adb shell cat /sys/kernel/debug/gpio | grep -i rs485
adb shell cat /sys/kernel/debug/pinctrl/*/pinmux-pins | grep <gpio>

# 持續送 0x55 方便用示波器抓
adb shell "while true; do printf '\x55'; usleep 1000; done > /dev/ttyHS1"
```

---

## 5. 量測（示波器步驟）

> 設備：兩通道以上示波器，最好 4 通道；差動探棒最佳，沒有就用兩個單端探棒做 MATH = CH1 − CH2。

### 5.1 探棒位置

| 通道 | 接哪 | 觸發 |
|---|---|---|
| CH1 | TXD（SoC → transceiver DI） | 下降邊（找 start bit）|
| CH2 | DE （SoC GPIO） | 上升邊 |
| CH3 | A （bus 上的 D+） | — |
| CH4 | B （bus 上的 D-），MATH = CH3 − CH4 | — |

時間軸：1 / baud × 12 ≈ 一個 byte。115200 → 約 87 µs 一個 bit → 設 20 µs/格。

### 5.2 預期觀察

| 你看到 | 解讀 |
|---|---|
| TXD 動、DE 也動、A-B 也跟著動 | ✅ 全鏈路通；接下來看對方有沒有收到 |
| TXD 動、DE 動，A-B 不動 | transceiver 沒供電 / Vcc 掉 / DI 沒進 IC（焊接、走線） |
| TXD 動、DE **不動**、A-B 不動 | 軟體沒開 RS485 mode；或 dts 的 RTS GPIO 沒設對 |
| TXD 動、DE 動，但 DE 比 TXD 早收 / 晚收太多 | 調 `rs485-rts-delay` 或 `delay_rts_before/after_send` |
| A-B 有訊號但是「歪斜」、有大振鈴 | 終端電阻缺、或裝太多、或線太長 |
| Bus idle 時 A-B 在 0 V 附近抖動 | 沒 fail-safe biasing → RX 會收到假 break |
| 自己送的同時 RXD 也動 | echo：/RE 沒關，或 transceiver 不支援 mute；改用 GPIO 強制 |

---

## 6. 端到端 Root Cause 流程（出問題就照這條走）

```
        START
          │
          ▼
   收得到 / 送得到？
        ├─ 都不行 → §6.1 完全沒訊號
        ├─ 只能送 → §6.2 收不到
        ├─ 只能收 → §6.3 送不出去
        └─ 偶爾通 → §6.4 偶發錯誤
```

### 6.1 完全沒訊號

1. `adb shell dmesg | grep -i ttyHS` → tty 有沒有起來？沒有 → dts 沒掛或 status 沒 okay。
2. `adb shell ls /dev/ttyHS*` → 節點存在嗎？
3. 量 transceiver Vcc → 對嗎？
4. 量 TXD → 送資料時有沒有 toggling？沒有 → driver 沒在送，回去看 stty / 程式有沒有真的 write。
5. 量 DE → 有 toggling 嗎？沒有 → RS485 mode 沒打開（`TIOCSRS485` / sysfs / dts `linux,rs485-enabled-at-boot-time`）。

### 6.2 我送對方收不到

1. 量 A-B 差動波形是不是「乾淨且 ±2 V 以上」。
2. DE 收尾時機：stop bit 之後才掉？太早 → 加 `delay_rts_after_send`。
3. 對方 baud / parity / stop 跟你一致？
4. 對方有沒有正確接 A↔A、B↔B？（很多人接反，接反通常會收到全部反向 → 整段 framing error）
5. GND 有沒有共接。

### 6.3 對方送我收不到

1. DE 放掉之後 /RE 有沒有打開？量 RXD 在「對方應該在送」的時候有沒有動。
2. bias 電阻在不在？bus idle 量 A-B 應 > +200 mV。
3. SoC 的 RXD pinmux 對嗎？`cat /sys/kernel/debug/pinctrl/.../pinmux-pins`。
4. `cat /proc/interrupts` 觀察 RX 中斷有沒有跳。

### 6.4 偶發錯誤、亂碼

1. dmesg 噴 `framing error / overrun / break` → 多半是 baud 抖、grounding、或 fail-safe 失效。
2. 線太長 + 速率太高 → 降 baud 驗證 (試 9600)。
3. 多 master 互撞 → 通訊協定層（Modbus 等）排程錯。
4. 共模電壓超 transceiver 規格 (-7~+12V) → 用 isolated transceiver。

---

## 7. 一頁速查表（貼工作站旁）

```
電氣   差動，A>B = '1' (mark)，A<B = '0' (space)
電壓   |A-B| ≥ 200 mV 即可判讀；典型 ±2 V
偏壓   idle 必須 A-B ≥ +200 mV，否則加 680Ω 上/下拉
終端   120 Ω，只在頭尾兩端
拓樸   daisy-chain，不准 star、不准 ring
線材   雙絞 STP，特性阻抗 ~120 Ω
速率   1200 ~ 10 Mbps，常用 9600 / 115200
距離   ≤ 1200 m @ 100 kbps（速率與距離成反比）
方向   DE 拉高發送、DE 拉低接收；/RE 通常與 DE 同步
時序   DE↑ → TX 第一個 bit；TX 最後 stop bit → DE↓（不可早）
共地   GND 必接，可加 100 Ω 限流
```

---

## 8. 動手做：第一次 bring-up SOP

> 假設你拿到一塊 SA8775P 板子要把 RS485 跑起來。照這個順序，每完成一條打勾。

```
[ ] 看原理圖，確認 RS485 transceiver 型號、DE/RE 接到哪個 SoC GPIO、UART 是哪一組 QUP
[ ] 看 dts，確認 UART node 已 enable、有 rs485 屬性、RTS GPIO 對得上
[ ] adb shell dmesg | grep ttyHS  確認 tty 號
[ ] adb shell stty -F /dev/ttyHSx 115200 cs8 -parenb -cstopb -echo raw
[ ] echo 1 > /sys/class/tty/ttyHSx/rs485_enabled  或 ioctl 開
[ ] 示波器 4 ch 接好 TXD / DE / A / B
[ ] adb shell "while true; do printf '\x55'; sleep 0.1; done > /dev/ttyHSx"
[ ] 看：TXD 有動？DE 有動？A-B 有動？三者時序對？
[ ] PC 端 USB-RS485 dongle 對接，cat /dev/ttyUSB0 | xxd 看是不是收到 55
[ ] 反向：PC 送 AA，板子端 cat /dev/ttyHSx | xxd 收到嗎？
[ ] 拉長線到實際使用長度，重做一次，紀錄錯誤率
```

每一步出錯都回去找對應章節。**不要跳級**。

---

## 附錄 A：常見 transceiver pinout（MAX485 系列）

```
            ┌─────────────┐
       RO ──│1           8│── Vcc
       /RE ──│2           7│── B
       DE  ──│3           6│── A
       DI  ──│4           5│── GND
            └─────────────┘
```

## 附錄 B：用 logic analyzer 也可以

便宜的 Saleae / sigrok 也行（24 MHz sample，115200 綽綽有餘），decode UART 直接給你 byte。但**差動電壓只有示波器看得到**，logic analyzer 只能看 TTL 端（TXD/RXD/DE）。

## 附錄 C：相關 kernel source 路徑

```
drivers/tty/serial/qcom_geni_serial.c   # SA8775P 的 UART driver
include/uapi/linux/serial.h             # struct serial_rs485
Documentation/devicetree/bindings/serial/rs485.txt
```

---

**完成後**：把你量到的四張波形截圖貼到本文件 §2 下方，註明 baud / dataformat / 拓樸長度，下次別人再 debug 直接看就行。
