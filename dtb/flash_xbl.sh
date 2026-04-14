#!/bin/bash
xbl_config=${1:-"/media/wilson/nvme_Wilson_Data1/fw_00114/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1/boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/"}
xbl=${1:-"/media/wilson/nvme_Wilson_Data1/fw_00114/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1/boot_images/boot/QcomPkg/SocPkg/LeMans/Bin/LAA/RELEASE/"}
tmp_flash=/nvme_Wilson_Data/QCS9100-dev/dtb-bin_hacker/tmp-flash-xbl

cp $xbl_config/xbl_config.elf $tmp_flash/xbl_config.elf
cp $xbl/xbl.elf $tmp_flash/xbl.elf
qdl --storage ufs --include $tmp_flash/ $tmp_flash/prog_firehose_ddr.elf $tmp_flash/flash-xbl.xml

