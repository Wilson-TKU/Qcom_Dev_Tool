#!/bin/bash -e
# Copyright (c) 2025 innodisk Crop.
# 
# This software is released under the MIT License.
# https://opensource.org/licenses/MIT

DEFAULT_FILE="./dtb.bin"
FILENAME=${1:-$DEFAULT_FILE}

if [ "${FILENAME##*.}" = "vfat" ] || [ "${FILENAME##*.}" = "bin" ]; then
    echo "${FILENAME} is .vfat file."
else
    echo "${FILENAME} is not .vfat file."
    exit
fi

mkdir -p vfat

sleep 0.3

MOUNT_POINT=$(realpath vfat)

sudo mount -o loop -t vfat "${FILENAME}" "${MOUNT_POINT}"

cd "${MOUNT_POINT}"

sudo dtc -i dtb -o combined-dtb.dts combined-dtb.dtb

code combined-dtb.dts