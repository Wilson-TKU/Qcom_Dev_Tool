# Flash Image Tools

提供兩個 flash 腳本：
- `flash-image.sh`：單台機器 flash，支援分段燒錄 (sail / ufs / cdt / main-image / all)
- `flash-image-multi.sh`：多台機器並行 flash，透過 USB serial 來鎖定目標裝置

---

## flash-image.sh

### 基本格式

```bash
./flash-image.sh [stage ...] <path>
```

- `stage` 省略時等同 `all`
- 可以一次帶**多個 stage**，會依輸入順序執行；重複的會自動去重
- `path` **必填**，一律放在**最後面**，通常是一大包完整 image 根目錄，例如：
  `/media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/`

### Stages

| Stage   | 動作 | 來源資料夾 |
| ------- | ---- | ---------- |
| `all`   | sail + ufs + image 一次跑完 (預設) | `<path>` |
| `sail`  | Flash SAIL (SPI NOR)               | `<path>/sail_nor/` |
| `ufs`   | Flash UFS provision                | `<path>/ufs-provision-iq9/`，找不到則退回專案內 `image/ufs-provision-iq9/` |
| `image` | Flash 主要 image                   | `<path>` (若有 `qcom-multimedia-image` 子目錄則自動切過去) |
| `cdt`   | Flash CDT                          | `<path>/cdt-iq9/`，找不到則用 `<path>` |

> `cdt` 不會被 `all` 帶到。要連 cdt 一起跑就用 `./flash-image.sh all cdt <path>`。

### 範例

```bash
# 只給路徑 → 自動視為 all
./flash-image.sh /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/

# 單一 stage + 路徑
./flash-image.sh all   /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/
./flash-image.sh sail  /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/
./flash-image.sh ufs   /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/
./flash-image.sh image /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/
./flash-image.sh cdt   /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/

# 多個 stage 一行帶完 (生產時最常用)
./flash-image.sh all cdt /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/
./flash-image.sh sail cdt /media/wilson/nvme_Wilson_Data1/B2B-6.6.97/260512-exma-q911-v2.1.0/

# 查看說明
./flash-image.sh -h
```

---

## flash-image-multi.sh

對指定的 USB serial 裝置進行 flash，方便同時操作多台機器。

### 基本格式

```bash
./flash-image-multi.sh <path> <serial>
```

### 範例

```bash
./flash-image-multi.sh image/v1.1.0 7F3B752C
```

### 查看裝置 serial

```bash
udevadm info --query=property --name=/dev/ttyUSB1 | grep -E "ID_MODEL"
# 輸出範例
# ID_MODEL_ID=9008
# ID_MODEL=QUSB_BULK_CID:0440_SN:B1B26728
# ID_MODEL_ENC=QUSB_BULK_CID:0440_SN:B1B26728
```

`SN:` 後面那串就是要傳給 `flash-image-multi.sh` 的 serial。
