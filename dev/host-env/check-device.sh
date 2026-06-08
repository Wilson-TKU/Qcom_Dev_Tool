#!/bin/bash
#
# check-device.sh — 偵測高通板子目前接在 USB 上的狀態
# -----------------------------------------------------------------------------
# 判斷板子處於哪一種模式，方便決定下一步該用 qdl 燒錄、adb 還是 fastboot。
#   EDL/QDL  (05c6:9008)  → 可以用 qdl 燒錄
#   adb      (adb devices 有抓到) → 可以 adb shell
#   fastboot (fastboot devices 有抓到) → 可以 fastboot flash
# -----------------------------------------------------------------------------

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }

echo "=========================================="
echo " Qualcomm 板子 USB 狀態檢查"
echo "=========================================="

# --- 1. lsusb 看 VID/PID ---
log "lsusb (Qualcomm 05c6 / Google 18d1):"
LSUSB_OUT="$(lsusb | grep -iE '05c6|18d1|qualcomm|google')"
if [ -n "$LSUSB_OUT" ]; then
    echo "$LSUSB_OUT" | sed 's/^/    /'
else
    echo "    (沒看到，板子可能沒接、沒開機，或線只供電不傳輸)"
fi

# --- 2. 判斷 EDL ---
echo "------------------------------------------"
if lsusb | grep -qiE '05c6:9008'; then
    log "偵測到 EDL/QDL 模式 (05c6:9008) → 可以用 qdl 燒錄"
    echo "    範例: cd <repo>/image && ./flash-image.sh all <image 根目錄>"
else
    echo "    未在 EDL 模式 (沒有 05c6:9008)"
fi

# --- 3. adb ---
echo "------------------------------------------"
if command -v adb >/dev/null 2>&1; then
    ADB_OUT="$(adb devices | grep -vE '^List of devices' | grep -w device)"
    if [ -n "$ADB_OUT" ]; then
        log "adb 有抓到裝置 → 可以 adb shell"
        echo "$ADB_OUT" | sed 's/^/    /'
        echo "    進燒錄模式: adb shell reboot edl"
    else
        warn "adb 沒抓到裝置 (adb devices 為空或 unauthorized)"
        adb devices | sed 's/^/    /'
    fi
else
    warn "adb 未安裝 — 先跑 ./setup-host-env.sh apt"
fi

# --- 4. fastboot ---
echo "------------------------------------------"
if command -v fastboot >/dev/null 2>&1; then
    FB_OUT="$(fastboot devices 2>/dev/null)"
    if [ -n "$FB_OUT" ]; then
        log "fastboot 有抓到裝置"
        echo "$FB_OUT" | sed 's/^/    /'
    else
        echo "    fastboot 沒抓到裝置 (正常，除非在 bootloader)"
    fi
else
    warn "fastboot 未安裝 — 先跑 ./setup-host-env.sh apt"
fi

# --- 5. 權限提示 ---
echo "------------------------------------------"
if id -nG "$USER" | tr ' ' '\n' | grep -qx plugdev; then
    log "$USER 在 plugdev 群組 (qdl/adb 免 sudo OK)"
else
    warn "$USER 不在 plugdev 群組 → 跑 ./setup-host-env.sh udev 後重新登入"
fi
echo "=========================================="
