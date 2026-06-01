#!/bin/sh
# 5G/LTE Modem QMI 撥號自動化 — 走 libqmi 官方 wrapper (qmi-network)
#
# 適用範圍:任何進 QMI composition 的模組
#   (USB interface 看到 vendor-class ff/ff/50 之類, 被 qmi_wwan driver bind)
#
# 已驗證 (2026-05-29):
#   - Fibocom AIW-356 / FM160 (2cb7:0104) — qmicli signal info 讀到 LTE -75dBm
#     (撥號路徑驗證中, 用本腳本)
#
# 已知不適用:
#   ❌ MBIM composition 模組 — 請改用 mbim.sh
#      (/dev/cdc-wdm0 同名但承載協議不同, 用 QMI cmd 對 MBIM device 會失敗)
#      → 本腳本開頭已加 protocol detect, 偵測到就 bail 並提示換 mbim.sh
#
# 設計與 mbim.sh 平行:
#   * 釋放 MM → qmi-network start → udhcpc → 驗證 → 還原 MM
#   * qmi-proxy 自動管理 (PROXY=yes)
#   * 自動處理現代 modem 必備的 raw-IP mode (qmi_wwan)
#
# 為何用 qmi-network 而不是手刻 qmicli:
#   * libqmi 官方腳本, 把 PDP context 啟動 / WDS start-network / 拿 packet handle 一次跑完
#   * 不會留半開 session
#   * 自動透過 qmi-proxy multiplex, 避免 device-busy 衝突
# ==============================================================================

DEVICE="${DEVICE:-/dev/cdc-wdm0}"
IFACE="${IFACE:-wwan0}"
APN="${APN:-internet}"
CONF=/etc/qmi-network.conf

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------- 釋放 MM 對 modem 的控制 ----------
release_mm() {
    command -v mmcli >/dev/null 2>&1 || return 0
    MM_MODEM=$(mmcli -L 2>/dev/null | grep -oE '/org/freedesktop/ModemManager1/Modem/[0-9]+' | head -1)
    [ -z "$MM_MODEM" ] && return 0
    log_info "釋放 MM 對 $MM_MODEM 的控制"
    mmcli -m "$MM_MODEM" --simple-disconnect >/dev/null 2>&1 || true
    mmcli -m "$MM_MODEM" --disable           >/dev/null 2>&1 || true
    sleep 2
}

restore_mm() {
    [ -z "$MM_MODEM" ] && return 0
    log_info "還原 MM 對 modem 的控制"
    mmcli -m "$MM_MODEM" --enable >/dev/null 2>&1 || true
}
trap restore_mm EXIT INT TERM

# ============================================================================
echo "========================================"
echo " QMI 撥號 (qmi-network)  APN=$APN  $DEVICE → $IFACE"
echo "========================================"

# Step 0: 環境檢查
command -v qmi-network >/dev/null 2>&1 || { log_err "qmi-network 不存在,裝 libqmi-utils"; exit 1; }
command -v qmicli      >/dev/null 2>&1 || { log_err "qmicli 不存在,裝 libqmi-utils"; exit 1; }
[ -c "$DEVICE" ]   || { log_err "$DEVICE 不存在"; exit 1; }
[ -d "/sys/class/net/$IFACE" ] || { log_err "$IFACE 不存在"; exit 1; }

# Step 0.5: 協議檢查 — 確認 cdc-wdm0 真的是 QMI 不是 MBIM
PROTO_OK=0
for iface_dir in /sys/bus/usb/devices/*/*:1.*; do
    [ -d "$iface_dir" ] || continue
    [ -L "$iface_dir/driver" ] || continue
    drv=$(readlink "$iface_dir/driver" | sed 's,.*/,,')
    case "$drv" in
        qmi_wwan) PROTO_OK=1 ;;
    esac
done
if [ "$PROTO_OK" = "0" ]; then
    log_err "$DEVICE 看起來不是 QMI control device (沒有 qmi_wwan driver bind 任何 interface)"
    log_err "這支腳本只適用 QMI 模組。可能你的 modem 走 MBIM — 請改用 mbim.sh / mbimcli。"
    log_warn "目前 USB modem interface 狀態:"
    for d in /sys/bus/usb/devices/*/idVendor; do
        v=$(cat "$d" 2>/dev/null)
        case "$v" in
            2c7c|1bc7|1199|2cb7|413c|0489|1e0e)
                dev=$(dirname "$d")
                echo "  $dev VID=$v PID=$(cat $dev/idProduct)"
                for i in "$dev"/*:*; do
                    [ -d "$i" ] || continue
                    drv="(NONE)"
                    [ -L "$i/driver" ] && drv=$(readlink "$i/driver" | sed 's,.*/,,')
                    printf "    %s class=%s/%s/%s drv=%s\n" \
                        "$(basename $i)" \
                        "$(cat $i/bInterfaceClass)" \
                        "$(cat $i/bInterfaceSubClass)" \
                        "$(cat $i/bInterfaceProtocol)" \
                        "$drv"
                done
                ;;
        esac
    done
    exit 1
fi

# Step 1: 釋放 MM
release_mm

# Step 2: 清理上次的狀態 — 避免 "PDH already exists" / 殘留 CID
#   qmi-network 會在 /tmp/qmi-network-state-<wdm> 存 CID+PDH 給 "resume" 用,
#   但我們每次都想要乾淨 dial,所以先 idempotent stop + 清檔 + flush IP。
WDM_BASE=$(basename "$DEVICE")               # cdc-wdm0
STATE_FILE="/tmp/qmi-network-state-$WDM_BASE"
if [ -f "$STATE_FILE" ]; then
    log_info "偵測到舊 state ($STATE_FILE),先 qmi-network stop 清乾淨"
    qmi-network "$DEVICE" stop >/dev/null 2>&1 || true
    rm -f "$STATE_FILE"
fi
# 同步把可能殘存的 IP 清掉(不然 udhcpc 拿到新 lease 時會跟舊 IP 並存)
ip addr flush dev "$IFACE" 2>/dev/null || true

# Step 3: 切 raw-IP mode (現代 QMI modem 大多需要)
#   QMI/RmNet 預設可能是 802.3 (Ethernet frame), 但現代韌體只支援 raw-IP
#   切之前 IFACE 必須是 DOWN 狀態
log_info "切 $IFACE 為 raw-IP mode"
ip link set "$IFACE" down 2>/dev/null
RAW_IP_NODE="/sys/class/net/$IFACE/qmi/raw_ip"
if [ -w "$RAW_IP_NODE" ]; then
    echo Y > "$RAW_IP_NODE" 2>/dev/null && log_info "  raw_ip = Y" || log_warn "  raw_ip 寫入失敗(可能 driver 不支援切換)"
else
    log_warn "  $RAW_IP_NODE 不存在或不可寫(舊版 qmi_wwan driver?),跳過"
fi

# Step 4: 寫 qmi-network.conf (使用 qmi-proxy)
log_info "寫 $CONF (APN=$APN, qmi-proxy=yes)"
cat > "$CONF" <<EOF
APN=$APN
PROXY=yes
EOF

# Step 5: qmi-network 撥號 (state 已乾淨,理論上第一發就過)
log_info "qmi-network start ..."
START_OUT=$(qmi-network "$DEVICE" start 2>&1)
echo "$START_OUT" | tail -10
if ! echo "$START_OUT" | grep -qiE "Network started|started successfully"; then
    log_warn "第一發 start 沒過 — 走 fallback: stop → 等 2s → 再 start"
    qmi-network "$DEVICE" stop >/dev/null 2>&1 || true
    rm -f "$STATE_FILE"
    sleep 2
    START_OUT=$(qmi-network "$DEVICE" start 2>&1)
    echo "$START_OUT" | tail -10
    echo "$START_OUT" | grep -qiE "Network started|started successfully" || { log_err "qmi-network start 仍失敗"; exit 2; }
fi

# Step 6: 拉 wwan0 up
log_info "拉 $IFACE up"
ip link set "$IFACE" up
sleep 1

# Step 7: 取 IP — 先試 udhcpc, 失敗 fall-back 到 qmicli wds 拿 static IP
log_info "嘗試 udhcpc 取 IP"
if udhcpc -i "$IFACE" -q -n -t 5 2>&1 | tail -5 | grep -q "obtained"; then
    log_info "  ✓ udhcpc 取得 IP"
else
    log_warn "  udhcpc 失敗,改從 qmicli wds-get-current-settings 拿 IP"
    WDS_OUT=$(qmicli -d "$DEVICE" --wds-get-current-settings 2>&1)
    echo "$WDS_OUT" | tail -20
    IP4=$(echo  "$WDS_OUT" | grep -E "IPv4 address:"  | awk '{print $NF}' | head -1)
    GW4=$(echo  "$WDS_OUT" | grep -E "IPv4 gateway address:" | awk '{print $NF}' | head -1)
    PFX=$(echo  "$WDS_OUT" | grep -E "IPv4 subnet mask:" | awk '{print $NF}' | head -1)
    DNS1=$(echo "$WDS_OUT" | grep -E "IPv4 primary DNS:" | awk '{print $NF}' | head -1)
    DNS2=$(echo "$WDS_OUT" | grep -E "IPv4 secondary DNS:" | awk '{print $NF}' | head -1)
    if [ -z "$IP4" ]; then
        log_err "wds-get-current-settings 也沒拿到 IPv4 address"
        exit 3
    fi
    # subnet mask 轉 prefix length (簡單做法: 255.255.255.0 → 24 等)
    case "$PFX" in
        255.255.255.252) CIDR=30 ;;
        255.255.255.248) CIDR=29 ;;
        255.255.255.240) CIDR=28 ;;
        255.255.255.224) CIDR=27 ;;
        255.255.255.192) CIDR=26 ;;
        255.255.255.128) CIDR=25 ;;
        255.255.255.0)   CIDR=24 ;;
        *)               CIDR=29 ;;  # 大多 cellular bearer 在 /29 ~ /30 之間
    esac
    log_info "  套用 IP $IP4/$CIDR  GW $GW4  DNS $DNS1 $DNS2"
    ip addr add "$IP4/$CIDR" dev "$IFACE"
    [ -n "$GW4" ] && ip route add default via "$GW4" dev "$IFACE"
    if [ -n "$DNS1" ]; then
        {
            echo "nameserver $DNS1"
            [ -n "$DNS2" ] && echo "nameserver $DNS2"
        } > /tmp/resolv.conf.qmi
        log_info "  DNS 寫到 /tmp/resolv.conf.qmi (請自行 merge 到 /etc/resolv.conf)"
    fi
fi

# Step 8: 驗證
sleep 1
echo ""
log_info "==== 結果 ===="
ip a show "$IFACE" 2>&1 | grep -E "inet "
ip route | grep -E "default|$IFACE" | head -3

log_info "ping test..."
if ping -I "$IFACE" -c 3 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log_info "✓ 外網通 (8.8.8.8)"
else
    log_err "✗ ping 失敗"
    exit 4
fi

if ping -I "$IFACE" -c 1 -W 3 google.com >/dev/null 2>&1; then
    log_info "✓ DNS 解析正常"
else
    log_warn "✗ DNS 不通 — 看 /etc/resolv.conf 或 /tmp/resolv.conf.qmi"
fi

echo ""
log_info "撥號完成。要斷線: qmi-network $DEVICE stop"
