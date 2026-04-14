#!/bin/bash

# Check if DTB file path is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <path_to_dtb_file>"
  exit 1
fi

DTB_FILE=$1
TMP_DIR="tmp_dtb"

# Check if the source DTB file exists
if [ ! -f "$DTB_FILE" ]; then
    echo "Error: DTB file not found at $DTB_FILE"
    exit 1
fi

# Re-create the temporary directory for a clean flash
echo "Preparing temporary directory..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Copy necessary files
echo "Copying files to $TMP_DIR..."
cp "$DTB_FILE" "$TMP_DIR/dtb.bin"
cp prog_firehose_ddr.elf "$TMP_DIR/"
cp rawprogram4.xml "$TMP_DIR/"

echo "Changing to $TMP_DIR and flashing..."
# Use a subshell to 'cd' into the directory.
(cd "$TMP_DIR" && qdl --storage ufs --include . prog_firehose_ddr.elf rawprogram*.xml)

echo "Flash process completed."
