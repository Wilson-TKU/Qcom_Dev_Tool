---
name: qcom-debug
description: Use when the user asks to debug or investigate an issue on the Qualcomm target device (display/DP/eDP/MIPI/HDMI, audio, kernel/dmesg, power, thermal, boot, network, performance, etc.). Triggers on phrases like "幫我看 display", "debug DP", "查 dmesg", "adb 連入看", "ssh 進去看", "板子上的 X 不會動", "kernel panic", "screen 黑屏", or any request to run diagnostics on the Qcom platform.
---

# Qcom Platform Debug Skill

通用 Qualcomm 平台 debug 入口。此 skill 在使用者要求對 target device 進行除錯時觸發。

## Platform Context

- SoC codename: **LeMans** (SA8775P, Snapdragon Ride Flex / Auto)
- OS on target: **Qualcomm Linux (QLI / qimpsdk)** — 不是 Android，但部分 build 仍支援 `adb`
- Boot chain: XBL (SBL) → UEFI → Kernel；本專案常修改 `xbl.elf` / `xbl_config.elf` / `dtb`
- Host toolchain dirs in this repo:
  - [fw/](../../../fw/) — firmware build & flash (xbl, uefi)
  - [dtb/](../../../dtb/) — DTB modify / flash
  - [image/](../../../image/) — full image flash via qdl
  - [debug-tool-jtag/](../../../debug-tool-jtag/) — JTAG/openocd

## Connection Methods

使用者每次會告訴你採用哪一種連線方式。**不要假設**，先確認後再執行。

### 1. ADB
```bash
adb devices                   # 確認裝置
adb root && adb wait-for-device
adb shell <cmd>
adb pull <remote> <local>
adb logcat -d                 # 若有 Android logcat
```
若 adb 透過 TCP：`adb connect <ip>:5555` 後一樣操作。

### 2. SSH
```bash
ssh <user>@<ip>               # 使用者會在對話中給 user/ip
ssh <user>@<ip> '<cmd>'       # 一次性遠端指令
scp <user>@<ip>:<remote> .    # 拉檔
```

### 3. Serial / UART
```bash
sudo picocom -b 115200 /dev/ttyUSB0
# 或
sudo minicom -D /dev/ttyUSB0 -b 115200
```
Serial 主要用於看 boot log / kernel panic / 無法進入 OS 的情境。

## Workflow — Ask First, Then Execute

當使用者提出 debug 需求時，按以下流程：

1. **釐清問題**：症狀為何？什麼時候發生？是否可重現？最近改過什麼 (firmware / dtb / kernel cmdline)？
2. **列出排查計畫**：先告訴使用者你打算跑哪些**唯讀**指令 (dmesg/cat/ls/getprop)、為什麼要看這些。
3. **取得使用者確認**後再執行。
4. **任何寫入動作** (echo > sysfs、修改 prop、reboot、rmmod/insmod、flash) 都**必須**先明確確認。
5. 收到輸出後 → 摘要重點 → 推測下一步 → 再次確認。

## Common Diagnostic Snippets

### Kernel / Boot
```bash
dmesg | tail -200
dmesg -T | grep -iE 'error|fail|warn|panic|bug'
cat /proc/cmdline
cat /proc/version
uname -a
journalctl -b -p err          # systemd 系統
journalctl -k -b              # 本次 boot 的 kernel log
```

### Display (DP / eDP / MIPI / HDMI)
DRM/KMS 在 Qcom Linux 上路徑：
```bash
# Connectors / modes / status
ls /sys/class/drm/
for c in /sys/class/drm/card*-*; do
  echo "=== $c ==="; cat $c/status; cat $c/modes 2>/dev/null | head; cat $c/enabled 2>/dev/null;
done

# EDID dump (DP/HDMI hotplug 排查)
cat /sys/class/drm/card0-DP-1/edid | xxd | head

# DRM debug (寫入動作 → 先確認)
# echo 0x1ff > /sys/module/drm/parameters/debug

# MSM/Adreno DRM debugfs
ls /sys/kernel/debug/dri/0/
cat /sys/kernel/debug/dri/0/state 2>/dev/null
cat /sys/kernel/debug/dri/0/clients 2>/dev/null

# DPU (Display Processing Unit) trace
ls /sys/kernel/debug/dri/0/*dpu* 2>/dev/null

# 跑 modetest (libdrm-tests)
modetest -M msm_drm
```
DP link training 失敗時的常見檢查：HPD 狀態、EDID 是否讀到、link rate / lane count、AUX 通訊。

### Audio
```bash
aplay -l                       # ALSA 卡與裝置
cat /proc/asound/cards
cat /proc/asound/card0/codec*
amixer -c 0 contents | head -50
# PulseAudio / PipeWire
pactl list sinks short
wpctl status
```

### Power / Thermal
```bash
cat /sys/class/thermal/thermal_zone*/type
cat /sys/class/thermal/thermal_zone*/temp
cat /sys/class/power_supply/*/uevent
cat /sys/kernel/debug/clk/clk_summary | head -50
cat /sys/kernel/debug/regulator/regulator_summary | head -50
```

### CPU / Performance
```bash
cat /proc/loadavg
top -bn1 | head -20
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
cat /sys/devices/system/cpu/online
```

### Storage / FS
```bash
mount | grep -v tmpfs
df -h
lsblk
cat /proc/partitions
```

### Network
```bash
ip a
ip r
ping -c 3 8.8.8.8
nmcli d         # 若使用 NetworkManager
```

### Process / Module
```bash
ps -ef | grep -i <name>
lsmod
modinfo <module>
```

## When the Box Is Bricked / Won't Boot

- Serial console 看 XBL/UEFI log → 對應到 [fw/](../../../fw/) 重新 build
- DTB 可疑 → [dtb/flash_dtb.sh](../../../dtb/flash_dtb.sh) 燒回 golden DTB
- 完全 brick → 進 EDL (9008) → [image/flash-image.sh](../../../image/flash-image.sh) via qdl

## Output Discipline

- 遠端指令輸出可能很長：先用 `head`/`tail`/`grep` 過濾，避免一次貼上百行。
- 把 raw log 摘要成「症狀 → 觀察 → 假設 → 下一步」四段，再請使用者裁決。
- 多步操作之間每次都簡短回報結果，不要在背景跑一大串再一次性回報。

## What NOT to Do Without Explicit Confirmation

- `reboot` / `shutdown` / `kexec`
- `echo X > /sys/...` 任何 sysfs 寫入
- `rmmod` / `insmod` / `modprobe -r`
- 任何 `flash_*.sh` / qdl flash
- 改 `/etc/`、`/boot/`、kernel cmdline、bootargs
- `dd` 到 block device
- 殺 systemd service (`systemctl stop/disable`)

確認過後可以做，但每次都要明確徵詢，不能因為前一次允許就連續做。
