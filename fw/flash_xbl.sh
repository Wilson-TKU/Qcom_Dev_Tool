#!/bin/bash

if [ -z "$1" ]; then
    echo "錯誤: 請提供要燒錄的 ELF 資料夾路徑！"
    echo "用法: $0 <elf_folder_path>"
    echo "範例: $0 comb_PM_SHUTDOWN_2s"
    exit 1
fi

ELF_DIR=$(realpath "$1")
TMP_FLASH="$(pwd)/tmp-flash-xbl"

if [ ! -d "$TMP_FLASH" ]; then
    echo "錯誤: 找不到 $TMP_FLASH 資料夾，請確認已將 tmp-flash-xbl 複製到當前目錄。"
    exit 1
fi

if [ ! -f "$ELF_DIR/xbl.elf" ] || [ ! -f "$ELF_DIR/xbl_config.elf" ]; then
    echo "錯誤: 找不到 $ELF_DIR/xbl.elf 或 xbl_config.elf"
    exit 1
fi

echo "================================================="
echo "準備燒錄..."
echo "從 $ELF_DIR 複製 ELF 檔案至 $TMP_FLASH"
cp "$ELF_DIR/xbl_config.elf" "$TMP_FLASH/xbl_config.elf"
cp "$ELF_DIR/xbl.elf" "$TMP_FLASH/xbl.elf"

echo "執行 QDL 燒錄..."
qdl --storage ufs --include "$TMP_FLASH/" "$TMP_FLASH/prog_firehose_ddr.elf" "$TMP_FLASH/flash-xbl.xml"

echo "燒錄結束！"
echo "================================================="
