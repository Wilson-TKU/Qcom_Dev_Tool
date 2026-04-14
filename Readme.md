## Build BOOT (xbl.elf & xbl_config.elf)
- modify
/media/wilson/nvme_Wilson_Data1/fw_00120/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1/boot_images/boot/Settings/Soc/LeMans/Core/PMIC/pm.dtsi
/media/wilson/nvme_Wilson_Data1/fw_00120/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1/boot_images/boot/QcomPkg/Library/PmicLib/target/lemans/system/src/pm_sbl_boot_oem.c
- build
```bash
./manual_build.sh <naming-your-folder>
```
## Flash xbl & xbl_config
```bash
./flash_xbl.sh <your-folder-with-xbl-xbl_config>
```