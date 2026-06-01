#!/bin/bash
export SECTOOLS=/media/wilson/nvme_Wilson_Data1/fw_00114/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux/sectools
export SECTOOLS_DIR=/media/wilson/nvme_Wilson_Data1/fw_00114/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux
export HEXAGON_ROOT=$HOME/Qualcomm/HEXAGON_Tools
export DTC=/usr/bin
export LLVM=/media/wilson/nvme_Wilson_Data1/fw_env/llvm/14.0.4/
# 檢查是否有傳入測試名稱參數
if [ -z "$1" ]; then
    echo "錯誤: 請提供測試名稱！"
    echo "用法: $0 <測試名稱>"
    echo "範例: $0 test_warm_reset_2s"
    exit 1
fi

TEST_NAME=$1
# 取得當前時間作為資料夾名稱後綴
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 設定輸出資料夾路徑 (建立在當前目錄的 test_results 下面, 以參數命名)
OUTPUT_DIR="test_results/${TEST_NAME}_${TIMESTAMP}"

echo "================================================="
echo " 開始執行測試參數: $TEST_NAME"
echo " 測試紀錄與檔案備份將會儲存至:"
echo " -> $OUTPUT_DIR"
echo "================================================="

# 建立紀錄資料夾
mkdir -p "$OUTPUT_DIR"

# 要備份的修改檔案路徑
PM_DTSI="boot_images/boot/Settings/Soc/LeMans/Core/PMIC/pm.dtsi"
PM_SBL_BOOT_OEM="boot_images/boot/QcomPkg/Library/PmicLib/target/lemans/system/src/pm_sbl_boot_oem.c"

# 備份檔案到紀錄資料夾內
echo "-> 備份測試修改過的檔案..."
if [ -f "$PM_DTSI" ]; then
    cp "$PM_DTSI" "$OUTPUT_DIR/"
else
    echo "警告: 找不到 $PM_DTSI"
fi

if [ -f "$PM_SBL_BOOT_OEM" ]; then
    cp "$PM_SBL_BOOT_OEM" "$OUTPUT_DIR/"
else
    echo "警告: 找不到 $PM_SBL_BOOT_OEM"
fi

echo "================================================="
echo "-> 開始編譯 (1/2 Clean)..."
python -u boot_images/boot_tools/buildex.py -t lemans,QcomToolsPkg -v LAA -r RELEASE --build_flags=cleanall 2>&1 | tee "$OUTPUT_DIR/build_clean.log"

echo "================================================="
echo "-> 開始編譯 (2/2 Build)..."
python -u boot_images/boot_tools/buildex.py -t lemans,QcomToolsPkg -v LAA -r RELEASE 2>&1 | tee "$OUTPUT_DIR/build.log"

echo "================================================="
echo "-> 開始燒錄 (Flash)..."
./flash_xbl.sh ./boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/ 2>&1 | tee "$OUTPUT_DIR/flash.log"

echo "================================================="
echo " 測試 '$TEST_NAME' 執行完畢！"
echo " 修改的源代碼、編譯日誌(log) 與燒錄日誌(log) 皆已備份至："
echo "   $OUTPUT_DIR"
echo "================================================="