#!/bin/bash
# manual_build.sh
# 用途: 當你手動修改完 pm_sbl_boot_oem.c 和 pm.dtsi 之後，執行此腳本來編譯並提取檔案。
# 用法: ./manual_build.sh <自訂輸出目錄名稱>

if [ -z "$1" ]; then
    echo "請提供輸出資料夾名稱！"
    echo "用法: $0 <自訂輸出目錄名稱>"
    echo "範例: $0 my_custom_test"
    exit 1
fi

OUT_FOLDER_NAME="$1"

BASE_DIR="/media/wilson/nvme_Wilson_Data1/fw_00120/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1"
OUT_DIR="/media/wilson/nvme_Wilson_Data1/fw_00120/power_button_experiments/fw-image/$OUT_FOLDER_NAME"

# 來源檔案路徑
DTSI_PATH="$BASE_DIR/boot_images/boot/Settings/Soc/LeMans/Core/PMIC/pm.dtsi"
C_PATH="$BASE_DIR/boot_images/boot/QcomPkg/Library/PmicLib/target/lemans/system/src/pm_sbl_boot_oem.c"
XBL_ELF="$BASE_DIR/boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/xbl.elf"
XBL_CONFIG_ELF="$BASE_DIR/boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/xbl_config.elf"

# 設定環境變數
export SECTOOLS="/media/wilson/nvme_Wilson_Data1/fw_00120/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux/sectools"
export SECTOOLS_DIR="/media/wilson/nvme_Wilson_Data1/fw_00120/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux"
export HEXAGON_ROOT=$HOME/Qualcomm/HEXAGON_Tools
export DTC=/usr/bin
export LLVM=/media/wilson/nvme_Wilson_Data1/fw_env/llvm/14.0.4/

echo "================================================="
echo "開始編譯 XBL (跳過 cleanall 進行增量編譯)..."
cd "$BASE_DIR" || exit

# 執行編譯指令
python -u boot_images/boot_tools/buildex.py -t lemans,QcomToolsPkg -v LAA -r RELEASE

if [ $? -ne 0 ]; then
    echo "================================================="
    echo "錯誤: 編譯失敗，請檢查你手動修改的程式碼！"
    exit 1
fi

echo "================================================="
echo "編譯成功！正在提取檔案至 $OUT_DIR ..."
mkdir -p "$OUT_DIR"

# 複製剛編譯好的檔案和原始碼到指定資料夾
cp "$DTSI_PATH" "$OUT_DIR/pm.dtsi"
cp "$C_PATH" "$OUT_DIR/pm_sbl_boot_oem.c"
cp "$XBL_ELF" "$OUT_DIR/xbl.elf"
cp "$XBL_CONFIG_ELF" "$OUT_DIR/xbl_config.elf"

echo "完成！檔案已儲存於 $OUT_DIR 。"
echo "你可以使用 flash_xbl.sh 來進行燒錄測試，例如："
echo "./flash_xbl.sh $OUT_FOLDER_NAME"
