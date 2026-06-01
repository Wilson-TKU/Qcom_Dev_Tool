#!/bin/sh
#
# 5G/LTE Modem 撥號 — ModemManager 路徑 (推薦)
# 適用：任何 ModemManager 認得到的模組 (EM060K-GL / MV32W-A / EM7595 / MV31W ...)
#
# 為何推薦：
#   * MM 有 per-vendor plugin (quectel / sierra / telit ...)，會處理各家韌體的奇怪 init
#   * 不用 root 自己跟 MBIM/QMI 原始協定搏鬥
#   * EM060K-GL 韌體的 standalone MBIM CONNECT 會 NotInitialized，**只有走 MM 才會通**
#
# 缺點：
#   * 部分 build 的 MM 看到 cdc_mbim 介面會標 ignored、fallback 到 PPP via ttyUSB*
#     → 速度只有幾 Mbps；要拿到 MBIM 全速需重 build MM 開啟 MBIM 支援
#
# 用法：
#   APN=internet ./mm-connect.sh           # 連
#   ./mm-connect.sh disconnect             # 斷
# ==============================================================================

APN="${APN:-internet}"
CON_NAME="${CON_NAME:-5g-mm}"
ACTION="${1:-connect}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------- preflight: 檢測 BSP 是否含必要套件 ----------
preflight_bsp_check() {
    local MISSING=""
    # 1. MM 是否含 MBIM/QMI 支援
    if [ -x /usr/sbin/ModemManager ]; then
        if ! ldd /usr/sbin/ModemManager 2>/dev/null | grep -q "libmbim\|libqmi"; then
            log_warn "ModemManager 沒含 MBIM/QMI 支援 (build 時沒帶 --with-mbim/--with-qmi)"
            MISSING="$MISSING MM-MBIM"
        fi
    fi
    # 2. pppd 必要件
    command -v pppd >/dev/null 2>&1 || { log_warn "pppd 不存在 (PPP fallback path 無法用)"; MISSING="$MISSING pppd"; }
    # 3. NM 是否有 wwan plugin
    if command -v nmcli >/dev/null 2>&1; then
        if nmcli -t -f WWAN-HW general status 2>/dev/null | grep -q missing; then
            log_warn "NetworkManager WWAN-HW: missing (沒 networkmanager-plugin-wwan)"
            MISSING="$MISSING NM-wwan"
        fi
    fi
    # 4. PID-specific udev rule
    local PID
    PID=$(awk -F= '/idProduct/ {print toupper($2)}' /sys/bus/usb/devices/*/idProduct 2>/dev/null | head -1)
    if [ -f /usr/lib/udev/rules.d/77-mm-quectel-port-types.rules ] && [ -n "$PID" ]; then
        if ! grep -qi "ProductID==\"$PID\"\|idProduct\}==\"$PID\"" /usr/lib/udev/rules.d/77-mm-quectel-port-types.rules; then
            log_warn "udev port-types rule 沒涵蓋當前 modem PID = $PID"
            MISSING="$MISSING udev-rule"
        fi
    fi

    if [ -n "$MISSING" ]; then
        log_warn "BSP 缺件:$MISSING"
        log_warn "詳見 modem-guide.md 第 14 節 (BSP 補丁清單)"
    fi
}

ensure_services() {
    for s in ModemManager NetworkManager; do
        if ! systemctl is-active --quiet $s; then
            log_info "啟動 $s"
            systemctl start $s
        fi
    done
}

wait_modem() {
    local i=0
    while [ $i -lt 30 ]; do
        MM_PATH=$(mmcli -L 2>/dev/null | grep -oE '/org/freedesktop/ModemManager1/Modem/[0-9]+' | head -1)
        [ -n "$MM_PATH" ] && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

do_connect() {
    preflight_bsp_check
    ensure_services
    log_info "等 MM 偵測 modem (最多 30s)..."
    if ! wait_modem; then
        log_err "MM 找不到 modem。檢查：lsusb / dmesg / mmcli -L"
        exit 1
    fi
    log_info "MM modem: $MM_PATH"

    # state 可能是 disabled / registered / connected
    STATE=$(mmcli -m "$MM_PATH" 2>/dev/null | grep -m1 "state:" | awk -F': ' '{print $2}' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    log_info "current state: $STATE"

    if [ "$STATE" = "disabled" ] || [ "$STATE" = "enabling" ]; then
        log_info "Enable modem..."
        mmcli -m "$MM_PATH" --enable >/dev/null 2>&1 || { log_err "enable 失敗"; exit 1; }
        sleep 3
    fi

    # 已經 connected 就 skip
    STATE=$(mmcli -m "$MM_PATH" 2>/dev/null | grep -m1 "state:" | awk -F': ' '{print $2}' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    if [ "$STATE" = "connected" ]; then
        log_warn "已連線，跳過 connect"
    else
        log_info "撥號 APN=$APN ..."
        if ! mmcli -m "$MM_PATH" --simple-connect="apn=$APN,ip-type=ipv4" 2>&1 | grep -q "successfully connected"; then
            log_err "撥號失敗。詳細："
            mmcli -m "$MM_PATH" --simple-connect="apn=$APN,ip-type=ipv4"
            exit 1
        fi
    fi

    # bearer 資訊
    BEARER_INFO=$(mmcli -m "$MM_PATH" -b 0 2>/dev/null)
    BEARER_IF=$(echo "$BEARER_INFO" | grep "interface:" | awk -F': ' '{print $2}' | xargs)
    BEARER_METHOD=$(echo "$BEARER_INFO" | grep "method:" | awk -F': ' '{print $2}' | xargs)
    log_info "Bearer: interface=$BEARER_IF  method=$BEARER_METHOD"

    # 如果 method=ppp 表示 MM 用 PPP via AT (速度受限)
    # 如果 method=dhcp/static 表示走 wwan0 MBIM/QMI (好)
    case "$BEARER_METHOD" in
        ppp)
            log_warn "走 PPP via $BEARER_IF — 速度上限約幾 Mbps (AT 串口傳輸)"
            log_warn "若需 MBIM 全速：重 build MM with --with-mbim 或檢查 modem composition"
            ;;
        dhcp|static)
            log_info "走 $BEARER_METHOD via $BEARER_IF — 全速 path"
            ;;
    esac

    # 走 PPP path：必須有 pppd 接手才會真正撥
    if [ "$BEARER_METHOD" = "ppp" ]; then
        if ! command -v pppd >/dev/null 2>&1; then
            log_err "MM 已下 AT 準備好，但 pppd 不存在 → PPP session 起不來"
            log_err "wwan0 / ppp0 都不會有 IP，data path 卡死"
            log_err ""
            log_err "→ 解法：image 加 'ppp' package 重 build BSP"
            log_err "→ 或   :重 build ModemManager 開啟 mbim/qmi support 用 wwan0"
            log_err ""
            log_warn "目前 MM bearer state=connected 是假象，沒任何 packet 流"
            exit 2
        fi
        # 未來如果 ppp 裝了：這裡可以手動 spawn pppd
        log_warn "pppd 在，但本腳本還沒實作手動 pppd dial 流程"
        log_warn "建議重 build NM with wwan plugin，讓 nmcli con up 自動跑 pppd"
    fi

    # 用 nmcli 把 connection profile 建好（要 NM 有 wwan plugin 才會 work）
    if nmcli -t -f WWAN-HW general status 2>/dev/null | grep -qi missing; then
        log_warn "NM WWAN-HW missing，跳過 nmcli profile 設定"
    else
        if ! nmcli -t -f NAME con show | grep -qx "$CON_NAME"; then
            log_info "建 NM connection profile: $CON_NAME"
            # ifname 不要寫 '*'，那會比對到 lo；對 gsm 類型不寫 ifname 讓 NM auto-bind 即可
            nmcli con add type gsm con-name "$CON_NAME" apn "$APN" >/dev/null 2>&1 || true
        fi
        log_info "拉起 NM connection: $CON_NAME"
        nmcli con up "$CON_NAME" 2>&1 | head -3
    fi

    # 如果 bearer method 是 dhcp/static（MBIM/QMI 路徑），那 wwan0 上應該已經有 IP
    if [ "$BEARER_METHOD" = "dhcp" ] || [ "$BEARER_METHOD" = "static" ]; then
        log_info "wwan0 應該已有 IP，udhcpc 確認一下"
        ip link set "$BEARER_IF" up
        udhcpc -i "$BEARER_IF" -q -n -t 5 >/dev/null 2>&1
    fi

    sleep 2
    echo ""
    log_info "==== 最終結果 ===="
    nmcli -t -f NAME,DEVICE,STATE con show --active 2>/dev/null | grep "$CON_NAME"
    ip -4 addr show "$BEARER_IF" 2>/dev/null | grep -E "inet "
    ip a show ppp0 2>/dev/null | grep -E "inet "
    ip route | grep -E "default|$BEARER_IF" | head -3

    log_info "ping test..."
    if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log_info "外網通 ✓"
    else
        log_err "ping 失敗 — 看 route / DNS / 或 PPP/MBIM 沒真撥起"
        exit 3
    fi
}

do_disconnect() {
    MM_PATH=$(mmcli -L 2>/dev/null | grep -oE '/org/freedesktop/ModemManager1/Modem/[0-9]+' | head -1)
    if [ -z "$MM_PATH" ]; then
        log_warn "MM 找不到 modem"
        exit 0
    fi
    nmcli con down "$CON_NAME" 2>/dev/null || true
    mmcli -m "$MM_PATH" --simple-disconnect 2>&1 | head -1
    log_info "已斷線"
}

case "$ACTION" in
    connect)    do_connect ;;
    disconnect) do_disconnect ;;
    *) echo "Usage: APN=xxx $0 [connect|disconnect]"; exit 1 ;;
esac
