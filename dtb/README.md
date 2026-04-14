<!--
 Copyright (c) 2025 innodisk Crop.
 
 This software is released under the MIT License.
 https://opensource.org/licenses/MIT
-->

# Overview
This repository is for quick modify `dtb.bin` for debugging.

# Requirement
- ubuntu 20.04+
- code, dtc, qdl
- dtc tool
  - ```sudo apt install device-tree-compiler ```

# Usage
1. Modify
    ```bash
    ./modify_qcom_dtb.sh dtb.bin
    ```
2. Save
   ```bash
   ./save_qcom_dtb.sh
   ```
3. Flash
   ```bash
   ./flash_dtb.sh
   ```
