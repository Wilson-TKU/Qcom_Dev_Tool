#!/bin/bash

# 獲取腳本目前的絕對路徑 (專案根目錄，用於找 qdl, provision, cdt, fw)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QDL_TOOL="$SCRIPT_DIR/qdl-2.3.1"


# ================= 路徑解析邏輯 =================
# 1. 設定 Image 的根目錄 (TARGET_IMAGE_ROOT)
if [ -n "$1" ]; then
    TARGET_IMAGE_ROOT="${1%/}"
else
    TARGET_IMAGE_ROOT="$SCRIPT_DIR/image/v1.1.0"
fi

if [ -n "${2:-}" ]; then
    QDL_SELECTOR="$2"
elif [ -z "${QDL_SELECTOR:-}" ]; then
    QDL_SELECTOR=""
fi
QDL_EXTRA=()
if [ -n "$QDL_SELECTOR" ]; then
    QDL_EXTRA=( -S "$QDL_SELECTOR" )
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
    "$QDL_TOOL" "${QDL_EXTRA[@]}" --storage spinor prog_firehose_ddr.elf rawprogram0.xml patch0.xml
)

# ==== Flash UFS-provision ====
# Provision 檔案仍在專案資料夾內 ($SCRIPT_DIR)，不受 Image 路徑影響
echo "==== Flash UFS-provision... ===="
"$QDL_TOOL" -d "${QDL_EXTRA[@]}" --storage ufs "$SCRIPT_DIR/image/ufs-provision-iq9/prog_firehose_ddr.elf" "$SCRIPT_DIR/image/ufs-provision-iq9/provision_1_2.xml"

# ==== Flash Main Image ====
echo "==== Flash Main image... ===="

# 自動判斷：有些版本 Image 檔案在 qcom-multimedia-image 子目錄，有些在根目錄
if [ -d "$TARGET_IMAGE_ROOT/qcom-multimedia-image" ]; then
    IMG_PATH="$TARGET_IMAGE_ROOT/qcom-multimedia-image"
else
    IMG_PATH="$TARGET_IMAGE_ROOT"
fi

echo "   -> Source: $IMG_PATH"

"$QDL_TOOL" "${QDL_EXTRA[@]}" --storage ufs \
    --include "$IMG_PATH" \
    "$IMG_PATH/prog_firehose_ddr.elf" \
    "$IMG_PATH"/rawprogram*.xml \
    "$IMG_PATH"/patch*.xml

echo "==== Flash Process Completed! ===="
