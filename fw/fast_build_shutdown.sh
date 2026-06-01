#!/bin/bash
# fast_build_shutdown.sh

# 1. 定義路徑
BASE_DIR="/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1"
SDK_C_PATH="$BASE_DIR/boot_images/boot/QcomPkg/Library/PmicLib/target/lemans/system/src/pm_sbl_boot_oem.c"
MY_C_PATH="/media/wilson/nvme_Wilson_Data1/fw_00117/power_button_experiments/comb_PM_SHUTDOWN_2s/pm_sbl_boot_oem.c"
TARGET_DIR="/media/wilson/nvme_Wilson_Data1/fw_00117/power_button_experiments/comb_PM_SHUTDOWN_2s"

# 2. 設定環境變數 (根據 fw_00117 修改)
export SECTOOLS="/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux/sectools"
export SECTOOLS_DIR="/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux"
export HEXAGON_ROOT=$HOME/Qualcomm/HEXAGON_Tools
export DTC=/usr/bin
export LLVM=/media/wilson/nvme_Wilson_Data1/fw_env/llvm/14.0.4/

echo "================================================="
echo "1. 將修改過的 pm_sbl_boot_oem.c 複製到 SDK 目錄..."
echo "來源: $MY_C_PATH"
echo "目的: $SDK_C_PATH"
cp "$MY_C_PATH" "$SDK_C_PATH"

echo "================================================="
echo "2. 切換到 SDK 目錄進行增量編譯 (加速版，跳過 cleanall)..."
cd "$BASE_DIR" || exit
# 注意：這裡刻意拿掉了 --build_flags=cleanall，讓它只編譯有修改的 C 檔
python -u boot_images/boot_tools/buildex.py -t lemans,QcomToolsPkg -v LAA -r RELEASE

# 如果編譯失敗則中斷
if [ $? -ne 0 ]; then
    echo "================================================="
    echo "錯誤: 編譯失敗，請檢查程式碼！"
    exit 1
fi

echo "================================================="
echo "3. 編譯成功！將結果 xbl.elf 複製回 comb_PM_SHUTDOWN_2s 目錄..."
OUT_BIN="$BASE_DIR/boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/xbl.elf"
OUT_CFG="$BASE_DIR/boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/xbl_config.elf"

cp "$OUT_BIN" "$TARGET_DIR/"
cp "$OUT_CFG" "$TARGET_DIR/"

echo "完成！你可以進入 $TARGET_DIR 使用 flash 腳本燒錄測試了。"
