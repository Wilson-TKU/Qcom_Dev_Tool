# host-env — Ubuntu 開發主機環境設定

在一台**全新的 Ubuntu(建議 22.04)** 上，快速準備好：

- **燒錄高通平台**(EDL / QDL,`qdl` 工具)
- **adb 連線**到高通平台
- (選用)Yocto/BSP build 的相依套件與 `repo` 工具

目標平台:SA8775P (LeMans) / QLI · qimpsdk。

---

## TL;DR

```bash
cd dev/host-env

# 一鍵全裝 (apt 套件 + adb/fastboot + 編譯 qdl + udev rules + plugdev)
./setup-host-env.sh

# 重新登入 (讓 plugdev 群組生效)，然後接上板子檢查狀態
./check-device.sh
```

---

## setup-host-env.sh

分階段(stage)安裝,省略參數 = `all`。

| Stage | 做什麼 |
|-------|--------|
| `apt` | 安裝 Build Guide 列的 build 相依套件 + `adb` + `fastboot` + 編譯 qdl 所需 (`libusb-1.0-0-dev` `libxml2-dev`) |
| `repo` | 安裝 Google `repo` 工具(抓 BSP manifest 用) |
| `qdl` | 從原始碼([linux-msm/qdl](https://github.com/linux-msm/qdl))編譯並安裝到 `/usr/local/bin/qdl`,支援 `--storage` / `--include`,與本 repo 的 flash 腳本相容 |
| `udev` | 寫入 `/etc/udev/rules.d/51-qcom-usb.rules`(EDL `05c6:9008` + Qualcomm adb),並把使用者加入 `plugdev` |
| `gitcfg` | (選用)git global 設定(name/email/http buffer)+ locale `en_US.UTF-8` |
| `verify` | 檢查 adb / fastboot / qdl / repo / plugdev / lsusb 狀態 |

```bash
./setup-host-env.sh                # = apt repo qdl udev verify
./setup-host-env.sh qdl            # 只重編 qdl
./setup-host-env.sh udev verify    # 重灌 udev rules 後驗證
./setup-host-env.sh all gitcfg     # 全部 + git/locale
./setup-host-env.sh -h             # 說明
```

> **plugdev 群組**:第一次跑完 `udev` stage 後,**必須重新登入(或重開機)** 才能免 `sudo` 使用 qdl/adb。

> **關於 qdl 版本**:本 repo 的 [image/flash-image.sh](../../image/flash-image.sh) 預設呼叫同目錄下的 `qdl-2.3.1`(Qualcomm SDK 內附版)。本腳本裝的是開源 `qdl` 到 `/usr/local/bin`。兩者指令介面相容;若你想統一用系統版,把腳本裡的 `QDL_TOOL` 改成 `qdl` 即可。

---

## check-device.sh

接上板子後,判斷它目前在哪種模式,決定下一步:

```bash
./check-device.sh
```

- 看到 `05c6:9008` → **EDL 模式**,可以 `qdl` 燒錄
- `adb devices` 有裝置 → 可以 `adb shell`
- `fastboot devices` 有裝置 → 在 bootloader

---

## 完整流程

### 1. 主機準備(一次)
```bash
./setup-host-env.sh
# 重新登入
```

### 2. 板子進 EDL 燒錄模式(擇一)
```bash
adb shell reboot edl          # 板子在 adb 可用時 (最常用)
# 或 UART shell 裡: reboot edl
# 或手動: 按住 F_DL → 接 +12V Type-C → 放開
```
進入後 `lsusb` 應出現 `05c6:9008`。

### 3. 燒錄(用本 repo 既有腳本)
```bash
cd ../../image
./flash-image.sh all <image 根目錄>     # sail + ufs + image
./flash-image.sh cdt <image 根目錄>     # 視需要單獨燒 CDT
```

### 4. adb 連線
```bash
adb devices
adb shell
adb shell reboot              # 注意:用 reboot,不要用 adb reboot
```

---

## 參考文件 (Qualcomm Linux Build Guide)

- [Build environment setup (80-70029-254)](https://docs.qualcomm.com/doc/80-70029-254/topic/github_workflow_unregistered_users.html?product=895724676033554725&facet=Build%20Guide&version=1.8)
- [Flash images (80-70029-254)](https://docs.qualcomm.com/doc/80-70029-254/topic/flash_images.html?product=895724676033554725&facet=Build%20Guide&version=1.8)
- [USB / adb setup (80-70029-8SC)](https://docs.qualcomm.com/doc/80-70029-8SC/topic/usb.html)
