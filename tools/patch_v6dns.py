import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\iptables.sh"
s = io.open(P, encoding="utf-8").read()

NEW = '''# ---------------------------------------------------------------
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

# 和 v4 一致的豁免：AGH/SmartDNS 自身（uid 9999 / 0），proxy 模式下再加
# 隧道出接口与 VPN 应用 uid，避免把 VPN 自己的 DNS 也吞掉。
v6_exempt() {
    ip6tables -w 2 "$@" -m owner --uid-owner 9999 -j RETURN 2>/dev/null
    ip6tables -w 2 "$@" -m owner --uid-owner 0 -j RETURN 2>/dev/null
    [ "$vpn_compat" = proxy ] || return 0
    ip6tables -w 2 "$@" -o lo -j RETURN 2>/dev/null
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

'''

a = s.index("v6_present() {")
b = s.rindex("# ---------------------------------------------------------------\n", 0, a)
b = s.rindex("# ---------------------------------------------------------------\n", 0, b)
c = s.index("rebuild_rules_raw() {")

s2 = s[:b] + NEW + s[c:]

# 调用点改名
n1 = s2.count("apply_rules6 1")
n2 = s2.count("apply_rules6 0")
s2 = s2.replace("apply_rules6 1", "apply_v6 1").replace("apply_rules6 0", "apply_v6 0")

# need_fix 的 v6 判定改成模式感知
OLD_CHECK = '''    if v6_present; then
        if expect_hijack; then
            ip6tables -w 2 -t nat -C ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
        else
            ip6tables -w 2 -t nat -C ADGUARD6 -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
        fi
    fi
'''
NEW_CHECK = '''    _vmode=$(v6_effective)
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
'''
assert OLD_CHECK in s2, "need_fix 段没匹配到"
s2 = s2.replace(OLD_CHECK, NEW_CHECK)

# 模式变化也要触发重建
OLD_STATE = 'vpnstate="$vnow|$vpn_compat"'
NEW_STATE = 'vpnstate="$vnow|$vpn_compat|$(v6_effective)"'
assert OLD_STATE in s2
s2 = s2.replace(OLD_STATE, NEW_STATE)

# 守护循环每轮重新 source 时要带上 v6_dns 的兜底
OLD_DEF = '''    [ -n "$vpn_apps" ] || vpn_apps=""
    sync_redir_port'''
NEW_DEF = '''    [ -n "$vpn_apps" ] || vpn_apps=""
    [ -n "$v6_dns" ] || v6_dns=auto
    sync_redir_port'''
assert OLD_DEF in s2
s2 = s2.replace(OLD_DEF, NEW_DEF)

io.open(P, "w", encoding="utf-8", newline="\n").write(s2)
print("apply_rules6 调用点替换:", n1, n2)
print("新大小:", len(s.encode()), "->", len(s2.encode()))

import hashlib
print("md5:", hashlib.md5(s2.encode()).hexdigest())
io.open(r"F:\BUG\_ipt_new.sh", "w", encoding="utf-8", newline="\n").write(s2)