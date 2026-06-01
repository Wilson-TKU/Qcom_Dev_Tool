#!/bin/bash
# Deploy newly-built qmi_wwan.ko to target via adb, then reload and verify.
# Pre-requisite: build_qmi_wwan.sh has been run successfully.

set -euo pipefail

KSRC=/media/wilson/nvme_Wilson_Data1/kernel-src/QLI1.8_qcom
MOD="$KSRC/drivers/net/usb/qmi_wwan.ko"

[ -f "$MOD" ] || { echo "ERR: $MOD not found — run build_qmi_wwan.sh first"; exit 1; }

echo "==> Local module:"
ls -l "$MOD"
file "$MOD" 2>/dev/null

adb wait-for-device

echo "==> Push to /tmp/qmi_wwan.ko on target"
adb push "$MOD" /tmp/qmi_wwan.ko

echo "==> Replace + reload on target"
adb shell '
set -e
KREL=$(uname -r)
TARGET=/lib/modules/$KREL/kernel/drivers/net/usb/qmi_wwan.ko

# Backup once (不覆蓋原始備份)
if [ ! -f "${TARGET}.orig" ]; then
  cp "$TARGET" "${TARGET}.orig"
  echo "==> Backed up to ${TARGET}.orig"
fi

# Unload existing
rmmod qmi_wwan 2>/dev/null && echo "==> Unloaded old qmi_wwan" || echo "==> qmi_wwan not loaded"

# Replace
cp /tmp/qmi_wwan.ko "$TARGET"
depmod -a

# Reload
modprobe qmi_wwan
sleep 2

echo ""
echo "==> /sys/class/net:"
ls /sys/class/net/
echo ""
echo "==> /dev cdc-wdm / wwan:"
ls /dev/cdc-wdm* /dev/wwan* 2>&1
echo ""
echo "==> USB 3-1.4:1.0 driver bind:"
ls -l /sys/bus/usb/devices/3-1.4:1.0/driver 2>&1
echo ""
echo "==> dmesg tail:"
dmesg | tail -15
'
