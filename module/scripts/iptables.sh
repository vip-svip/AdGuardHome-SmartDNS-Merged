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
# IPv6 的 DNS 劫持
#
# 现实情况：相当多 Android 内核没编 ip6table_nat（ip6tables 报
# `can't initialize ip6tables table 'nat': Table does not exist`），
# 也没有可用的 xt_TPROXY（在 OUTPUT 里挂 TPROXY 直接 Invalid argument，
# 而 TPROXY 只对 PREROUTING 转发的流量有意义，AGH 自身也不做透明绑定），
# 所以 v6 不能照抄 v4 的 REDIRECT。这里给三条路，config.prop 的 v6_dns 控制：
#
#   auto     默认。nat 表可用就走 redirect；不可用自动退到 drop。
#   redirect ip6tables -t nat REDIRECT（先尝试 modprobe ip6table_nat）
#   drop     在自己的 mangle 链 AGH_V6DNS 里把去往 53 的连接丢掉。系统解析器
#            会自动回落到已被劫持的 v4 DNS（实测多花不到 1ms）。注意：只有
#            v6、没有任何 v4 DNS 的网络里这样会解析失败。
#   keep     完全不碰 v6。
#
# VPN 让路（vpn_compat=auto 且检测到隧道）时 v6 一并撤掉，交给 VPN。
# ---------------------------------------------------------------
[ -n "$v6_dns" ] || v6_dns=auto

ADG6_CHAIN="ADGUARD6"
V6M_CHAIN="AGH_V6DNS"
V6_LOG_STATE=""

v6_log() {
    [ "$V6_LOG_STATE" = "$1" ] && return 0
    V6_LOG_STATE="$1"
    _vlast=$(tail -1 "$MAIN_LOG" 2>/dev/null)
    case "$_vlast" in
        *"$1"*) return 0 ;;
    esac
    echo "$(date '+%F %T') $1" >> "$MAIN_LOG"
}

# v6 nat 表是否可用。顺带尝试加载内核模块，结果缓存，避免每轮都探测。
V6_NAT_OK=""
v6nat_ok() {
    case "$V6_NAT_OK" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    V6_NAT_OK=0
    if ! ip6tables -w 2 -t nat -L -n >/dev/null 2>&1; then
        for _m in ip6table_nat nf_nat_ipv6 xt_nat; do
            modprobe "$_m" 2>/dev/null
        done
    fi
    ip6tables -w 2 -t nat -L -n >/dev/null 2>&1 && V6_NAT_OK=1
    [ "$V6_NAT_OK" = 1 ]
}

# 实际生效的 v6 模式
v6_effective() {
    case "$v6_dns" in
        keep|drop|redirect) printf '%s' "$v6_dns" ;;
        *)
            if v6nat_ok; then printf 'redirect'; else printf 'drop'; fi
            ;;
    esac
}

v6_present() {
    ip6tables -w 2 -t nat -L "$ADG6_CHAIN" >/dev/null 2>&1
}

v6m_present() {
    ip6tables -w 2 -t mangle -L "$V6M_CHAIN" >/dev/null 2>&1
}

v6m_jumped() {
    ip6tables -w 2 -t mangle -C OUTPUT -j "$V6M_CHAIN" >/dev/null 2>&1
}

v6m_unjump() {
    _n=0
    while [ "$_n" -lt 5 ] && v6m_jumped; do
        ip6tables -w 2 -t mangle -D OUTPUT -j "$V6M_CHAIN" 2>/dev/null || break
        _n=$((_n+1))
    done
}

v6nat_unjump() {
    _n=0
    while [ "$_n" -lt 5 ] && ip6tables -w 2 -t nat -C OUTPUT -j "$ADG6_CHAIN" >/dev/null 2>&1; do
        ip6tables -w 2 -t nat -D OUTPUT -j "$ADG6_CHAIN" 2>/dev/null || break
        _n=$((_n+1))
    done
}

# 撤掉两套 v6 规则（换模式 / 让路 / 关掉都要先清）
v6_cleanup() {
    v6m_unjump
    if v6m_present; then
        ip6tables -w 2 -t mangle -F "$V6M_CHAIN" 2>/dev/null
        ip6tables -w 2 -t mangle -X "$V6M_CHAIN" 2>/dev/null
    fi
    if v6_present; then
        v6nat_unjump
        ip6tables -w 2 -t nat -F "$ADG6_CHAIN" 2>/dev/null
        ip6tables -w 2 -t nat -X "$ADG6_CHAIN" 2>/dev/null
    fi
}

# 和 v4 一致的豁免：SmartDNS（uid 9999）+ 回环，proxy 模式下再加隧道出接口
# 与 VPN 应用 uid，避免把 VPN 自己的 DNS 也吞掉。
# 不再豁免 uid 0：netd 就是 uid 0，豁免它等于让系统解析器绕过 AGH。
v6_exempt() {
    ip6tables -w 2 "$@" -m owner --uid-owner 9999 -j RETURN 2>/dev/null
    ip6tables -w 2 "$@" -o lo -j RETURN 2>/dev/null
    [ "$vpn_compat" = proxy ] || return 0
    for _o in tun tap ppp utun wg ipsec; do
        ip6tables -w 2 "$@" -o "${_o}+" -j RETURN 2>/dev/null
    done
    for _u in $(vpn_uids); do
        ip6tables -w 2 "$@" -m owner --uid-owner "$_u" -j RETURN 2>/dev/null
    done
}

# apply_v6 <yield>：yield=1 表示 VPN 在接管，v6 一律撤掉
apply_v6() {
    _yield="$1"
    _mode=$(v6_effective)
    v6_cleanup

    if [ "$_yield" = 1 ]; then
        v6_log "[INFO] IPv6：VPN 已在接管，v6 DNS 不劫持"
        return 0
    fi

    if [ "$_mode" = redirect ]; then
        ip6tables -w 2 -t nat -N "$ADG6_CHAIN" 2>/dev/null
        if v6_present; then
            v6_exempt -t nat -A "$ADG6_CHAIN"
            ip6tables -w 2 -t nat -A "$ADG6_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null
            ip6tables -w 2 -t nat -A "$ADG6_CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null
            ip6tables -w 2 -t nat -A OUTPUT -j "$ADG6_CHAIN" 2>/dev/null
            v6_log "[INFO] IPv6：nat REDIRECT 劫持 v6 DNS -> $redir_port"
            return 0
        fi
        v6_log "[WARN] IPv6：nat 表不可用（Table does not exist），自动改走 drop"
        _mode=drop
    fi

    if [ "$_mode" = drop ]; then
        ip6tables -w 2 -t mangle -N "$V6M_CHAIN" 2>/dev/null
        if v6m_present; then
            v6_exempt -t mangle -A "$V6M_CHAIN"
            ip6tables -w 2 -t mangle -A "$V6M_CHAIN" -p udp --dport 53 -j DROP 2>/dev/null
            ip6tables -w 2 -t mangle -A "$V6M_CHAIN" -p tcp --dport 53 -j DROP 2>/dev/null
            ip6tables -w 2 -t mangle -A OUTPUT -j "$V6M_CHAIN" 2>/dev/null
            v6_log "[INFO] IPv6：内核无 nat 表，改用 mangle 丢弃 v6 DNS（系统回落 v4 劫持链）"
        else
            v6_log "[WARN] IPv6：mangle 表也不可用，v6 DNS 未做处理"
        fi
        return 0
    fi
    # keep：什么都不做
}

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
        apply_v6 1
        return 0
    fi

    # uid 9999 (SmartDNS) 豁免：它的明文上游查询要直出，不能被自己劫持
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 9999 -j RETURN
    # 回环豁免：本机解析器（127.0.0.1:53 之类）不出网，劫持它没有意义还会自环
    iptables -w 2 -t nat -A ADGUARD -o lo -j RETURN
    # 精确豁免 dnsenc 的 bootstrap 查询（root 身份问 223.5.5.5:53 解析 DoH 主机名）
    # 只放 root + 该目的地址 + 53 端口，普通 App 查 223.5.5.5 依旧被劫持
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -d 223.5.5.5 -p udp --dport 53 -j RETURN
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -d 223.5.5.5 -p tcp --dport 53 -j RETURN
    # 注意：不再有「uid 0 全豁免」。root 里除了 AGH/dnsenc，还有 netd ——
    # 系统解析器 dnsproxyd 就是 uid 0，全豁免等于让所有 App 的 DNS 绕过 AGH。
    if [ "$vpn_compat" = proxy ]; then
        # 出接口是隧道的查询属于 VPN 自己，抢了会成环 / 打乱 fake-ip
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

    apply_v6 0
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
    [ -n "$v6_dns" ] || v6_dns=auto
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
    _vmode=$(v6_effective)
    if [ "$_vmode" = drop ]; then
        if expect_hijack; then
            v6m_jumped || need_fix=1
        else
            v6m_jumped && need_fix=1
        fi
    elif [ "$_vmode" = redirect ] && v6_present; then
        if expect_hijack; then
            ip6tables -w 2 -t nat -C "$ADG6_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
        else
            ip6tables -w 2 -t nat -C "$ADG6_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
        fi
    fi

    # VPN 接口上下线、或 vpn_compat 被改，立刻重建（不等 AGH 状态变化）
    vpnstate="$vnow|$vpn_compat|$(v6_effective)"
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
