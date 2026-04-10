#!/bin/bash

# 獲取腳本目前的絕對路徑 (專案根目錄，用於找 qdl, provision, cdt, fw)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QDL_TOOL="$SCRIPT_DIR/qdl-2.3.1"

# ================= 路徑解析邏輯 =================
# 1. 設定 Image 的根目錄 (TARGET_IMAGE_ROOT)
if [ -n "$1" ]; then
    # 如果使用者有輸入參數 (例如 /media/wilson/...), 直接使用該路徑
    # ${1%/} 的作用是去掉路徑最後面的斜線 (/)，避免路徑拼接出現 //
    TARGET_IMAGE_ROOT="${1%/}"
else
    # 如果沒輸入，使用專案內的預設路徑
    TARGET_IMAGE_ROOT="$SCRIPT_DIR/image/EXMP-Q911_v0.0.3"
fi

echo "------------------------------------------"
echo "Script Location : $SCRIPT_DIR"
echo "Target Image Dir: $TARGET_IMAGE_ROOT"
echo "------------------------------------------"

# 2. 安全檢查：確認目標 Image 資料夾是否存在
if [ ! -d "$TARGET_IMAGE_ROOT" ]; then
    echo "Error: Directory $TARGET_IMAGE_ROOT does not exist!"
    exit 1
fi

# ==== Flash SAIL ====
# SAIL 在 Image 資料夾內的一層 (sail_nor)
echo "==== Flash SAIL... ===="
(
    # 使用 TARGET_IMAGE_ROOT 進入目標資料夾
    cd "$TARGET_IMAGE_ROOT/sail_nor" || exit
    "$QDL_TOOL" --storage spinor prog_firehose_ddr.elf rawprogram0.xml patch0.xml
)

# ==== Flash UFS-provision ====
# Provision 檔案仍在專案資料夾內 ($SCRIPT_DIR)，不受 Image 路徑影響
echo "==== Flash UFS-provision... ===="
"$QDL_TOOL" --storage ufs "$SCRIPT_DIR/image/ufs-provision-iq9/prog_firehose_ddr.elf" "$SCRIPT_DIR/image/ufs-provision-iq9/provision_1_2.xml"

# ==== Flash Main Image ====
echo "==== Flash Main image... ===="

# 自動判斷：有些版本 Image 檔案在 qcom-multimedia-image 子目錄，有些在根目錄
if [ -d "$TARGET_IMAGE_ROOT/qcom-multimedia-image" ]; then
    IMG_PATH="$TARGET_IMAGE_ROOT/qcom-multimedia-image"
else
    IMG_PATH="$TARGET_IMAGE_ROOT"
fi

echo "   -> Source: $IMG_PATH"

"$QDL_TOOL" --storage ufs \
    --include "$IMG_PATH" \
    "$IMG_PATH/prog_firehose_ddr.elf" \
    "$IMG_PATH"/rawprogram*.xml \
    "$IMG_PATH"/patch*.xml

# # ==== Flash CDT ====
# # CDT 在專案資料夾內 ($SCRIPT_DIR)
# echo "==== Flash CDT... ===="
# (
#     cd "$SCRIPT_DIR/image/cdt-iq9" || exit
#     "$QDL_TOOL" --storage ufs prog_firehose_ddr.elf rawprogram3.xml patch3.xml
# )
# # ==== Flash FW_TZ ====
# # FW 在專案資料夾內 ($SCRIPT_DIR)
# echo "==== Flash FW_TZ... ===="
# (
#     cd "$SCRIPT_DIR/fw-enable-TZ-qup-serial-CAN-spi-work" || exit
#     "$QDL_TOOL" --storage ufs "$SCRIPT_DIR/prog_firehose_ddr.elf" rawprogram4.xml patch4.xml
# )

echo "==== Flash Process Completed! ===="