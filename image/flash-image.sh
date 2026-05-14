#!/bin/bash

# 獲取腳本目前的絕對路徑 (專案根目錄，用於找 qdl, provision, cdt, fw)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QDL_TOOL="$SCRIPT_DIR/qdl-2.3.1"

# ================= Usage / Help =================
usage() {
    cat <<EOF
Usage:
  $(basename "$0") [stage ...] <path>
  $(basename "$0") -h | --help

  - stage 省略時等於 'all'
  - 可以一次帶多個 stage，會依序執行，例如: all cdt
  - path 必填，一律放最後面，通常是一大包完整 image 根目錄，例如:
      /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/

Stages:
  all     sail + ufs + image (預設批次)
  sail    Flash SAIL              從 <path>/sail_nor/
  ufs     Flash UFS provision     優先 <path>/ufs-provision-iq9/，否則用專案內 image/ufs-provision-iq9/
  image   Flash 主要 image        從 <path> (自動判斷 qcom-multimedia-image 子目錄)
  cdt     Flash CDT               優先 <path>/cdt-iq9/，否則用 <path> 內的檔案

Examples:
  $(basename "$0")          /media/.../260512-exma-q911-v2.1.0/    # 等同 all
  $(basename "$0") all      /media/.../260512-exma-q911-v2.1.0/
  $(basename "$0") sail     /media/.../260512-exma-q911-v2.1.0/
  $(basename "$0") ufs      /media/.../260512-exma-q911-v2.1.0/
  $(basename "$0") image    /media/.../260512-exma-q911-v2.1.0/
  $(basename "$0") cdt      /media/.../260512-exma-q911-v2.1.0/
  $(basename "$0") all cdt  /media/.../260512-exma-q911-v2.1.0/    # all + cdt 一次跑完
EOF
}

# ================= Stage 函式 =================
flash_sail() {
    echo "==== Flash SAIL... ===="
    (
        cd "$TARGET_IMAGE_ROOT/sail_nor" || exit 1
        "$QDL_TOOL" --storage spinor prog_firehose_ddr.elf rawprogram0.xml patch0.xml
    )
}

flash_ufs_provision() {
    echo "==== Flash UFS-provision... ===="

    # 優先用 <path>/ufs-provision-iq9/，找不到再用專案內預設
    if [ -d "$TARGET_IMAGE_ROOT/ufs-provision-iq9" ]; then
        UFS_PATH="$TARGET_IMAGE_ROOT/ufs-provision-iq9"
    else
        UFS_PATH="$SCRIPT_DIR/image/ufs-provision-iq9"
    fi
    echo "   -> Source: $UFS_PATH"

    "$QDL_TOOL" --storage ufs \
        "$UFS_PATH/prog_firehose_ddr.elf" \
        "$UFS_PATH/provision_1_2.xml"
}

flash_image() {
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
}

flash_cdt() {
    echo "==== Flash CDT... ===="

    # 優先 <path>/cdt-iq9/，否則用 <path> 本身
    if [ -d "$TARGET_IMAGE_ROOT/cdt-iq9" ]; then
        CDT_PATH="$TARGET_IMAGE_ROOT/cdt-iq9"
    else
        CDT_PATH="$TARGET_IMAGE_ROOT"
    fi
    echo "   -> Source: $CDT_PATH"

    (
        cd "$CDT_PATH" || exit 1
        "$QDL_TOOL" --storage ufs prog_firehose_ddr.elf rawprogram3.xml patch3.xml
    )
}

# 判斷字串是否為合法 stage 名稱
is_stage() {
    case "$1" in
        all|sail|ufs|image|cdt) return 0 ;;
        *) return 1 ;;
    esac
}

# 把一個 stage 名稱展開成實際要跑的 step 序列 (印到 stdout，每行一個)
expand_stage() {
    case "$1" in
        all)  printf '%s\n' sail ufs image ;;
        *)    printf '%s\n' "$1" ;;
    esac
}

# ================= 參數解析 =================
# 至少要有一個參數 (path)；help 例外
if [ $# -eq 0 ]; then
    echo "Error: <path> is required"
    echo ""
    usage
    exit 1
fi

if [ $# -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

# 最後一個參數一定是 path，其它都是 stage
IMAGE_ARG="${!#}"
STAGE_ARGS=( "${@:1:$#-1}" )

# 沒指定 stage → 預設 all
if [ "${#STAGE_ARGS[@]}" -eq 0 ]; then
    STAGE_ARGS=( all )
fi

# 驗證 stage 名稱，並組出真正要跑的 step 序列 (依輸入順序，重複的 step 只跑一次)
STEPS=()
for s in "${STAGE_ARGS[@]}"; do
    if ! is_stage "$s"; then
        echo "Error: Unknown stage '$s'"
        echo ""
        usage
        exit 1
    fi
    while IFS= read -r step; do
        # 跳過已加入過的 step，避免 'all cdt sail' 把 sail 跑兩次
        already=0
        for existing in "${STEPS[@]}"; do
            [ "$existing" = "$step" ] && { already=1; break; }
        done
        [ $already -eq 0 ] && STEPS+=( "$step" )
    done < <(expand_stage "$s")
done

# ================= 路徑解析 =================
# ${IMAGE_ARG%/} 去掉路徑最後面的斜線，避免路徑拼接出現 //
TARGET_IMAGE_ROOT="${IMAGE_ARG%/}"

echo "------------------------------------------"
echo "Script Location : $SCRIPT_DIR"
echo "Target Image Dir: $TARGET_IMAGE_ROOT"
echo "Stages          : ${STAGE_ARGS[*]}"
echo "Steps to run    : ${STEPS[*]}"
echo "------------------------------------------"

if [ ! -d "$TARGET_IMAGE_ROOT" ]; then
    echo "Error: Directory $TARGET_IMAGE_ROOT does not exist!"
    exit 1
fi

# ================= 執行 =================
for step in "${STEPS[@]}"; do
    case "$step" in
        sail)  flash_sail ;;
        ufs)   flash_ufs_provision ;;
        image) flash_image ;;
        cdt)   flash_cdt ;;
    esac
done

echo "==== Flash Process Completed! ===="