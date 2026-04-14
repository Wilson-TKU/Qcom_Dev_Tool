#!/bin/bash
# Copyright (c) 2025 innodisk Crop.
# 
# This software is released under the MIT License.
# https://opensource.org/licenses/MIT

MOUNT_POINT=$(realpath vfat)

cd vfat

sudo dtc -i dts -o combined-dtb.dtb combined-dtb.dts

cd ..

sudo umount ${MOUNT_POINT}
