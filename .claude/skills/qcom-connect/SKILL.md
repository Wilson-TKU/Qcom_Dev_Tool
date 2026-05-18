---
name: qcom-connect
description: Use to establish or pick a connection channel to the Qualcomm target device before running any on-device command. Triggers when the user says things like "連進去看", "adb 一下", "ssh 進去", "從 UART 看", "板子有沒有連上", "跑這個指令到板子上", or any request that implies executing something on the target rather than the host. Resolves which of ADB / UART / SSH to use.
---

# Qcom Platform Connect Skill

決定並建立到 target device 的連線管道。在任何「對板子下指令」的動作**之前**先走過此 skill。

## Available Channels

使用者環境支援三種通道，**預設順序**：

1. **ADB shell** — 通常已接上，預設首選
2. **UART debug console** — `/dev/ttyUSB0`，用於開機 log / kernel panic / 無法進 OS 時
3. **SSH** — 須跟使用者要 IP (與帳號)

## Decision Flow

收到「對板子下指令」需求時：

### Step 1 — 預設嘗試 ADB
使用者通常已把板子用 USB 接上，**直接先試 adb**：
```bash
adb devices
```
- 有列出 device → 直接用 `adb shell <cmd>`
- 列出但 `unauthorized` → 提示使用者在板子上按授權對話框
- 空的 / `no devices` → 走 Step 2 詢問

需要 root 權限的指令前：
```bash
adb root && adb wait-for-device
adb shell <cmd>
```

### Step 2 — ADB 不通時，詢問使用者要切哪一條
不要自己亂試 (不要直接打開 `/dev/ttyUSB0`，可能會搶到其他 serial 工具)。**先問**：

> ADB 沒抓到裝置，要走 UART (/dev/ttyUSB0) 還是 SSH？SSH 的話請給我 `<user>@<ip>`。

### Step 3 — 按使用者選擇建立連線

#### UART (`/dev/ttyUSB0`)
```bash
# 確認裝置存在 & 沒被佔用
ls -l /dev/ttyUSB0
lsof /dev/ttyUSB0 2>/dev/null || sudo fuser /dev/ttyUSB0
```
**互動式**使用者自己開：
```bash
sudo picocom -b 115200 /dev/ttyUSB0
# 或
sudo minicom -D /dev/ttyUSB0 -b 115200
```
**腳本化抓 log** (短期擷取)：
```bash
sudo stty -F /dev/ttyUSB0 115200 raw -echo
sudo timeout 10 cat /dev/ttyUSB0
```
UART 場景下我**不會**直接接管 serial — 由使用者貼 log 給我看，或請使用者在 console 跑指令把結果貼回。

#### SSH (要 IP)
拿到 `<user>@<ip>` 後：
```bash
ssh <user>@<ip>                    # 互動
ssh <user>@<ip> '<cmd>'            # 一次性
scp <user>@<ip>:<remote> .         # 拉檔
```
第一次連線會問 host key，告訴使用者出現時直接 yes。

## Quick Check Snippets

每種通道都先確認「真的連到對的板子」再執行業務指令：

```bash
# ADB
adb shell 'uname -a; cat /etc/os-release 2>/dev/null; getprop ro.product.model 2>/dev/null'

# SSH
ssh <user>@<ip> 'uname -a; cat /etc/os-release'

# UART
# 在 console 內手動輸入 uname -a
```

## Conventions

- **預設不問先試 adb**：使用者說「板子上看 X」直接 `adb devices` + `adb shell`，不要每次都先問通道。
- **adb 失敗時再問**：不要瞎試 UART/SSH。
- **SSH IP 不要記在 skill 裡**：每次跟使用者要 (IP 可能會變)。
- **同一段對話內可重用**：若使用者這次選了 SSH `wilson@192.168.x.x`，後續同對話內可繼續用，不必每次重問。
- **單一指令傳送**：偏好 `adb shell '<cmd>'` / `ssh user@ip '<cmd>'` 形式而非進互動 shell，方便擷取輸出。
- **長輸出先過濾**：`| head`, `| tail`, `| grep` 在遠端就過濾完，不要把整份 dmesg 拉回 host。

## Hand-off to Other Skills

連上之後實際的 debug 內容請走 [[qcom-debug]] skill (display / audio / kernel / power 等診斷指令)。此 skill 只負責「怎麼連」。
