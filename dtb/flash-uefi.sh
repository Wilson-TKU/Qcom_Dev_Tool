#!/bin/bash
uefi=${1:-"./uefi.elf"}

# cp $uefi/uefi.elf ./uefi.elf
qdl --storage ufs --include ./ ./prog_firehose_ddr.elf ./flash-uefi.xml

