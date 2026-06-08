#!/bin/bash
#
# setup-host-env.sh
# -----------------------------------------------------------------------------
# 在一台全新的 Ubuntu (建議 22.04) 上，一鍵準備「燒錄高通平台 + adb 連線」的環境。
#
# 涵蓋：
#   - apt 套件 (Qualcomm Build Guide 列的 build 相依套件 + adb/fastboot + qdl build deps)
#   - Google `repo` 工具
#   - 從原始碼編譯 `qdl` (linux-msm/qdl)，支援 --storage / --include，與本 repo 的 flash 腳本相容
#   - udev rules：EDL/QDL 模式 (05c6:9008) + Qualcomm adb 裝置 → 免 sudo 即可存取
#   - 把目前使用者加入 plugdev 群組
#   - (選用) git global 設定與 locale
#
# 參考文件 (Qualcomm Linux Build Guide 80-70029-254 / USB 80-70029-8SC)：
#   https://docs.qualcomm.com/doc/80-70029-254/topic/github_workflow_unregistered_users.html
#   https://docs.qualcomm.com/doc/80-70029-254/topic/flash_images.html
#   https://docs.qualcomm.com/doc/80-70029-8SC/topic/usb.html
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_USER="${SUDO_USER:-$USER}"          # 即使用 sudo 執行，群組也加到真正的使用者
QDL_REPO="https://github.com/linux-msm/qdl.git"
QDL_SRC_DIR="${QDL_SRC_DIR:-$HOME/.local/src/qdl}"

# ================= Usage / Help =================
usage() {
    cat <<EOF
Usage:
  $(basename "$0") [stage ...]
  $(basename "$0") -h | --help

  - stage 省略時等於 'all'
  - 可一次帶多個 stage，依序執行，例如:  $(basename "$0") apt udev verify

Stages:
  all      預設批次 = apt repo qdl udev verify   (不含 gitcfg)
  apt      安裝 build 相依套件 + adb + fastboot + qdl 編譯相依
  repo     安裝 Google repo 工具 (Yocto/BSP build 用)
  qdl      從原始碼編譯並安裝 qdl 到 /usr/local/bin
  udev     安裝 udev rules (EDL 05c6:9008 + Qualcomm adb) 並加入 plugdev
  gitcfg   設定 git global (name/email/buffer) 與 locale en_US.UTF-8
  verify   檢查 adb / fastboot / qdl / lsusb / 群組狀態

Examples:
  $(basename "$0")                 # = all，一台新機從零準備好燒錄+adb
  $(basename "$0") qdl             # 只重編 qdl
  $(basename "$0") udev verify     # 重灌 udev rules 後驗證
  $(basename "$0") all gitcfg      # 全部 + git/locale 設定
EOF
}

# ================= 小工具 =================
log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

need_sudo() {
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        log "部分步驟需要 sudo 權限，可能會要求輸入密碼"
    fi
}

# ================= Stage 函式 =================

stage_apt() {
    log "Stage: apt — 安裝套件"
    sudo apt-get update

    # Qualcomm Build Guide 列的 build 相依套件
    local BUILD_PKGS=(
        gawk wget git diffstat unzip texinfo gcc build-essential chrpath
        socat cpio python3 python3-pip python3-pexpect xz-utils debianutils
        iputils-ping python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev
        pylint xterm python3-subunit mesa-common-dev zstd liblz4-tool locales
        tar python-is-python3 file libxml-opml-simplegen-perl vim whiptail
        g++ libacl1
    )
    # 編譯 qdl 需要的相依
    local QDL_BUILD_PKGS=( libusb-1.0-0-dev libxml2-dev pkg-config make )

    sudo apt-get install -y "${BUILD_PKGS[@]}" "${QDL_BUILD_PKGS[@]}" || \
        warn "部分 build 套件安裝失敗 (不同 Ubuntu 版本套件名可能不同，可忽略非必要項)"

    # adb / fastboot：Ubuntu 22.04 套件名為 adb / fastboot，舊版為 android-tools-*
    if sudo apt-get install -y adb fastboot; then
        log "已安裝 adb / fastboot"
    elif sudo apt-get install -y android-tools-adb android-tools-fastboot; then
        log "已安裝 android-tools-adb / android-tools-fastboot"
    else
        warn "adb/fastboot 透過 apt 安裝失敗，請手動安裝 platform-tools"
    fi
}

stage_repo() {
    log "Stage: repo — 安裝 Google repo 工具"
    if command -v repo >/dev/null 2>&1; then
        log "repo 已存在，略過"
        return 0
    fi
    if sudo apt-get install -y repo; then
        log "已透過 apt 安裝 repo"
    else
        warn "apt 沒有 repo 套件，改用官方腳本安裝到 /usr/local/bin/repo"
        sudo curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
            -o /usr/local/bin/repo && sudo chmod a+x /usr/local/bin/repo
    fi
}

stage_qdl() {
    log "Stage: qdl — 從原始碼編譯 ($QDL_REPO)"
    if ! command -v git >/dev/null 2>&1; then
        err "缺 git，請先跑: $(basename "$0") apt"
        return 1
    fi

    mkdir -p "$(dirname "$QDL_SRC_DIR")"
    if [ -d "$QDL_SRC_DIR/.git" ]; then
        log "更新既有原始碼: $QDL_SRC_DIR"
        git -C "$QDL_SRC_DIR" pull --ff-only || warn "git pull 失敗，沿用現有原始碼"
    else
        git clone --depth 1 "$QDL_REPO" "$QDL_SRC_DIR" || {
            err "git clone qdl 失敗 (檢查網路)。若公司網路擋外網，可改用 Qualcomm SDK 內附的 qdl-2.3.1"
            return 1
        }
    fi

    make -C "$QDL_SRC_DIR" || { err "qdl 編譯失敗 (確認已裝 libusb-1.0-0-dev / libxml2-dev)"; return 1; }

    sudo install -m 0755 "$QDL_SRC_DIR/qdl" /usr/local/bin/qdl
    log "qdl 已安裝到 /usr/local/bin/qdl"
    /usr/local/bin/qdl --help 2>&1 | head -3 || true
    warn "注意：本 repo 的 image/flash-image.sh 預設呼叫同目錄下的 qdl-2.3.1 (Qualcomm SDK 內附版本)。"
    warn "      若你只用系統 qdl，可在腳本中把 QDL_TOOL 改成 'qdl'，或把 /usr/local/bin/qdl 連過去。"
}

stage_udev() {
    log "Stage: udev — 安裝 rules 並加入 plugdev"
    local RULES_FILE="/etc/udev/rules.d/51-qcom-usb.rules"

    sudo tee "$RULES_FILE" >/dev/null <<'RULES'
# Qualcomm USB udev rules — 由 Qcom_Dev_Tool/dev/host-env/setup-host-env.sh 產生
#
# EDL / QDL (Emergency Download，Firehose) 模式 — 燒錄時使用
SUBSYSTEMS=="usb", ATTRS{idVendor}=="05c6", ATTRS{idProduct}=="9008", MODE="0666", GROUP="plugdev"
# Sahara / QDL 其它常見 PID
SUBSYSTEMS=="usb", ATTRS{idVendor}=="05c6", ATTRS{idProduct}=="900e", MODE="0666", GROUP="plugdev"

# Qualcomm 一般裝置 (adb / diag+adb 等 composite)，給 plugdev 群組存取
SUBSYSTEM=="usb", ATTRS{idVendor}=="05c6", MODE="0660", GROUP="plugdev"

# fastboot (bootloader)，部分版本走 Google VID 18d1
SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", MODE="0660", GROUP="plugdev"
RULES

    log "已寫入 $RULES_FILE"

    # 確保 plugdev 群組存在並把使用者加進去
    getent group plugdev >/dev/null || sudo groupadd plugdev
    if id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx plugdev; then
        log "$RUN_USER 已在 plugdev 群組"
    else
        sudo usermod -aG plugdev "$RUN_USER"
        warn "已把 $RUN_USER 加入 plugdev — 需『重新登入』或重開機才會生效"
    fi

    # 重新載入 udev
    sudo udevadm control --reload-rules && sudo udevadm trigger
    log "udev rules 已重新載入"
}

stage_gitcfg() {
    log "Stage: gitcfg — git global 設定與 locale"

    local cur_email cur_name
    cur_email="$(git config --global --get user.email 2>/dev/null)"
    cur_name="$(git config --global --get user.name 2>/dev/null)"
    [ -n "$cur_email" ] && log "目前 git user.email = $cur_email (未變更)" \
                        || warn "git user.email 尚未設定，請手動: git config --global user.email <email>"
    [ -n "$cur_name" ]  && log "目前 git user.name  = $cur_name (未變更)" \
                        || warn "git user.name 尚未設定，請手動: git config --global user.name <name>"

    # Build Guide 建議的 git 大檔/慢速容忍設定 (clone 大型 BSP 用)
    git config --global color.ui auto
    git config --global http.postBuffer 1048576000
    git config --global http.maxRequestBuffer 1048576000
    git config --global http.lowSpeedLimit 0
    git config --global http.lowSpeedTime 999999
    log "已套用 git http buffer / color 設定"

    # locale
    sudo locale-gen en_US.UTF-8
    sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    log "已設定 locale en_US.UTF-8 (新開的 shell 生效)"
}

stage_verify() {
    log "Stage: verify — 檢查環境"
    echo "------------------------------------------"
    printf "  adb       : "; command -v adb >/dev/null && adb version | head -1 || echo "未安裝"
    printf "  fastboot  : "; command -v fastboot >/dev/null && fastboot --version | head -1 || echo "未安裝"
    printf "  qdl       : "; command -v qdl >/dev/null && echo "$(command -v qdl)" || echo "未安裝 (PATH 上沒有)"
    printf "  repo      : "; command -v repo >/dev/null && echo "$(command -v repo)" || echo "未安裝"
    printf "  plugdev   : "; id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx plugdev && echo "$RUN_USER 已加入" || echo "$RUN_USER 尚未生效 (需重新登入)"
    echo "------------------------------------------"
    log "目前 USB 上的 Qualcomm/Google 裝置 (lsusb):"
    lsusb | grep -iE "05c6|18d1|qualcomm|google" || echo "  (沒看到，請確認板子已接上 USB)"
    echo "------------------------------------------"
    log "adb devices:"
    command -v adb >/dev/null && adb devices || echo "  (adb 未安裝)"
    echo "------------------------------------------"
    cat <<'TIP'
進 EDL 燒錄模式的方法 (擇一)：
  - adb:    adb shell reboot edl          (板子目前在 adb 可用時)
  - UART:   在 shell 下 reboot edl
  - 手動:   按住 F_DL → 接上 +12V Type-C → 放開
  進入後 lsusb 應出現  05c6:9008 (Qualcomm CDC ... 9008)，即可用 qdl 燒錄。

燒錄 (用本 repo 的腳本)：
  cd <repo>/image && ./flash-image.sh all <image 根目錄>
TIP
}

# ================= stage 展開 =================
is_stage() {
    case "$1" in
        all|apt|repo|qdl|udev|gitcfg|verify) return 0 ;;
        *) return 1 ;;
    esac
}
expand_stage() {
    case "$1" in
        all) printf '%s\n' apt repo qdl udev verify ;;
        *)   printf '%s\n' "$1" ;;
    esac
}

# ================= 參數解析 =================
if [ $# -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage; exit 0
fi

STAGE_ARGS=( "$@" )
[ "${#STAGE_ARGS[@]}" -eq 0 ] && STAGE_ARGS=( all )

STEPS=()
for s in "${STAGE_ARGS[@]}"; do
    if ! is_stage "$s"; then
        err "Unknown stage '$s'"; echo ""; usage; exit 1
    fi
    while IFS= read -r step; do
        already=0
        for existing in "${STEPS[@]}"; do
            [ "$existing" = "$step" ] && { already=1; break; }
        done
        [ $already -eq 0 ] && STEPS+=( "$step" )
    done < <(expand_stage "$s")
done

echo "------------------------------------------"
echo "Host env setup"
echo "  User to configure : $RUN_USER"
echo "  Stages            : ${STAGE_ARGS[*]}"
echo "  Steps to run      : ${STEPS[*]}"
echo "------------------------------------------"

need_sudo

for step in "${STEPS[@]}"; do
    case "$step" in
        apt)    stage_apt ;;
        repo)   stage_repo ;;
        qdl)    stage_qdl ;;
        udev)   stage_udev ;;
        gitcfg) stage_gitcfg ;;
        verify) stage_verify ;;
    esac
done

log "完成！若有把使用者加入 plugdev，請重新登入後再用 qdl/adb。"
