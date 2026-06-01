#!/bin/bash
# Build qmi_wwan.ko with Quectel EM060K-GL (0x030b) PID patched in.
# Target: QLI 1.8-ver.1.1, kernel 6.6.119-qli-1.8-ver.1.1-06201-g380a343250d3-dirty
#
# 流程：
#  1. patch drivers/net/usb/qmi_wwan.c 加入 0x030b
#  2. 鎖死 LOCALVERSION 與 .scmversion 讓 vermagic 對得起 target
#  3. make modules_prepare (產生 Module.symvers / 所需 generated header)
#  4. make M=drivers/net/usb modules (只編這個目錄)
#  5. 驗證 vermagic + 030b 字串是否在 .ko 內

set -euo pipefail

KSRC=/media/wilson/nvme_Wilson_Data1/kernel-src/QLI1.8_qcom
SDK=/media/wilson/nvme_Wilson_Data1/cross_compiler/v2.3.0
PATCH=/media/wilson/nvme_Wilson_Data1/github/Qcom_Dev_Tool/debug/5G-modem/qmi_wwan.patch

# Qcom SDK 的 aarch64-qcom-linux-gcc 位置
TOOLCHAIN_BIN="$SDK/sysroots/x86_64-qcomsdk-linux/usr/bin/aarch64-qcom-linux"

# 注意：不 source environment-setup-* (那會污染 CC/CXX 帶 userspace flag)
# 只把 toolchain 加進 PATH，讓 kernel Makefile 自己用
export PATH="$TOOLCHAIN_BIN:$PATH"
export ARCH=arm64
export CROSS_COMPILE=aarch64-qcom-linux-

# 確認 compiler 在
command -v aarch64-qcom-linux-gcc >/dev/null || { echo "ERR: aarch64-qcom-linux-gcc not found in PATH"; exit 1; }
echo "==> Using: $(aarch64-qcom-linux-gcc --version | head -1)"

cd "$KSRC"

# 1. Patch qmi_wwan.c (idempotent)
if grep -q "0x030b" drivers/net/usb/qmi_wwan.c; then
  echo "==> qmi_wwan.c already has 0x030b, skip patch"
else
  patch -p1 < "$PATCH"
  echo "==> Patched qmi_wwan.c"
fi

# 2. 鎖 vermagic：6.6.119-qli-1.8-ver.1.1-06201-g380a343250d3-dirty
#    a) CONFIG_LOCALVERSION="-qli-1.8-ver.1.1"
#    b) .scmversion 寫死 git 段，避免 setlocalversion 重新計算
echo "-06201-g380a343250d3-dirty" > .scmversion
sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-qli-1.8-ver.1.1"|' .config

# 3. Prepare
echo "==> make olddefconfig"
make olddefconfig
echo "==> make modules_prepare"
make modules_prepare -j"$(nproc)"

# 3.5 Module.symvers — modules_prepare 不會產生它，正規做法要 'make vmlinux'
#     但 target /lib/modules/$(uname -r)/build/ 內已有 BSP build 完整 symvers，
#     直接 adb pull 過來省 20~40 分鐘 (這也保證 symbol CRC 與 target kernel 完全一致)
if [ ! -f Module.symvers ]; then
  echo "==> Module.symvers missing — pull from target via adb"
  KREL=$(adb shell uname -r | tr -d '\r')
  adb pull "/lib/modules/$KREL/build/Module.symvers" Module.symvers
  wc -l Module.symvers
fi

# 4. 只編 drivers/net/usb 內的 module (含 qmi_wwan.ko)
echo "==> Build drivers/net/usb modules"
make M=drivers/net/usb modules -j"$(nproc)"

# 5. Verify
echo ""
echo "==> qmi_wwan.ko built:"
ls -l drivers/net/usb/qmi_wwan.ko
echo ""
echo "==> vermagic (要跟 target 完全一致):"
"${TOOLCHAIN_BIN}/aarch64-qcom-linux-modinfo" drivers/net/usb/qmi_wwan.ko 2>/dev/null | grep -E "vermagic|filename" \
  || modinfo drivers/net/usb/qmi_wwan.ko 2>/dev/null | grep -E "vermagic|filename" \
  || strings drivers/net/usb/qmi_wwan.ko | grep -E "^[0-9]+\.[0-9]+\.[0-9]+-qli" | head -1
echo ""
echo "==> 確認 0x030b 已編進 ID table:"
"${TOOLCHAIN_BIN}/aarch64-qcom-linux-objdump" -s -j .rodata drivers/net/usb/qmi_wwan.ko \
  | grep -iE "7c2c.*0b03|0b03.*7c2c" | head -3 \
  || echo "(用 readelf / strings 再驗一次)"

echo ""
echo "==> 完成。下一步：debug/5G-modem/deploy_qmi_wwan.sh"
