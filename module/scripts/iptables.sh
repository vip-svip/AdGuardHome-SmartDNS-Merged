#!/system/bin/sh
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
. "$AGH_DIR/scripts/config.prop"
MAIN_LOG="$AGH_DIR/agh.log"

# 说明：原「iptables 加固」子系统（AGH_HARDEN / AGH_HARDEN6 链、#!iptables: 指令解析）
# 已按用户要求整体移除，只保留 DNS 劫持（nat ADGUARD/ADGUARD6）与进程守护。

# 防止重复启动
[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

# 检测Adguardhome是否存活
agh_running() {
    pgrep -f "$BIN_DIR/AdGuardHome" >/dev/null 2>&1
}

# 启动AdGuardHome
start_agh() {
    {
        case "$(getprop persist.sys.locale)" in
            zh*) echo "$(date '+%F %T') AdGuardHome 进程丢失，正在重启..." ;;
            *)   echo "$(date '+%F %T') AdGuardHome process lost, restarting..." ;;
        esac
    } >> "$MAIN_LOG"
    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    "$BIN_DIR/AdGuardHome" --no-check-update >/dev/null 2>&1 &
}

# 重建iptables规则
rebuild_rules() {
    iptables -w 2 -t nat -L ADGUARD >/dev/null 2>&1 || {
        iptables -w 2 -t nat -N ADGUARD
        iptables -w 2 -t nat -I OUTPUT -j ADGUARD
    }
    iptables -w 2 -t nat -F ADGUARD
    # uid 0 (root) / uid 9999 (SmartDNS) 豁免: AGH/SmartDNS 自身出站查询不回环
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 9999 -j RETURN
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -j RETURN
    iptables -w 2 -t nat -A ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 2 -t nat -A ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port"
    # IPv6 DNS 劫持（部分内核无 v6 nat 表，失败即跳过）
    if ip6tables -w 2 -t nat -L ADGUARD6 >/dev/null 2>&1; then
        ip6tables -w 2 -t nat -F ADGUARD6
    else
        ip6tables -w 2 -t nat -N ADGUARD6 2>/dev/null
        ip6tables -w 2 -t nat -I OUTPUT -j ADGUARD6 2>/dev/null
    fi
    ip6tables -w 2 -t nat -A ADGUARD6 -m owner --uid-owner 9999 -j RETURN 2>/dev/null
    ip6tables -w 2 -t nat -A ADGUARD6 -m owner --uid-owner 0 -j RETURN 2>/dev/null
    ip6tables -w 2 -t nat -A ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null
    ip6tables -w 2 -t nat -A ADGUARD6 -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null
    # 只做 DNS 劫持；iptables 加固(DROP 853/53 v6)功能已按用户要求移除。
    # REDIRECT 规则即时生效，不需要开关飞行模式刷新网络。
}

# SmartDNS存活守护
smartdns_running() {
    pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1
}

SD_DIR="$AGH_DIR/smartdns"
SMARTDNS_BIN="$SD_DIR/usr/local/lib/smartdns/smartdns"
start_smartdns() {
    mkdir -p "$SD_DIR/dev" "$SD_DIR/proc" "$SD_DIR/sys" "$SD_DIR/tmp" "$SD_DIR/run"
    mountpoint -q "$SD_DIR/dev" || mount --bind /dev "$SD_DIR/dev" 2>/dev/null
    mountpoint -q "$SD_DIR/proc" || mount --bind /proc "$SD_DIR/proc" 2>/dev/null
    mountpoint -q "$SD_DIR/sys" || mount --bind /sys "$SD_DIR/sys" 2>/dev/null
    mountpoint -q "$SD_DIR/tmp" || mount -t tmpfs -o mode=0777,nosuid,nodev tmpfs "$SD_DIR/tmp" 2>/dev/null
    mountpoint -q "$SD_DIR/run" || mount -t tmpfs -o mode=0777,nosuid,nodev tmpfs "$SD_DIR/run" 2>/dev/null
    setsid chroot "$SD_DIR" /usr/local/lib/smartdns/smartdns >/dev/null 2>&1 &
}

# 规则守护循环（5s）
last_agh=""
while true; do
    . "$AGH_DIR/scripts/config.prop"
    need_restart=0
    agh_running || need_restart=1
    if [ -x "$SMARTDNS_BIN" ] && ! smartdns_running; then
        start_smartdns
    fi
    # 加密上游转发守护（有加密上游配置时保持 dnsenc 在线）
    if [ -x "$BIN_DIR/dnsenc" ]; then
        encn=$(grep -vE '^[[:space:]]*(#|$)' "$SD_DIR/etc/smartdns/encrypted.conf" 2>/dev/null | grep -c . 2>/dev/null)
        [ -n "$encn" ] || encn=0
        if [ "$encn" -gt 0 ]; then
            if ! pgrep -f "$BIN_DIR/dnsenc" >/dev/null 2>&1; then
                SSL_CERT_DIR=/system/etc/security/cacerts/ setsid "$BIN_DIR/dnsenc" \
                    -listen 127.0.0.1:6054 -conf "$SD_DIR/etc/smartdns/encrypted.conf" \
                    >> "$AGH_DIR/dnsenc.log" 2>&1 &
            fi
        else
            # 加密上游全部删掉时，转发进程也一起停，别留空转
            if pgrep -f "$BIN_DIR/dnsenc" >/dev/null 2>&1; then
                pkill -9 -f "$BIN_DIR/dnsenc" 2>/dev/null
                _i=0
                while [ "$_i" -lt 20 ]; do
                    pgrep -f "$BIN_DIR/dnsenc" >/dev/null 2>&1 || break
                    sleep 0.25; _i=$((_i+1))
                done
            fi
        fi
    fi
    need_fix=0
    iptables -w 2 -t nat -C ADGUARD -m owner --uid-owner 9999 -j RETURN 2>/dev/null || need_fix=1
    iptables -w 2 -t nat -C ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
    iptables -w 2 -t nat -C ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
    # v6 nat 可能不被内核支持，只在该链存在时检查
    if ip6tables -w 2 -t nat -L ADGUARD6 >/dev/null 2>&1; then
        ip6tables -w 2 -t nat -C ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
        ip6tables -w 2 -t nat -C ADGUARD6 -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
    fi
    [ $need_restart -eq 1 ] && start_agh
    cur_agh=0
    agh_running && cur_agh=1
    if [ $need_restart -eq 1 ] || [ $need_fix -eq 1 ] || [ "$cur_agh" != "$last_agh" ]; then
        rebuild_rules
        last_agh=$cur_agh
    fi
    sleep 5
done &