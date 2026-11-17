#!/system/bin/sh
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
. "$AGH_DIR/scripts/config.prop"
MAIN_LOG="$AGH_DIR/agh.log"

# 说明：原「iptables 加固」子系统（AGH_HARDEN / AGH_HARDEN6 链、#!iptables: 指令解析）
# 已按用户要求整体移除，只保留 DNS 劫持（nat ADGUARD/ADGUARD6）与进程守护。
#
# ---------------------------------------------------------------
# VPN 共存（vpn_compat，可在 config.prop 或 6081 管理页切换）
#   auto   默认。检测到 VPN / 代理的隧道接口（tun* / tap* / ppp* / utun* / wg* /
#          ipsec*，且必须是 UP 状态）时，自动把 DNS 劫持让路：ADGUARD 链清空成
#          只 RETURN，并把 -j ADGUARD 从 OUTPUT 摘掉，解析完全交给 VPN。
#          VPN 断开后 5 秒内自动恢复劫持。这是「不和 VPN 冲突」的默认行为。
#   proxy  串联共存。始终保留劫持，但「出接口是隧道」的查询、以及 VPN/代理应用
#          自身 uid 发出的查询直接 RETURN，不会被劫持 —— 避免 Clash/mihomo 自己的
#          DNS 被抢、避免 AGH→隧道→Clash DNS→AGH 的解析环。适合想让 AGH 继续
#          过滤 VPN 流量的场景。
#   off    不做任何 VPN 判断，全量劫持（老行为）。
#
# 另外两点防冲突设计：
#   1. 跳转改成「追加到 OUTPUT 末尾」而不是插到最前面。代理/VPN 自己插的
#      dport 53 规则（tproxy / REDIRECT）会在我们前面先命中，不会被我们抢。
#   2. 只操作自己的 ADGUARD / ADGUARD6 链，从不 flush、不删别的程序的规则。
# ---------------------------------------------------------------

# 老版 config.prop 里可能没有这些键，给默认值
[ -n "$vpn_compat" ] || vpn_compat=auto
[ -n "$vpn_apps" ] || vpn_apps=""

# ---------------------------------------------------------------
# redir_port 以 AGH 的 yaml 为准
# service.sh 每次启动会随机化 dns.port 并回写 config.prop；但只要 config.prop
# 被别处覆盖（比如手动推送、从模板恢复），REDIRECT 就会指向一个没人监听的端口，
# 结果是「DNS 全挂」——最隐蔽的故障。所以这里每次都以 yaml 为准校正一次。
# ---------------------------------------------------------------
YAML="$AGH_DIR/bin/AdGuardHome.yaml"
sync_redir_port() {
    [ -f "$YAML" ] || return 0
    _p=$(awk '/^dns:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$YAML" 2>/dev/null)
    case "$_p" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$_p" = "$redir_port" ] && return 0
    redir_port="$_p"
    sed -i "s/^redir_port=.*/redir_port=$_p/" "$AGH_DIR/scripts/config.prop" 2>/dev/null
    echo "$(date '+%F %T') [WARN] config.prop 的 redir_port 与 AGH 实际端口不一致，已校正为 $_p" >> "$MAIN_LOG"
}
sync_redir_port

# 常见 VPN / 代理客户端（proxy 模式下按包名查 uid 后豁免）
VPN_PKGS_DEFAULT="com.github.metacubex.clash.meta com.github.kr328.clash com.follow.clash \
com.nebula.clashmi com.getsurfboard com.v2ray.ang com.v2ray.ang.fdroid \
io.nekohasekai.sagernet com.hxtunnel.vpn com.netrino.v2rayapp dev.minios.tgwsproxy"

# 防止重复启动
# 单次模式：由 6081 管理页切 vpn_compat 后同步重建一次，立刻生效（不等守护循环的 5 秒）
ONCE=0
[ "$1" = "--once" ] && ONCE=1

# 已有守护在跑就退出（--once 例外，它就是要跟守护并存跑一次）
[ $ONCE -eq 0 ] && [ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

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

# ---------------------------------------------------------------
# VPN 探测
# ---------------------------------------------------------------
# 出接口是隧道就认为 VPN 在跑。
# 必须排除内核自带的 tunl0（名字是 tun+l0，不是 tun+数字），否则恒判有 VPN。
vpn_ifaces() {
    ip -o link show up 2>/dev/null | awk -F': ' '{
        n = $2
        sub(/@.*/, "", n)
        if (n ~ /^(tun|tap|ppp|utun|wg|ipsec)[0-9]+$/) printf "%s ", n
    }'
}

# 包名 → uid（/data/data 权限位最快，查不到再问 pm）
pkg_uid() {
    _u=$(stat -c %u "/data/data/$1" 2>/dev/null)
    case "$_u" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$_u"; return 0 ;;
    esac
    pm list packages -U 2>/dev/null \
        | sed -n "s/^package:$1 uid:\([0-9]*\).*/\1/p" | head -1
}

vpn_uids() {
    for _p in $VPN_PKGS_DEFAULT $vpn_apps; do
        _u=$(pkg_uid "$_p")
        case "$_u" in ''|*[!0-9]*) continue ;; esac
        printf '%s\n' "$_u"
    done | sort -u | tr '\n' ' '
}

# 同一条状态日志只写一次，避免 5 秒一条刷屏
VPN_LOG_STATE=""
log_vpn() {
    [ "$VPN_LOG_STATE" = "$1" ] && return 0
    VPN_LOG_STATE="$1"
    # 跨进程去重：管理页切模式的 `--once` 是另一个进程，VPN_LOG_STATE 从空开始，
    # 会跟守护进程写重同一行。日志最后一条内容相同就不再重复写。
    _last=$(tail -1 "$MAIN_LOG" 2>/dev/null)
    case "$_last" in
        *"$1"*) return 0 ;;
    esac
    echo "$(date '+%F %T') $1" >> "$MAIN_LOG"
}

# ---------------------------------------------------------------
# 跳转管理（追加到末尾，避免抢占代理自己的规则）
# ---------------------------------------------------------------
jump_present() {
    iptables -w 2 -t nat -C OUTPUT -j ADGUARD >/dev/null 2>&1
}

ensure_jump() {
    jump_present && return 0
    iptables -w 2 -t nat -A OUTPUT -j ADGUARD 2>/dev/null
}

drop_jump() {
    _n=0
    while [ "$_n" -lt 5 ] && jump_present; do
        iptables -w 2 -t nat -D OUTPUT -j ADGUARD 2>/dev/null || break
        _n=$((_n+1))
    done
}

# 当前是否应该做 DNS 劫持
expect_hijack() {
    case "$vpn_compat" in
        proxy|off) return 0 ;;
    esac
    [ -z "$(vpn_ifaces)" ]
}

# ---------------------------------------------------------------
# IPv6（部分内核没有 v6 nat 表，失败即跳过）
# ---------------------------------------------------------------
v6_present() {
    ip6tables -w 2 -t nat -L ADGUARD6 >/dev/null 2>&1
}

apply_rules6() {
    _yield="$1"
    v6_present || {
        ip6tables -w 2 -t nat -N ADGUARD6 2>/dev/null
        v6_present || return 0
    }
    ip6tables -w 2 -t nat -F ADGUARD6 2>/dev/null

    if [ "$_yield" = 1 ]; then
        ip6tables -w 2 -t nat -A ADGUARD6 -j RETURN 2>/dev/null
        _n=0
        while [ "$_n" -lt 5 ] && ip6tables -w 2 -t nat -C OUTPUT -j ADGUARD6 >/dev/null 2>&1; do
            ip6tables -w 2 -t nat -D OUTPUT -j ADGUARD6 2>/dev/null || break
            _n=$((_n+1))
        done
        return 0
    fi

    ip6tables -w 2 -t nat -A ADGUARD6 -m owner --uid-owner 9999 -j RETURN 2>/dev/null
    ip6tables -w 2 -t nat -A ADGUARD6 -m owner --uid-owner 0 -j RETURN 2>/dev/null
    if [ "$vpn_compat" = proxy ]; then
        ip6tables -w 2 -t nat -A ADGUARD6 -o lo -j RETURN 2>/dev/null
        for _o in tun tap ppp utun wg ipsec; do
            ip6tables -w 2 -t nat -A ADGUARD6 -o "${_o}+" -j RETURN 2>/dev/null
        done
        for _u in $(vpn_uids); do
            ip6tables -w 2 -t nat -A ADGUARD6 -m owner --uid-owner "$_u" -j RETURN 2>/dev/null
        done
    fi
    ip6tables -w 2 -t nat -A ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null
    ip6tables -w 2 -t nat -A ADGUARD6 -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null
    ip6tables -w 2 -t nat -C OUTPUT -j ADGUARD6 >/dev/null 2>&1 \
        || ip6tables -w 2 -t nat -A OUTPUT -j ADGUARD6 2>/dev/null
}

# ---------------------------------------------------------------
# 重建iptables规则
# ---------------------------------------------------------------
rebuild_rules_raw() {
    iptables -w 2 -t nat -L ADGUARD >/dev/null 2>&1 || iptables -w 2 -t nat -N ADGUARD
    iptables -w 2 -t nat -F ADGUARD

    _vifs=$(vpn_ifaces)
    _yield=0
    case "$vpn_compat" in
        proxy|off) _yield=0 ;;
        *)         [ -n "$_vifs" ] && _yield=1 ;;
    esac

    if [ "$_yield" = 1 ]; then
        # 让路：链清空成只 RETURN，并且把跳转从 OUTPUT 摘掉，
        # 这样代理/VPN 自己插的 dport 53 规则可以安安静静排第一位。
        iptables -w 2 -t nat -A ADGUARD -j RETURN
        drop_jump
        log_vpn "[INFO] 检测到 VPN 接口($_vifs)，DNS 劫持已让路（vpn_compat=auto），解析交给 VPN 自己处理"
        apply_rules6 1
        return 0
    fi

    # uid 0 (root) / uid 9999 (SmartDNS) 豁免: AGH/SmartDNS 自身出站查询不回环
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 9999 -j RETURN
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -j RETURN

    if [ "$vpn_compat" = proxy ]; then
        # 出接口是隧道的查询属于 VPN 自己，抢了会成环 / 打乱 fake-ip
        iptables -w 2 -t nat -A ADGUARD -o lo -j RETURN
        for _o in tun tap ppp utun wg ipsec; do
            iptables -w 2 -t nat -A ADGUARD -o "${_o}+" -j RETURN 2>/dev/null
        done
        for _u in $(vpn_uids); do
            iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner "$_u" -j RETURN 2>/dev/null
        done
        log_vpn "[INFO] vpn_compat=proxy：保留 DNS 劫持，已豁免隧道出流量${_vifs:+（当前 $_vifs）}与 VPN 应用自身的查询"
    else
        log_vpn "[INFO] vpn_compat=$vpn_compat：DNS 劫持已生效（未检测到 VPN 接口）"
    fi

    iptables -w 2 -t nat -A ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 2 -t nat -A ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port"
    ensure_jump

    apply_rules6 0
    # REDIRECT 规则即时生效，不需要开关飞行模式刷新网络。
}

# ---------------------------------------------------------------
# rebuild_rules 加锁包装
# 守护循环与 `--once`（管理页切模式）可能同时触发重建；先 -F 再逐条 -A，
# 两个进程交错执行会出现「REDIRECT 重复 2 条」的中间态。用 mkdir 原子锁串行化。
# ---------------------------------------------------------------
IPT_LOCK="$AGH_DIR/.ipt.lock"
rebuild_rules() {
    _n=0
    while ! mkdir "$IPT_LOCK" 2>/dev/null; do
        _n=$((_n + 1))
        # 持锁进程已死（或锁目录残留）：40×0.1s≈4s 后强拆
        [ $_n -ge 40 ] && rm -rf "$IPT_LOCK"
        sleep 0.1
    done
    rebuild_rules_raw
    rmdir "$IPT_LOCK" 2>/dev/null
    rm -rf "$IPT_LOCK" 2>/dev/null
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
last_vpnstate="__init__"

# --once：由 6081 管理页切换 vpn_compat 后同步重建一次就退出，不等守护循环的 5 秒
if [ $ONCE -eq 1 ]; then
    rebuild_rules
    exit 0
fi

while true; do
    . "$AGH_DIR/scripts/config.prop"
    [ -n "$vpn_compat" ] || vpn_compat=auto
    [ -n "$vpn_apps" ] || vpn_apps=""
    sync_redir_port
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

    # ---- 规则体检（按当前 VPN 状态判断「应该有什么」）----
    need_fix=0
    vnow=$(vpn_ifaces)
    if expect_hijack; then
        jump_present || need_fix=1
        iptables -w 2 -t nat -C ADGUARD -m owner --uid-owner 9999 -j RETURN 2>/dev/null || need_fix=1
        iptables -w 2 -t nat -C ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
        iptables -w 2 -t nat -C ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
    else
        # 已让路：跳转和 REDIRECT 都不该在
        jump_present && need_fix=1
        iptables -w 2 -t nat -C ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
        iptables -w 2 -t nat -C ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
    fi
    if v6_present; then
        if expect_hijack; then
            ip6tables -w 2 -t nat -C ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
        else
            ip6tables -w 2 -t nat -C ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
        fi
    fi

    # VPN 接口上下线、或 vpn_compat 被改，立刻重建（不等 AGH 状态变化）
    vpnstate="$vnow|$vpn_compat"
    [ "$vpnstate" != "$last_vpnstate" ] && need_fix=1

    [ $need_restart -eq 1 ] && start_agh
    cur_agh=0
    agh_running && cur_agh=1
    if [ $need_restart -eq 1 ] || [ $need_fix -eq 1 ] || [ "$cur_agh" != "$last_agh" ]; then
        rebuild_rules
        last_agh=$cur_agh
        last_vpnstate="$vpnstate"
    fi
    sleep 5
done &
