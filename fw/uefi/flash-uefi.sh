#!/bin/bash
# Get the absolute path of the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The 'prog' file is located one level above the script directory
PROG_FILE="${SCRIPT_DIR}/../prog_firehose_ddr.elf"
# The XML file is in the same directory as the script
XML_FILE="${SCRIPT_DIR}/flash-uefi.xml"

# Default uefi path if not provided as an argument
uefi=${1:-"${SCRIPT_DIR}/uefi.elf"}

echo "Using SCRIPT_DIR: $SCRIPT_DIR"
echo "Using PROG_FILE: $PROG_FILE"

# Execute qdl with absolute paths
qdl --storage ufs --include "${SCRIPT_DIR}" "${PROG_FILE}" "${XML_FILE}"

