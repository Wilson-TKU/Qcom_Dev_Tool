# 專案技能文件 (Skill context for AI)

## 專案名稱
fw_00117 - Power Button & Reset Experiments

## 專案目標
修改高通 SBL bootloader (`xbl.elf`, `xbl_config.elf`)，以改變電源鍵 (`kpdpwr`) 以及重置組合鍵 (`resin + kpdpwr`) 長按時的硬體觸發行為 (例如 `PM_SHUTDOWN`, `PM_WARM_RESET`, `PM_HARD_RESET`)。

## 關鍵修改檔案
如果要修改按鍵行為，需要同時修改以下兩個檔案：

1. **`pm_sbl_boot_oem.c`** (控制按鍵觸發的 Reset Type 行為)
   - 路徑: `/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1/boot_images/boot/QcomPkg/Library/PmicLib/target/lemans/system/src/pm_sbl_boot_oem.c`
   - 需要修改其中的 `pm_app_pon_reset_cfg`，替換原本的 `PM_APP_PON_CFG_HARD_RESET` 或 `PM_APP_PON_CFG_WARM_RESET` 等字串。

2. **`pm.dtsi`** (控制按鍵長按的計時時間 `s1-ms` 和 `s2-ms`)
   - 路徑: `/media/wilson/nvme_Wilson_Data1/fw_00117/qualcomm-linux-spf-1-0_ap_standard_oem_nm-qimpsdk/BOOT.MXF.1.0.c1/boot_images/boot/Settings/Soc/LeMans/Core/PMIC/pm.dtsi`

## 編譯與提取方法
我們建立了一個自動化腳本：`manual_build.sh`。當你手動修改完 `.c` 與 `.dtsi` 檔案後，可以直接透過此腳本進行編譯，腳本會自動提取相關檔案以供測試。

- **使用方法**:
  ```bash
  cd /media/wilson/nvme_Wilson_Data1/fw_00117/power_button_experiments
  ./manual_build.sh <你的測試名稱>
  ```
- **執行結果**: 
  會自動幫你呼叫編譯，並將你修改的 `.c`, `.dtsi` 以及產出的 `xbl.elf`, `xbl_config.elf` 集中拉到 `/media/wilson/nvme_Wilson_Data1/fw_00117/power_button_experiments/<你的測試名稱>` 資料夾中。

## 燒錄測試
集中拉出的檔案目錄可配合此資料夾下的 `flash_xbl.sh` 進行直接燒錄：
```bash
./flash_xbl.sh <你的測試名稱>
```

## AI 幫助提示
當使用者要求「修改某種按鍵重置行為並編譯」時，AI 可以：
1. 先修改 `pm_sbl_boot_oem.c` 以及 `pm.dtsi` 原始碼。
2. 呼叫 `manual_build.sh <自訂名稱>` 來一鍵編譯及匯出檔案。
3. 提示使用者使用 `flash_xbl.sh` 進行燒錄。