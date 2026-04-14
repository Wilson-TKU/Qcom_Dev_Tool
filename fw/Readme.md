# 電源與重置按鍵硬體行為測試 (Power Button & Reset Experiments)

本目錄包含用來修改高通 SBL bootloader (`xbl.elf`, `xbl_config.elf`) 的實驗性腳本，目的在於客製化「電源鍵 (`kpdpwr`)」以及「音量下+電源鍵 (`resin + kpdpwr`)」長按時的硬體行為。

## 背景與程式碼邏輯

在預設設定中，如果我們想測試不同的重置行為（例如強制關機 vs 強制重啟），單純只修改 Device Tree 源碼 (`pm.dtsi`) 通常不會產生預期的效果。

這是因為在 C 原始碼 `pm_sbl_boot_oem.c` 裡面，**強制寫死** 了覆寫 `.dtsi` 設定的重置類型 (Reset Types)，這影響了 `KPDPWR` 以及 `RESIN_AND_KPDPWR` 兩個按鍵行為。

舉例來說，`pm_sbl_boot_oem.c` 在開機初期會動態將 `RESIN_AND_KPDPWR` 強制設成 `PM_APP_PON_CFG_HARD_RESET`：
```c
err_flag |= pm_app_pon_reset_cfg(PM_APP_PON_RESET_SOURCE_RESIN_AND_KPDPWR,
                            PM_APP_PON_CFG_HARD_RESET, pon_dt->s2_kpdpwr_resin_s1_ms, pon_dt->s2_kpdpwr_resin_s2_ms);
```
*(注意：這裡的計時器時間變數 `pon_dt->...` 仍然是從 `dtsi` 讀取的，但是重置類型 `PM_APP_PON_CFG_HARD_RESET` 被寫死了)*

此外，原始 C 程式碼並沒有在 `pm_device_post_init()` 裡專門處理單顆 `s2-resin` 按鍵的邏輯。因此我們的實驗主要是透過修改 `s2-kpdpwr-resin` (重置加電源) 以及標準的 `s2-kpdpwr` (獨立電源) 兩種來源的設定來達成目標。

所以，為了能正確測試功能，**我們需要同時修改這兩個檔案**：
1. **`pm.dtsi`**：把 `s1-ms` 和 `s2-ms` 設定到期望的行為 (本次實驗設定為 `s1-ms = <904>`, `s2-ms = <1000>`)。
2. **`pm_sbl_boot_oem.c`**：修改原始碼，將預設的 `PM_APP_PON_CFG_HARD_RESET` 等字串取代成為了完成這次測試我們想要的行為類型。

## LLVM Clang 14 編譯 LSE Atomics 問題解決方法

在使用較新版本的 Clang (AARCH64) 編譯器時 (此專案使用 v14.0.4)，針對 ARM 架構它預設會啟動 LSE (Large System Extension) 功能，導致編譯出來的目的檔依賴於 `__aarch64_ldadd4_relax` 等系統原子操作函數庫。但由於 bootloader 屬於裸機 (Bare-metal) 執行環境，缺乏相對應庫支援，在 Linker 連結 ELF 檔的時候會引發 Error: `undefined reference to '__aarch64_ldadd4_relax'`。

**修正方案：**
在以下 5 個 EDK2 編譯設定檔中加入並強制套用 `-mno-outline-atomics` 選項，以關閉 LSE 指令擴展解決編譯報錯：

1. `boot_images/boot/CryptoPkg/CryptoPkg.dsc`
   在 `[BuildOptions]` 區域加入 `-mno-outline-atomics`。
2. `boot_images/boot/QcomPkg/SocPkg/Kodiak/Common/Core.dsc.inc`
   在 `GCC:*_*_AARCH64_ARCHCC_FLAGS` 起首加上 `-mno-outline-atomics`。
3. `boot_images/boot/QcomPkg/SocPkg/LeMans/Common/Core.dsc.inc`
   同上。
4. `boot_images/boot/QcomPkg/SocPkg/Monaco/Common/Core.dsc.inc`
   同上。
5. `boot_images/boot/QcomPkg/XBLCore/XBLCore.inf`
   在 `GCC:*_*_*_CC_FLAGS` 結尾加入 `-mno-outline-atomics`。

## 編譯流程

我們使用 `build_combinations.py` 這個 Python 自動化腳本執行所有操作：它會備份並利用正規表達式自動替換 `.dtsi` 和 `.c` 裡的所有設定，呼叫 EDK2 的 `buildex.py` 腳本執行 Clean Build 後，再把它們的產出分別收拢到各自的資料夾當中。

編譯前確保已宣告這些環境變數：
- `SECTOOLS`
- `SECTOOLS_DIR`
- `HEXAGON_ROOT`
- `DTC`
- `LLVM`

只需要在終端機執行腳本即可一次性編譯所有測試需要的組合：
```bash
python3 build_combinations.py
```

註：腳本背後跑的編譯指令等同於執行 
```bash
python -u boot_images/boot_tools/buildex.py -t lemans,QcomToolsPkg -v LAA -r RELEASE --build_flags=cleanall
python -u boot_images/boot_tools/buildex.py -t lemans,QcomToolsPkg -v LAA -r RELEASE
```

## 燒錄流程

已經編譯好的各個情境會獨立收攏在此目錄下各自的資料夾 (例如 `comb_PM_SHUTDOWN_2s`)。
我們提供了一鍵燒錄腳本 `flash_xbl.sh` 來進行測試：

1. 確保當下目錄已準備好依賴組件資料夾 `tmp-flash-xbl`
2. 執行腳本並將包含 ELF 的目錄當成參數傳遞給它：
   ```bash
   ./flash_xbl.sh comb_PM_SHUTDOWN_2s
   ```
這會自動複製 `xbl.elf` 以及 `xbl_config.elf` 到快取目錄，並透過 `qdl` 將映像檔刷入開發板。

## 實驗組合與硬體驗證結果

在此留下欄位提供您於實機燒錄 `xbl_config.elf` 以及 `xbl.elf` 後填寫。

| 目錄 (Combination Folder) | 替換的類型 (Reset Type) | 長按2秒後的行為觀察 | 附註 |
|:---|:---|:---|:---|
| **comb_PM_SHUTDOWN_2s** | Shutdown (`PM_SHUTDOWN`) | [待填寫] | |
| **comb_PM_WARM_RESET_2s** | Warm Reset (`PM_WARM_RESET`) | [待填寫] | |
| **comb_PM_HARD_RESET_2s** | Hard Reset (`PM_HARD_RESET`) | [待填寫] | |

---
**附註:** 每一個產出的目錄底下都會存放該組合被修改過的 `pm_sbl_boot_oem.c` 以及 `pm.dtsi` 檔案，方便您日後能用 Diff 工具比對細節。未曾修改的原始碼會以 `.orig` 結尾的副檔名存放在主層目錄中。
