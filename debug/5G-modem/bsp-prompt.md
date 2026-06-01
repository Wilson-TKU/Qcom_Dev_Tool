# BSP Prompt — 給另一個 Claude session 用

用法：在你的 QLI BSP / Yocto layer repo 開一個 Claude session，把下面整段 **`---PROMPT START---` 到 `---PROMPT END---` 之間** 的內容貼給它。

---PROMPT START---

我需要你修改這個 Yocto BSP layer 來把 **cellular modem 升級到 ModemManager/NetworkManager 自動化體驗**。

## 背景

目標 image：Qualcomm Linux (QLI) 1.8-ver.1.1，跑在 SA8775P (LeMans) 平台。
搭配的 modem：Quectel EM060K-GL (USB VID:PID `2c7c:030b`，MBIM composition)。

**前提**：modem **已經能撥通了**（透過 `mbim-network` wrapper 手動撥，已驗證取得真實 IP + ping + DNS 都通）。這次任務是**把這個自動化**，讓 MM/NM 能直接接管。

實機檢查（已在 target 上 ldd / opkg / nmcli 確認）發現現 image 缺以下件，所以目前必須手動撥不能 MM 自動撥：

| 缺件 | 證據 | 補完的價值 |
|---|---|---|
| ModemManager **沒含 MBIM/QMI 支援** | `ldd /usr/sbin/ModemManager \| grep -iE 'mbim\|qmi'` → 空；表示 PACKAGECONFIG 沒帶 `mbim qmi` | MM 可以自動跑 MBIM/QMI 連線，不用 script 手動 mbim-network |
| **`ppp` 套件沒裝** | `which pppd` not found；`opkg list \| grep '^ppp'` 空 | 支援老式 3G dongle / PPP-only modem |
| **`networkmanager-plugin-wwan` 沒裝** | `nmcli general status` 顯示 `WWAN-HW: missing` | nmcli con add type gsm + auto-reconnect / SIM 熱插拔 |
| ~~udev port-types rule for PID 030B~~ | **不做**：image 給多客戶共用，不應為單一 vendor PID 寫死規則 | （優化用，屬 upstream MM） |

## 任務

請在這個 BSP layer 加 / 改 bbappend 來：

### 1. ModemManager 開啟 MBIM + QMI 支援

寫一個 `recipes-connectivity/modemmanager/modemmanager_%.bbappend`（或對應版本號 `_1.22.0.bbappend`），加上：

```bitbake
PACKAGECONFIG:append = " mbim qmi"
```

驗證方式：build 完拉出來 `ldd ${D}/usr/sbin/ModemManager`，應該要看到 `libmbim-glib.so` 跟 `libqmi-glib.so`。

### 2. 把 ppp 跟 networkmanager-plugin-wwan 加進 image

找到主 image recipe（通常是 `recipes-core/images/qcom-*-image*.bb` 或類似），加：

```bitbake
IMAGE_INSTALL:append = " ppp networkmanager-plugin-wwan"
```

如果不確定主 image recipe 在哪，幫我先 `grep -rl "IMAGE_INSTALL" recipes-core/images/` 找候選。

注意：
- `ppp` 套件是 OE-core 標準 recipe，feed 裡應該已經有，只是沒被 install 到 image
- `networkmanager-plugin-wwan` 是 `networkmanager` recipe 的 PACKAGECONFIG 子套件；可能需要在 `networkmanager.bbappend` 加 `PACKAGECONFIG:append = " modemmanager"` 來讓它編出 wwan plugin

### 3. ~~udev rule~~ — **不做**

> 已評估後決定 **不加 vendor-specific udev rule** 到 BSP：
> - 此 image 給多個客戶共用，為單一 Quectel PID 寫死規則是反模式
> - 已實測：沒加 rule 時 MM 也能 generic-detect AT port (`ttyUSB2 (at), ttyUSB3 (at)`)
> - `wwan0 (ignored)` 不是 udev rule 問題，是 MM 沒 link libmbim 造成；做完 §1 (PACKAGECONFIG mbim qmi) 自然會解
> - 真的需要時，正確路徑是 bump MM 版本到 upstream 已涵蓋的，或送 PR 到 [freedesktop/ModemManager](https://gitlab.freedesktop.org/mobile-broadband/ModemManager) 上游
>
> 先用 §1 + §2 兩個變更跑通，後續觀察 MM 行為再說。

## 請你做的事

1. **先掃 layer 結構**：找出
   - 主 image recipe 在哪 (`grep -rl IMAGE_INSTALL recipes-core/images/`)
   - 是否已有 `modemmanager` 或 `networkmanager` 的 bbappend (`find . -name '*modemmanager*.bbappend' -o -name '*networkmanager*.bbappend'`)
   - 這個 layer 用什麼套件管理約定（OE-core / meta-qcom / meta-openembedded）
2. **產生 patch / 新檔案**列表，並顯示完整內容讓我 review 後再寫進 disk
3. **不要** 直接 build；先讓我看 diff 並決定要不要套用
4. **驗證指令**：建議我 build 完之後在 target 上跑哪些指令確認修好（例如 `ldd /usr/sbin/ModemManager`、`opkg list-installed | grep ppp`、`nmcli general status` 看 WWAN-HW 不再 missing）

## 注意事項

- 我使用的 layer 不一定是 meta-qcom 原樣，可能是 ODM/OEM 客製版。先掃結構再下手。
- 如果發現 modemmanager / networkmanager recipe 在這個 layer 沒被 override，需要找上層 BSP（可能在 `../meta-qcom/` 或 SDK 路徑）來確認版本後再決定 bbappend 對哪個版本號。
- 我會自己跑 bitbake build，不需要你幫我跑。

---PROMPT END---
