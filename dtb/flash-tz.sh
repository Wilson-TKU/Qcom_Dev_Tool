#!/bin/bash

# Check if MBN file path is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <path_to_mbn_file>"
  exit 1
fi

MBN_FILE=$1
TMP_DIR="tmp_tz"

# Check if the source MBN file exists
if [ ! -f "$MBN_FILE" ]; then
    echo "Error: MBN file not found at $MBN_FILE"
    exit 1
fi

# Re-create the temporary directory for a clean flash
echo "Preparing temporary directory..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Copy necessary files
echo "Copying files to $TMP_DIR..."
cp "$MBN_FILE" "$TMP_DIR/devcfg.mbn"
cp prog_firehose_ddr.elf "$TMP_DIR/"
cp rawprogram4.xml "$TMP_DIR/"

echo "Changing to $TMP_DIR and flashing..."
# Use a subshell to 'cd' into the directory.
(cd "$TMP_DIR" && qdl --storage ufs --include . prog_firehose_ddr.elf rawprogram*.xml)

echo "Flash process completed."
