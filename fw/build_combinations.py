#!/usr/bin/env python3
import os
import re
import shutil
import subprocess

base_dir = "/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk"
boot_image_dir = os.path.join(base_dir, "BOOT.MXF.1.0.c1")

dtsi_path = os.path.join(boot_image_dir, "boot_images", "boot", "Settings", "Soc", "LeMans", "Core", "PMIC", "pm.dtsi")
c_path = os.path.join(boot_image_dir, "boot_images", "boot", "QcomPkg", "Library", "PmicLib", "target", "lemans", "system", "src", "pm_sbl_boot_oem.c")

out_dir = "/media/wilson/nvme_Wilson_Data1/fw_00117/power_button_experiments"
os.makedirs(out_dir, exist_ok=True)

# Backup originals
shutil.copy2(dtsi_path, os.path.join(out_dir, "pm.dtsi.orig"))
shutil.copy2(c_path, os.path.join(out_dir, "pm_sbl_boot_oem.c.orig"))

env = os.environ.copy()
env["SECTOOLS"] = "/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux/sectools"
env["SECTOOLS_DIR"] = "/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/QCS9100.LE.1.0/common/sectoolsv2/ext/Linux"
env["HEXAGON_ROOT"] = os.path.expanduser("~/Qualcomm/HEXAGON_Tools")
env["DTC"] = "/usr/bin"
env["LLVM"] = "/media/wilson/nvme_Wilson_Data1/fw_env/llvm/14.0.4/"

combinations = [
    ("PM_SHUTDOWN", "PM_SHUTDOWN", "PM_APP_PON_CFG_NORMAL_SHUTDOWN"),
    ("PM_WARM_RESET", "PM_WARM_RESET", "PM_APP_PON_CFG_WARM_RESET"),
    ("PM_HARD_RESET", "PM_HARD_RESET", "PM_APP_PON_CFG_HARD_RESET")
]

with open(dtsi_path, "r") as f:
    dtsi_orig = f.read()

with open(c_path, "r") as f:
    c_orig = f.read()

for comb_name, dtsi_macro, c_macro in combinations:
    print(f"--- Running combination {comb_name} ---")
    
    # Modify dtsi
    dtsi_mod = re.sub(
        r'(s2-kpdpwr.*?reset-type = /bits/ 8 <)[^>]+(>;)',
        rf'\g<1>{dtsi_macro}\g<2>',
        dtsi_orig, flags=re.DOTALL
    )
    dtsi_mod = re.sub(
        r'(s2-kpdpwr.*?s1-ms = <)\d+(>;)',
        rf'\g<1>904\g<2>',
        dtsi_mod, flags=re.DOTALL
    )
    dtsi_mod = re.sub(
        r'(s2-kpdpwr.*?s2-ms = <)\d+(>;)',
        rf'\g<1>1000\g<2>',
        dtsi_mod, flags=re.DOTALL
    )

    # s2-kpdpwr-resin
    dtsi_mod = re.sub(
        r'(s2-kpdpwr-resin.*?reset-type = /bits/ 8 <)[^>]+(>;)',
        rf'\g<1>{dtsi_macro}\g<2>',
        dtsi_mod, flags=re.DOTALL
    )
    dtsi_mod = re.sub(
        r'(s2-kpdpwr-resin.*?s1-ms = <)\d+(>;)',
        rf'\g<1>904\g<2>',
        dtsi_mod, flags=re.DOTALL
    )
    dtsi_mod = re.sub(
        r'(s2-kpdpwr-resin.*?s2-ms = <)\d+(>;)',
        rf'\g<1>1000\g<2>',
        dtsi_mod, flags=re.DOTALL
    )

    with open(dtsi_path, "w") as f:
        f.write(dtsi_mod)

    # Modify c_file
    # Search for pm_app_pon_reset_cfg(PM_APP_PON_RESET_SOURCE_KPDPWR, ... , pon_dt->s2_kpdpwr_s1_ms, pon_dt->s2_kpdpwr_s2_ms);
    c_mod = re.sub(
        r'(pm_app_pon_reset_cfg\s*\(\s*PM_APP_PON_RESET_SOURCE_KPDPWR\s*,\s*)[A-Z_]+(\s*,\s*pon_dt->s2_kpdpwr_s1_ms)',
        rf'\g<1>{c_macro}\g<2>',
        c_orig
    )
    c_mod = re.sub(
        r'(pm_app_pon_reset_cfg\s*\(\s*PM_APP_PON_RESET_SOURCE_RESIN_AND_KPDPWR\s*,\s*)[A-Z_]+(\s*,\s*pon_dt->s2_kpdpwr_resin_s1_ms)',
        rf'\g<1>{c_macro}\g<2>',
        c_mod
    )

    with open(c_path, "w") as f:
        f.write(c_mod)

    # Clean build
    print("Cleaning...")
    subprocess.run(["python", "-u", "boot_images/boot_tools/buildex.py", "-t", "lemans,QcomToolsPkg", "-v", "LAA", "-r", "RELEASE", "--build_flags=cleanall"], cwd=boot_image_dir, env=env)
    
    # Build
    print("Building...")
    subprocess.run(["python", "-u", "boot_images/boot_tools/buildex.py", "-t", "lemans,QcomToolsPkg", "-v", "LAA", "-r", "RELEASE"], cwd=boot_image_dir, env=env)

    # Copy files out
    comb_dir = os.path.join(out_dir, f"comb_{comb_name}_2s")
    os.makedirs(comb_dir, exist_ok=True)
    
    xbl_elf = os.path.join(boot_image_dir, "boot_images", "boot", "QcomPkg", "SocPkg", "LeMans", "Bin", "LAA", "RELEASE", "xbl.elf")
    if os.path.exists(xbl_elf):
        shutil.copy2(xbl_elf, os.path.join(comb_dir, "xbl.elf"))
    else:
        print(f"Error: {xbl_elf} not found!")

    xbl_config_elf = os.path.join(boot_image_dir, "boot_images", "boot", "QcomPkg", "SocPkg", "LeMans", "Bin", "LAA", "RELEASE", "xbl_config.elf")
    if os.path.exists(xbl_config_elf):
        shutil.copy2(xbl_config_elf, os.path.join(comb_dir, "xbl_config.elf"))
    
    shutil.copy2(dtsi_path, os.path.join(comb_dir, "pm.dtsi"))
    shutil.copy2(c_path, os.path.join(comb_dir, "pm_sbl_boot_oem.c"))

# Restore original files
with open(dtsi_path, "w") as f:
    f.write(dtsi_orig)

with open(c_path, "w") as f:
    f.write(c_orig)

print("Done with all 3 build combinations!")
