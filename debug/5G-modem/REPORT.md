# 5G Modem (Quectel EM060K-GL) 上線除錯紀錄

- **平台**：SA8775P / QLI 1.8-ver.1.1 / kernel 6.6.119
- **症狀**：M.2 5G modem 插上去 USB 認得到，但 driver 沒掛、沒 `wwan0` / `/dev/cdc-wdm0`

🎯 **最終根因**（HW 量測後揭露）

**B-Key preset pin (PERST# / FULL_CARD_POWER_OFF#) 被板上 0 ohm 預設 pull-high 到 3.3V**，導致 EM060K-GL 模組進入異常狀態（量到震盪波形），整顆 modem 永遠 boot 不到 application mode，所以只暴露 1 個 diagnostic interface (`bNumEndpoints==2`)，被 `qmi_wwan.c:1575` 主動 reject。

🎯 **修法**

EE 把該 preset pin 上的 0 ohm 拉 high 電阻**拔掉**，pin 預設浮 / pull-low；模組自己在 power-on 後會拉一下 1.8V high 做內部 reset。拔阻後 modem 進 application mode、`qmi_wwan` 正常 bind、`wwan0` / `/dev/cdc-wdm0` 出現，後續 MBIM 撥號實測拿到真實 IP。

✅ **已完成**

HW preset pin 預設電位修正後整條 stack 通；driver patch（`qmi_wwan` PID 0x030b）+ 跨編譯 + vermagic 對齊 + module deploy 流程也都驗收過。

⚠️ **驗收後發現**：HW 修好之後 modem 進的是 **MBIM composition**(class `02/0e` + `0a` 的標準 CDC class),`cdc_mbim` 用 class match 直接接走,**根本不需要 PID patch**。`qmi_wwan` 的 PID `0x030b` 補丁只在 modem 配成 vendor-class QMI/RmNet composition (`ff/ff/ff`) 時才會被用到 — 現在這顆 EM060K-GL 預設不是那條路。所以 driver patch 的價值縮減為「萬一將來切到 QMI mode 再用」。

---

## 主流程

### 1. 確認 module 是否掛起

`lsmod` 完全沒看到 wwan 相關 module，`/sys/class/wwan/`、`/dev/cdc-wdm*` 都不存在。

<details>
<summary>細節</summary>

```
$ adb shell lsmod | grep -iE "wwan|qmi|mbim|option"
qmi_cooling   16384  0       # 只有 SoC 內部熱管理 QMI，與 modem USB 無關
```

`/lib/modules/$(uname -r)/` 內 `qmi_wwan.ko`、`option.ko`、`cdc_mbim.ko` 都**存在**但沒載入 → udev 沒被觸發。
</details>

---

### 2. Driver 沒 bind，看 source 發現漏 PID（後來證實是表層）

USB enumeration 完成（VID:PID = `2c7c:030b` Quectel EM060K-GL），interface descriptor 是 `class=FF / subclass=FF / protocol=FF`——這就是 QMI/RmNet 標準簽章，理應由 `qmi_wwan` driver 接管。

對照 `modules.alias` 與 kernel source 發現：**`qmi_wwan.ko` 的 PID table 完全沒有 `0x030b`**。OpenWrt issue #16165 報告同樣問題、同樣解法。

> ⚠️ 此時誤判：以為這就是根因。實際上 reboot 後驗證才揭露——**modem 只暴露 1 個 interface 且僅 2 endpoint，是 diagnostic interface（DM），不是 QMI interface**。Patch PID 之後 driver 仍會在 `qmi_wwan.c:1575` 主動 return -ENODEV。詳見 step 6。

<details>
<summary>細節 — modem descriptor / driver alias 比對</summary>

Modem USB descriptor（`/sys/bus/usb/devices/3-1.4`）：
```
idVendor:        2c7c
idProduct:       030b
bNumInterfaces:  1
bInterfaceClass: FF / FF / FF (vendor-specific)
driver:          (NONE — 沒 bind)
```

`modules.alias` 搜 `2c7c:030b`：
- `option` 有，但只 match `ip30`（NMEA）/ `ip40`（AT），**不 match 我們的 `ipFF`**
- `qmi_wwan` 完全沒有 `030b` 任何條目

→ 任何 driver 都不會自動 bind。**動態 ID 注入（`echo "2c7c 030b" > new_id`）此路不通**，因為 `qmi_wwan` 用的是 `QMI_MATCH_FF_FF_FF` macro，必須在 compile-time 寫死。
</details>

---

### 3. Patch source 補上 PID

在 `drivers/net/usb/qmi_wwan.c` 加一行：

```diff
  {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0306)},  /* Quectel EP06/EG06/EM06 */
+ {QMI_MATCH_FF_FF_FF(0x2c7c, 0x030b)},  /* Quectel EM060K-GL */
  {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0512)},  /* Quectel EG12/EM12 */
```

插在 line 1095 與 1096 之間。位置是參考既有 Quectel 系列模組（0x0306 / 0x0512）的填法，因為 EM060K-GL 跟它們同屬 QMI-over-USB 走 ff/ff/ff interface 的家族。

<details>
<summary>細節 — patch 檔與 macro 解析</summary>

`QMI_MATCH_FF_FF_FF` macro 展開：
```c
#define QMI_MATCH_FF_FF_FF(vend, prod) \
    USB_DEVICE_AND_INTERFACE_INFO(vend, prod, 0xFF, 0xFF, 0xFF)
```
意思是「VID + PID + interface class/subclass/protocol 都是 FF」——與 step 2 看到的 modem descriptor 完全對應。

完整 patch：[qmi_wwan.patch](qmi_wwan.patch)
</details>

---

### 4. 用 Yocto SDK cross compiler 單獨編 `qmi_wwan.ko`

用平台官方 SDK toolchain `aarch64-qcom-linux-gcc`，配合 kernel source `make M=drivers/net/usb modules` 局部編譯，**不用編整顆 kernel**。

⭐ 最關鍵：**`vermagic` 必須跟 target 一模一樣**，否則 `modprobe` 會直接拒絕。

<details>
<summary>細節 — 三個必須對齊 + 編譯流程</summary>

**Target vermagic**：
```
6.6.119-qli-1.8-ver.1.1-06201-g380a343250d3-dirty SMP preempt mod_unload aarch64
```

**對齊三件事**：
1. `.config` 從 target `adb pull` 過來，host 預設 config 對不齊（會多 UBSAN/RANDOM_KMALLOC 之類）
2. ⭐ `Module.symvers` 也從 target `adb pull` 過來（省 20~40 分鐘的 `make vmlinux`）
3. `CONFIG_LOCALVERSION` 改成完整後綴 + `LOCALVERSION_AUTO=n`，再用 env `LOCALVERSION=""` 抑制 `setlocalversion` 自動加的 `+`

**SDK toolchain 陷阱**：不要 source `environment-setup-*`，那會污染 `CC` 帶 userspace flag（`-fstack-protector` / `--sysroot`），kernel build 會錯。只把 toolchain bin 加進 PATH 即可。

**完整 build script**：[build_qmi_wwan.sh](build_qmi_wwan.sh)
編譯時間：約 5 分鐘。
</details>

---

### 5. Push 到 target、insmod、驗證

把新 `qmi_wwan.ko` push 到 target persistent 位置（`/opt/`），`modprobe` dependencies (`usbnet` / `cdc_wdm`) 後 `insmod` 新版。Module 載入成功、vermagic 對齊、modalias 跟 driver alias 100% match。但**driver 仍不 bind modem interface**——這個矛盾推進到 step 6。

<details>
<summary>細節 — deploy 流程與 rootfs 注意事項</summary>

```bash
adb push qmi_wwan.ko /opt/        # /tmp 重開機會 wipe，改放 /opt
adb shell '
  modprobe usbnet                # insmod 不會自動載 dep，要先手動
  modprobe cdc_wdm
  insmod /opt/qmi_wwan.ko
'
```

注意：`/lib/modules` 在 ro mount (`/usr` 是 ro) 寫不進去，所以 debug 階段直接從 `/opt` insmod；要永久化需先 `mount -o remount,rw /usr`。

完整 deploy script：[deploy_qmi_wwan.sh](deploy_qmi_wwan.sh)
</details>

---

### 6. Reboot 後驗證 → 揭露真實根因

懷疑 debug 過程中對 USB sysfs (`authorize` / `bConfigurationValue` / `unbind/bind`) 的實驗把 USB 狀態弄壞。`adb shell reboot` 冷開機後重做，從乾淨環境再驗證——driver register 訊息有、module 載入正常、但 **driver 還是不 bind**，dmesg 連一個 probe attempt 訊息都沒。

🎯 翻 source 找到真實原因——`qmi_wwan.c:1575`：

```c
/* QMI-interface 跟 diagnostic 的 class/subclass/protocol 相同
 * 差別在 bNumEndpoints。 */
if (desc->bNumEndpoints == 2)
    return -ENODEV;
```

我們的 modem interface **`bNumEndpoints=2`**——`qmi_wwan` 看到 2 個 endpoint 就主動 reject，認為這是 diagnostic interface (DM)，不是真正的 QMI/RmNet interface。換言之 **modem 暴露的只是 DM channel，沒進 application mode**。

<details>
<summary>細節 — qmi_wwan probe 邏輯與 modem 異常狀態判斷</summary>

EM060K-GL 正常 application mode 應該暴露 5~7 個 interface（DM / NMEA / AT / AT / QMI 或 MBIM），其中 QMI/RmNet interface 會有 **3 個 endpoint**（2 bulk + 1 interrupt 給 cdc_wdm control channel）。

我們現在看到的：
```
bNumInterfaces:  1
Interface 0:
  bInterfaceClass:    FF (vendor-specific — 看起來像 QMI)
  bInterfaceSubClass: FF
  bInterfaceProtocol: FF
  bNumEndpoints:      2    ← 只有 2 個 bulk，沒 interrupt EP
```

`bNumEndpoints==2` + 單一 interface 是 Quectel modem **diagnostic-only mode** 的 signature，通常出現在：
- Modem application firmware 沒成功 boot（卡在 boot loader）
- Firmware 損毀
- 上次 firmware update 中斷
- 第一次使用、原廠 firmware 異常

Boot 時間軸也呼應：modem USB enumerate 花了 42 秒，遠超正常 cold boot 時間，看起來像試 boot application 失敗後 fallback 到 diagnostic mode。

⚠️ **這也意味著 step 2 對 OpenWrt issue 的對照是表層判斷**：OpenWrt 報告的 modem 是在正常 application mode (multi-interface)，patch PID 才有意義；我們 modem 連 multi-interface 都沒進到，patch 進去也無解。
</details>

---

## Before / After 對比

### Before — 原始狀態：driver 沒掛、interface 無人 bind
```
$ adb shell
$ lsmod | grep qmi_wwan
(空)                                  ← 沒人載入

$ ls /sys/class/net/
can0  eth0  eth1  lo                  ← 沒有 wwan0

$ ls /sys/bus/usb/devices/3-1.4:1.0/driver
No such file or directory             ← interface 沒被任何 driver bind
```

### After — patched module 已載入 + alias match，但 driver 仍拒絕 bind
```
$ adb shell

# Module 載入正常
$ lsmod | grep -E "qmi_wwan|cdc_wdm|usbnet"
qmi_wwan   40960  0
cdc_wdm    28672  1 qmi_wwan
usbnet     53248  1 qmi_wwan

# Vermagic 對齊
$ modinfo /opt/qmi_wwan.ko | grep vermagic
vermagic: 6.6.119-qli-1.8-ver.1.1-06201-g380a343250d3-dirty SMP preempt mod_unload aarch64
                                       ↑ 與 target 完全一致

# Modem 已 enumerate，alias 100% match
$ cat /sys/bus/usb/devices/2-1.4:1.0/modalias
usb:v2C7Cp030Bd0000dc00dsc00dp00icFFiscFFipFFin00

$ modinfo /opt/qmi_wwan.ko | grep "030B"
alias: usb:v2C7Cp030Bd*dc*dsc*dp*icFFiscFFipFFin*
                                       ↑ 已含 0x030B,跟 modalias 完全 match

# 但 driver 沒 bind：
$ cat /sys/bus/usb/devices/2-1.4:1.0/bNumEndpoints
02                                     ← 🎯 兇手:只有 2 endpoint
                                          → qmi_wwan.c:1575 主動 return -ENODEV
$ ls /sys/bus/usb/devices/2-1.4:1.0/driver
No such file or directory              ← interface 仍未被 bind

$ ls /sys/class/net/
can0  eth0  eth1  lo                   ← wwan0 仍未出現
$ ls /dev/cdc-wdm*
No such file or directory
```

**結論**：driver-side 修補完整，但 modem-side 沒進 application mode → driver probe 主動拒絕 → 整段 software stack 起不來。問題從 driver patch 層轉移到 modem firmware / hardware 層 — 進入 step 7。

---

### 7. HW 量測 preset pin 波形 → 確認真正根因

把 modem 退到「不能 bind」的怪狀（USB 認得但只 1 interface / 2 endpoints）跟「為什麼別張同類卡都 OK」放在一起看，EE 直接示波器量 B-Key 上幾根 boot strap pin。發現 **preset pin (B-Key Pin 6, `FULL_CARD_POWER_OFF#` / 等效 `PERST#`) 被板上 0 ohm 預設拉到 3.3V high 的狀態下，EM060K-GL 上電後該 pin 出現異常震盪波形**——modem 內部 reset / power sequencing 進入未定義狀態，application firmware 沒成功 boot，只剩 diagnostic interface 暴露出來。

⭐ **修法**：把該 preset pin 上的 0 ohm 電阻**拔掉**（讓 pin 預設浮接 / pull-low，不再被板子強拉 3.3V）。模組本身在 power-on 後會自己拉一下 **1.8V high pulse** 做內部 reset——這才是 Quectel datasheet 預期的 power-on 時序。

拔阻後實測（adb 量到的最終狀態）：

- USB enumeration 從 1 interface → **7 interfaces**（DM / 多個 AT/vendor / MBIM control / MBIM data / 1 個未識別輔助口）
- vendor-class interface (`ff/ff/40`) 的 `bNumEndpoints` 從 2 → **3**，跟其它平台正常 modem 一致
- `cdc_mbim` 用 **CDC standard class match**（`02/0e` + `0a`）直接 bind MBIM control/data interface
- `wwan0` / `/dev/cdc-wdm0` 出現
- AT/DM port 由 generic `option` driver 接走（也是 class match,不需要 PID）
- `mbim-network` 撥號拿到中華電信真實 IP `10.233.74.136`、ping / DNS 全通

⭐ **重要修正**：原以為一定要 patch `qmi_wwan.c` 加 PID `0x030b` 才能 bind,實測 HW 修好之後 modem 走的是 MBIM composition,`cdc_mbim` 看 class code 就吃下去了 — **PID patch 對當前工作模式是 no-op**。詳見開頭 "驗收後發現" 註記。

最終 interface map：

| Interface | class/sub/proto | EP | Driver | 用途 |
|---|---|---|---|---|
| 1.0 | `ff/ff/30` | 2 | option | DM (診斷口) |
| 1.1 | `ff/00/40` | 3 | option | AT-like |
| 1.2 | `ff/ff/40` | 3 | option | AT |
| 1.3 | `ff/ff/40` | 3 | option | AT |
| 1.8 | **`02/0e/00`** | 1 | **cdc_mbim** | MBIM control (走 `/dev/cdc-wdm0`) |
| 1.9 | **`0a/00/02`** | 2 | **cdc_mbim** | MBIM data (走 `wwan0`) |
| 1.12 | `ff/ff/70` | 1 | — | 輔助口(可能 GNSS),目前無人 bind,不影響 |

<details>
<summary>細節 — 三種 preset 波形比對（示波器量測）</summary>

```
正常 preset (其他平台正常運作):
  3.3V ──┐ ┌─────────────────────────────  ← 一次 power-on 後穩定維持 high
         └─┘

異常 EM060K-GL (preset 被 0R 拉 high 的狀況):
  3.3V    ┌─┐   ┌─┐    ┌─┐               ← 異常震盪,modem 內部 sequencing 失常
       ───┘ └───┘ └────┘ └─────

正常 EM060K-GL (移除 0 ohm preset 後):
  1.8V         ┌─┐                       ← 模組自己拉 high pulse 做 reset
       ────────┘ └────────────────────       (預設 low,只在 boot 瞬間有 pulse)
```

關鍵差別：
- **電壓階位**：原本板子用 3.3V domain 拉，模組自己拉時是 **1.8V domain**——電位不對 modem 就誤判
- **方向性**：modem 預期 preset 是「我自己控制」的 output，板子卻強拉成 input + pull-high → 衝突
- **時序**：模組需要看到 preset 從 low 拉到 high 的 transition 來觸發 cold reset；一直 high 看不到 edge

對應 M.2 spec 上 `FULL_CARD_POWER_OFF#` 應由 host 控制 (open-drain) 而不是用 0R 強拉到 VCC——這顆預留電阻是初版 layout 為了「保險開機」加的，反而踩到 EM060K-GL 的 power-on requirement。

教訓：M.2 module 的 enable / preset 類 pin，預設應該是 pull-low + host 主動控制，不要用 0R 強拉 high。後續 layout review 應把這類「保險用的 0R 上拉」全部 audit 一次。
</details>

---

## Before / After 對比（最終 — preset 0R 移除後）

```
$ adb shell ls /sys/class/net/
can0  eth0  eth1  lo  wwan0              ← wwan0 出現

$ adb shell ls /dev/cdc-wdm*
/dev/cdc-wdm0                            ← MBIM control device 出現

$ adb shell cat /sys/bus/usb/devices/3-1.4/bNumInterfaces
05                                       ← 5 個 interface (DM/NMEA/AT/AT/MBIM)

$ adb shell './mbim.sh'
... mbim-network start ok
udhcpc: lease of 10.233.74.136 obtained  ← 中華電信真實 IP
PING 8.8.8.8: 3 packets transmitted, 3 received, 0% packet loss
```

---

## 目前狀態 / 後續

### Hardware (根因)
- ✅ **B-Key Pin 6 preset 上的 0 ohm 拉 high 電阻已拔除**（EE 改板完成）
- ✅ Pin 預設 low、由模組自己拉 1.8V high pulse 做 reset
- ✅ Modem 進 application mode、5 個 interface 全暴露

### Software side (driver / 編譯 / 部署流程)
- ✅ Patch 加入 PID `0x030b` 完成 — ⚠️ 事後發現對當前 MBIM composition 是 no-op,`cdc_mbim` 用 CDC class match 就接得到。保留價值僅在「若將來 modem 切到 vendor-class QMI mode 才會用上」
- ✅ Cross compile single module 流程跑通 (Yocto SDK toolchain, `make M=...`) — 流程本身仍有重用價值,任何 kernel module patch 都能套同樣方法
- ✅ `vermagic` 完全對齊 target (`LOCALVERSION=""` trick, `.scmversion` 處理)
- ✅ Module.symvers / `.config` 從 target pull 對齊 (省 vmlinux build)
- ✅ Module 在 target 載入;不過真正 bind 資料路徑的是 `cdc_mbim`(走 standard CDC class),不是 `qmi_wwan`

### End-to-end 撥號
- ✅ `mbim-network` 撥號通、拿到 ISP 真實 IP、ping / DNS / download 全部驗證
- ✅ 自動化腳本 `mbim.sh` 部署到 `/etc/innodisk/dqe/mbim.sh`
- ⏳ ModemManager 自動撥（path B）需 BSP rebuild 加 `mbim qmi` PACKAGECONFIG + `ppp` / `networkmanager-plugin-wwan` — 已備 [bsp-prompt.md](bsp-prompt.md)

### Long-term
- ⏳ Layout review：audit 其它 M.2 enable / preset 類 pin 的 0R 上拉是否合理(避免下一張卡踩到同樣坑)
- ⏳ `qmi_wwan` PID patch 是否還要推 BSP — 視未來是否切 QMI mode 決定;走 MBIM 不需要

---

## 在別的對話框產生同樣風格報告的 Prompt

複製貼上以下整段給 Claude，就能用同樣風格產出 debug 報告。中括號內換成自己的內容：

````
請幫我把這次 debug 過程整理成「會議報告風格」的 markdown,放在 [檔案路徑]。

格式要求:
1. 開頭三行重點: 平台 / 症狀 / 結論 (一句話)
2. 「主流程」5~7 個編號步驟,每步只寫一行結論 + 一段 1~3 句的高層說明
3. 每步的技術細節用 GitHub <details><summary>細節</summary>...</details> 折疊起來
   (這樣會議時預設只看主流程,要 deep dive 才展開)
4. 步驟之間要點出因果關係 (例: step 3 為什麼那樣填,是因為 step 2 看到的觀察)
5. 結尾加 Before / After 對比區:
   - 實際 adb / shell log 貼上來,不要重寫
   - 關鍵欄位用 ← 箭頭加註解
   - 沒驗證的就老實寫「預期 / 待驗證」,不要假裝完成
6. 最後一個區塊「目前狀態 / 後續」,用 ✅ / ⏳ / ❌ 標每項進度
7. 連結用相對路徑指向同目錄的 patch / script (例: [qmi_wwan.patch](qmi_wwan.patch))
8. 用繁體中文,技術術語保留英文
9. 不要加裝飾性 emoji、不要寫 Disclaimer、不要寫感謝詞

語意 icon 使用 (只在有 weight 的地方用,不裝飾):
- 🎯 標在「根因」上 —— 開頭結論那行一個,正文裡找到 root cause 的那句一個。最多 2 個,讓讀者一眼掃到「真正的兇手在這」
- ⭐ 標在「關鍵突破點 / 可重用的技巧」—— 例如踩坑後找出來的 workaround、省時間的捷徑、會議後別人會想抄走的那種句子。整篇 2~3 個就夠
- ⚠️ 標在「坑 / 容易出錯處」—— 例如「不要 source 那個 env file 因為會污染 CC」這種反指引
- ✅ / ⏳ / ❌ 只用在「目前狀態」區塊的進度標記
- 不要用 🚀 🎉 🔥 💪 之類純情緒裝飾的 emoji

寫作態度:
- 細節 collapse 是為了會議簡報時一目瞭然,展開後要夠完整能讓接手的人重現
- 「我做了什麼」是重點,不是「為什麼這很重要」
- 不確定的地方標 ⏳ 比硬寫成 ✅ 好
- icon 寧可少用,2~3 個 ⭐ 比 10 個 ⭐ 有效;一個 🎯 比五個 🎯 有效

這次 debug 的背景跟我蒐集到的資料:
[把症狀、log、查到的關鍵發現、做了什麼、結果貼上來]
````

> 範例輸出: 即為本檔 [REPORT.md](REPORT.md) 本身 (這份報告就是用這個 prompt 風格做的)。
