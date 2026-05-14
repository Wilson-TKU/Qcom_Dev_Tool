#!/bin/bash

# 取得 script 自己的絕對路徑，這樣從任何目錄呼叫都能找到同目錄下的資源檔
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if DTB file path is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <path_to_dtb_file>"
  exit 1
fi

# 使用者給的 DTB 路徑相對於 CWD 解析，轉成絕對路徑後續才不會因 cd 失效
case "$1" in
    /*) DTB_FILE="$1" ;;
    *)  DTB_FILE="$PWD/$1" ;;
esac

# Check if the source DTB file exists
if [ ! -f "$DTB_FILE" ]; then
    echo "Error: DTB file not found at $DTB_FILE"
    exit 1
fi

TMP_DIR="$SCRIPT_DIR/tmp_dtb"
PROG_ELF="$SCRIPT_DIR/prog_firehose_ddr.elf"
RAWPROGRAM_XML="$SCRIPT_DIR/rawprogram4.xml"

# Re-create the temporary directory for a clean flash
echo "Preparing temporary directory..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Copy necessary files
echo "Copying files to $TMP_DIR..."
cp "$DTB_FILE" "$TMP_DIR/dtb.bin"
cp "$PROG_ELF" "$TMP_DIR/"
cp "$RAWPROGRAM_XML" "$TMP_DIR/"

echo "Changing to $TMP_DIR and flashing..."
# Use a subshell to 'cd' into the directory.
(cd "$TMP_DIR" && qdl --storage ufs --include . prog_firehose_ddr.elf rawprogram*.xml)

echo "Flash process completed."
