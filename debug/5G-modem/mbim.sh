#!/bin/sh
#
# 5G/LTE Modem MBIM 撥號自動化 — 走 libmbim 官方 wrapper (mbim-network)
#
# 適用範圍:任何進 MBIM composition 的模組
#   (USB interface 看到 class 02/0e + 0a, 被 cdc_mbim driver bind)
#
# 已驗證 (2026-05-29):
#   ✅ Quectel EM060K-GL  — 中華電信 LTE, IP 10.233.74.136 (HW preset 拔阻後)
#   ✅ Quectel MV31W      — 中華電信 5G-NSA, IP 10.234.195.120, DL 400Mbps
#   ✅ Sierra EM7595      — 中華電信 LTE, IP 10.202.214.241
#
# 已知不適用:
#   ❌ QMI composition 模組 (vendor-class iface bound by qmi_wwan)
#      例: Fibocom AIW-356 / FM160 (2cb7:0104)
#      原因: /dev/cdc-wdm0 同名但承載協議不同, 用 MBIM cmd 對 QMI device 會卡死
#      → 本腳本開頭已加 protocol detect, 偵測到就 bail 並提示換 qmicli
#
# 其他失敗類型 (路徑沒錯, 但模組另有問題):
#   ⚠️ MV32W-A 實測卡 'RadioPowerOff' / 'deregistered' — L4 層 (註冊網路) 失敗
#      不是 mbim.sh 路徑問題, 要排 AT+CFUN / 天線 / W_DISABLE pin
#
# 為何用 mbim-network 而不是手刻 mbimcli:
#   * libmbim 官方腳本, 把 ready → reg → attach → connect 一次正確跑完
#   * 不會留半開 session (手刻 mbimcli --no-close 會卡 TRID 在 NotInitialized)
#   * mbim-proxy 自動管理
# ==============================================================================

DEVICE="${DEVICE:-/dev/cdc-wdm0}"
IFACE="${IFACE:-wwan0}"
APN="${APN:-internet}"
CONF=/etc/mbim-network.conf

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------- 先讓 ModemManager 放開 modem（不關 MM、不影響其他 modem）----------
release_mm() {
    command -v mmcli >/dev/null 2>&1 || return 0
    MM_MODEM=$(mmcli -L 2>/dev/null | grep -oE '/org/freedesktop/ModemManager1/Modem/[0-9]+' | head -1)
    [ -z "$MM_MODEM" ] && return 0
    log_info "釋放 MM 對 $MM_MODEM 的控制"
    mmcli -m "$MM_MODEM" --simple-disconnect >/dev/null 2>&1 || true
    mmcli -m "$MM_MODEM" --disable           >/dev/null 2>&1 || true
    sleep 2
}

# ---------- 還原 MM 接管（讓 MM 之後能繼續 monitor modem）----------
restore_mm() {
    [ -z "$MM_MODEM" ] && return 0
    log_info "還原 MM 對 modem 的控制"
    mmcli -m "$MM_MODEM" --enable >/dev/null 2>&1 || true
}
trap restore_mm EXIT INT TERM

# ============================================================================
echo "========================================"
echo " MBIM 撥號 (mbim-network)  APN=$APN  $DEVICE → $IFACE"
echo "========================================"

# Step 0: 環境檢查
command -v mbim-network >/dev/null 2>&1 || { log_err "mbim-network 不存在，裝 libmbim-utils"; exit 1; }
command -v mbimcli      >/dev/null 2>&1 || { log_err "mbimcli 不存在，裝 libmbim-utils"; exit 1; }
[ -c "$DEVICE" ] || { log_err "$DEVICE 不存在"; exit 1; }

# Step 0.5: 協議檢查 — 確認 cdc-wdm0 真的是 MBIM 不是 QMI
# QMI modem 也會建 /dev/cdc-wdm0,但講不通 MBIM,跑下去會卡死 mbim-network start
PROTO_OK=0
for iface_dir in /sys/bus/usb/devices/*/*:1.*; do
    [ -d "$iface_dir" ] || continue
    [ -L "$iface_dir/driver" ] || continue
    drv=$(readlink "$iface_dir/driver" | sed 's,.*/,,')
    case "$drv" in
        cdc_mbim)
            # 確認該 device 暴露的 cdc-wdm 跟我們指定的一致
            wdm_path=$(ls "$iface_dir" 2>/dev/null | grep -E '^cdc-wdm[0-9]+$' | head -1)
            [ -z "$wdm_path" ] && wdm_path=$(find "$iface_dir" -maxdepth 2 -name 'cdc-wdm*' -printf '%f\n' 2>/dev/null | head -1)
            target_wdm=$(basename "$DEVICE")
            if [ "$wdm_path" = "$target_wdm" ] || [ -z "$wdm_path" ]; then
                PROTO_OK=1
            fi
            ;;
    esac
done
# Fallback: 只要系統上有 cdc_mbim bind 的 interface 就放行(粗檢)
if [ "$PROTO_OK" = "0" ]; then
    if lsmod 2>/dev/null | grep -q '^cdc_mbim ' && \
       grep -q . /sys/bus/usb/drivers/cdc_mbim/*:*/bInterfaceClass 2>/dev/null; then
        PROTO_OK=1
    fi
fi
if [ "$PROTO_OK" = "0" ]; then
    log_err "$DEVICE 看起來不是 MBIM control device (沒有 cdc_mbim driver bind 任何 interface)"
    log_err "這支腳本只適用 MBIM 模組。可能你的 modem 走 QMI — 請改用 qmicli / qmi-network。"
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

# Step 2: 寫 mbim-network.conf
log_info "寫 $CONF (APN=$APN, mbim-proxy=yes)"
cat > "$CONF" <<EOF
APN=$APN
PROXY=yes
EOF

# Step 3: 清 wwan0
ip addr flush dev "$IFACE" 2>/dev/null
ip link set "$IFACE" down 2>/dev/null
sleep 1

# Step 4: mbim-network 撥號
log_info "mbim-network start ..."
START_OUT=$(mbim-network "$DEVICE" start 2>&1)
echo "$START_OUT" | tail -10
if ! echo "$START_OUT" | grep -q "Network started successfully"; then
    log_err "mbim-network start 失敗"
    log_err "嘗試 stop 後重來："
    mbim-network "$DEVICE" stop 2>&1 | tail -3
    sleep 2
    log_info "重試..."
    START_OUT=$(mbim-network "$DEVICE" start 2>&1)
    echo "$START_OUT" | tail -10
    echo "$START_OUT" | grep -q "Network started successfully" || { log_err "仍失敗"; exit 2; }
fi

# Step 5: 拉 wwan0 + udhcpc
log_info "拉 $IFACE up + udhcpc"
ip link set "$IFACE" up
sleep 1
if ! udhcpc -i "$IFACE" -q -n -t 5 2>&1 | tail -5; then
    log_err "udhcpc 失敗"
    exit 3
fi

# Step 6: 驗證
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
    log_warn "✗ DNS 不通 — 看 /etc/resolv.conf"
fi

echo ""
log_info "撥號完成。要斷線：mbim-network $DEVICE stop"
