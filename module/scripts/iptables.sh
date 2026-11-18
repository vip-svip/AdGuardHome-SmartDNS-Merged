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

# dnsenc 的 bootstrap 明文上游（解析 DoH/DoT 主机名用）。必须选「系统 DNS 不会用」的地址：
# 它的豁免规则是 root + 该目的 IP + 53，如果这个 IP 同时出现在运营商下发的系统 DNS 里，
# netd（uid 0）的查询也会一起走豁免、绕过 AGH（历史 bug：曾用 223.5.5.5）。
DNSENC_BOOTSTRAP="180.184.1.1:53"
DNSENC_BOOTSTRAP_IP="${DNSENC_BOOTSTRAP%%:*}"

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
V6ONLY=0
[ "$1" = "--once" ] && ONCE=1
# --v6：只重建 IPv6 那套规则（v4 的 ADGUARD 链保持原样）。
# 切换 v6_dns 模式时绝不能顺手把 v4 劫持拆掉 —— 那几百毫秒 DNS 是裸奔的。
[ "$1" = "--v6" ] && V6ONLY=1

# 已有守护在跑就退出（--once / --v6 例外，它们就是要跟守护并存跑一次）
[ $ONCE -eq 0 ] && [ $V6ONLY -eq 0 ] && [ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

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

# 包名 → uid：先用 /data/data 的属主（最快），查不到再查 pm 缓存。
# 注意：早期实现是「每个包都跑一次 pm list packages -U」，在装了 20+ 个
# 代理类的机器上一次 vpn_uids 要 9 秒（pm 单次约 0.9s），直接把管理页
# 切模式卡到超时。现在 pm 只跑一次，结果落一个缓存文件复用。
PM_UID_CACHE="$AGH_DIR/.pm_uids"
pm_uid_cache() {
    _need=""
    [ -s "$PM_UID_CACHE" ] || _need=1
    # 装/卸应用会更新 packages.xml，比缓存新就让缓存失效
    if [ -z "$_need" ] && [ -f /data/system/packages.xml ] \
       && [ "$PM_UID_CACHE" -ot /data/system/packages.xml ]; then
        _need=1
    fi
    [ -n "$_need" ] || return 0
    pm list packages -U 2>/dev/null \
        | sed -n 's/^package:\([^ ]*\) uid:\([0-9]*\).*/\1 \2/p' > "$PM_UID_CACHE" 2>/dev/null
    [ -s "$PM_UID_CACHE" ] || rm -f "$PM_UID_CACHE" 2>/dev/null
    return 0
}

pkg_uid() {
    _u=$(stat -c %u "/data/data/$1" 2>/dev/null)
    case "$_u" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$_u"; return 0 ;;
    esac
    pm_uid_cache
    awk -v p="$1" '$1 == p { print $2; exit }' "$PM_UID_CACHE" 2>/dev/null
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
#
# 链用 A/B 两条轮换（ADGUARD / ADGUARDB）：
#   旧实现是 `-F ADGUARD` 再逐条 `-A`，从清空到最后一条 REDIRECT 补回
#   之间有大约 300ms 的空窗，这期间 dport 53 会直接放行（不过 AGH、不过
#   过滤）。改成「先在备用链里把整套规则建好，再用 -R 原子替换 OUTPUT
#   的跳转」，切换只占一次 iptables 调用的时间，空窗为 0。
# ---------------------------------------------------------------
V4_CHAINS="ADGUARD ADGUARDB"

# OUTPUT 当前跳到了哪条链（没有则输出空）
# 注意：必须用 -C 精确匹配，不能拿 `-S OUTPUT` 的字符串做前缀 case ——
# "ADGUARD" 是 "ADGUARDB" 的前缀，前缀匹配会永远返回 ADGUARD，
# 于是把「正在用的链」当成备用链去 -F，直接造成劫持空窗。
active_v4() {
    for _c in $V4_CHAINS; do
        [ -n "$_c" ] || continue
        iptables -w 2 -t nat -C OUTPUT -j "$_c" >/dev/null 2>&1 && { printf '%s' "$_c"; return 0; }
    done
    return 0
}

# 当前活动链的规则条数（没有跳转时按 ADGUARD 算）
v4_rules() {
    _c=$(active_v4)
    [ -n "$_c" ] || _c=ADGUARD
    iptables -w 2 -t nat -S "$_c" 2>/dev/null | grep -c '^-A'
}

jump_present() {
    [ -n "$(active_v4)" ]
}

# 把 OUTPUT 的 ADGUARD 跳转原子改到指定链；没有跳转就追加一条
swap_jump_to() {
    _t=$1
    _c=$(active_v4)
    [ "$_c" = "$_t" ] && return 0
    if [ -n "$_c" ]; then
        _n=$(iptables -w 2 -t nat -S OUTPUT 2>/dev/null | awk '
            /^-A / { c++; if ($0 ~ /-j ADGUARD$/ || $0 ~ /-j ADGUARDB$/) { print c; exit } }')
        if [ -n "$_n" ]; then
            if iptables -w 2 -t nat -R OUTPUT "$_n" -j "$_t" 2>/dev/null; then
                return 0
            fi
        fi
        # -R 失败（规则号算错之类）：退回先删后加
        drop_jump
    fi
    iptables -w 2 -t nat -A OUTPUT -j "$_t" 2>/dev/null
}

ensure_jump() {
    _t=$1
    [ -n "$_t" ] || _t=ADGUARD
    jump_present && [ "$(active_v4)" = "$_t" ] && return 0
    swap_jump_to "$_t"
}

# 删掉 OUTPUT 里指向我们任一链的跳转
drop_jump() {
    _n=0
    while [ "$_n" -lt 6 ]; do
        _hit=0
        for _c in $V4_CHAINS; do
            if iptables -w 2 -t nat -C OUTPUT -j "$_c" >/dev/null 2>&1; then
                if iptables -w 2 -t nat -D OUTPUT -j "$_c" 2>/dev/null; then
                    _hit=1
                fi
            fi
        done
        [ "$_hit" = 1 ] || break
        _n=$((_n+1))
    done
}

# 清掉「不是 keep」的那条链（切换完成后调用，此时它已无人引用）
drop_stale_v4() {
    _keep=$1
    _act=$(active_v4)
    for _c in $V4_CHAINS; do
        [ -z "$_c" ] && continue
        [ "$_c" = "$_keep" ] && continue
        # 安全阀：还在被 OUTPUT 引用就绝对不动，否则会出现
        # 「跳转指向一条被 -F 空了的链」= 劫持看着在、其实全放行
        [ "$_c" = "$_act" ] && continue
        iptables -w 2 -t nat -S "$_c" >/dev/null 2>&1 || continue
        iptables -w 2 -t nat -F "$_c" 2>/dev/null
        iptables -w 2 -t nat -X "$_c" 2>/dev/null
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

# ---------------------------------------------------------------
# 关于 v6 的历史包袱（保留说明，代码已删）
# 早期 auto 模式做过「实网自检」：装 drop → ping 验证 → 不行退回 keep。
# 实测这套自检不可靠：
#   1. 开机时解析栈还没预热，第一次 ping 必失败 → 误判成「只提供 v6 DNS」；
#   2. www.baidu.com 这类热域名走 DNS 缓存，drop 后仍能解析 → 误判成「可以 drop」；
#   3. 结果 keep / drop 来回横跳（日志里几秒钟翻一次）。
# 现在 auto 是确定性的：有 ip6tables nat 表就 redirect，没有就 drop。
# 真机 A/B 实测（24 域名 ping，keep / drop / auto 各 2 轮）全 0 失败，
# 说明本网络 drop 掉 v6:53 后 netd 会正常回落 v4 劫持链。
# 纯 v6 网络（无任何 v4 DNS 可用）请手动 v6_dns=keep。
# ---------------------------------------------------------------

# 实际生效的 v6 模式
# auto 的判定是确定性的：
#   有 nat 表 → redirect（v6 查询也进 AGH，最理想）
#   无 nat 表 → keep（不动 v6 DNS）
#
# 为什么没有 nat 表时不 drop：真机 A/B 实测，把 v6:53 丢掉之后 netd 并不会
# 可靠回落到 v4（系统 DNS 里 fe80::1%wlan0 排在前面），表现是"域名全解析不了"。
# 而且 DNS 缓存会把现场搞得很迷惑：切回 keep 解析恢复，再切回 drop 仍"正常"，
# 因为命中的是刚缓存下来的记录 —— 于是自检脚本永远得不到干净结论。
# 所以：拿不到 nat 表就不碰 v6，宁可不拦 v6 的广告，也不让整机解析挂掉。
# 想强行拦 v6 DNS 的用户可以手动 v6_dns=drop（自担解析失败风险）。
v6_effective() {
    case "$v6_dns" in
        keep|drop|redirect) printf '%s' "$v6_dns" ;;
        *)
            if v6nat_ok; then
                printf 'redirect'
            else
                printf 'keep'
            fi
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
    # ---- 第一步：把所有需要的信息先算出来，别夹在链操作中间 ----
    # （vpn_uids 要走 stat / pm 缓存，算它的时候链还是完好的）
    _vifs=$(vpn_ifaces)
    _yield=0
    case "$vpn_compat" in
        proxy|off) _yield=0 ;;
        *)         [ -n "$_vifs" ] && _yield=1 ;;
    esac
    _uids=""
    if [ "$_yield" = 0 ] && [ "$vpn_compat" = proxy ]; then
        _uids=$(vpn_uids)
    fi

    # ---- 第二步：在「当前没被引用」的那条链里把整套规则建好 ----
    _cur=$(active_v4)
    case "$_cur" in
        ADGUARD)  _new=ADGUARDB ;;
        ADGUARDB) _new=ADGUARD ;;
        *)        _new=ADGUARD ;;
    esac
    iptables -w 2 -t nat -L "$_new" >/dev/null 2>&1 || iptables -w 2 -t nat -N "$_new"
    iptables -w 2 -t nat -F "$_new"

    if [ "$_yield" = 1 ]; then
        # 让路：链里只留一条 RETURN，并且把跳转从 OUTPUT 摘掉，
        # 这样代理/VPN 自己插的 dport 53 规则可以安安静静排第一位。
        iptables -w 2 -t nat -A "$_new" -j RETURN
        drop_jump
        drop_stale_v4 "$_new"
        log_vpn "[INFO] 检测到 VPN 接口($_vifs)，DNS 劫持已让路（vpn_compat=auto），解析交给 VPN 自己处理"
        apply_v6 1
        return 0
    fi

    # uid 9999 (SmartDNS) 豁免：它的明文上游查询要直出，不能被自己劫持
    iptables -w 2 -t nat -A "$_new" -m owner --uid-owner 9999 -j RETURN
    # 回环豁免：本机解析器（127.0.0.1:53 之类）不出网，劫持它没有意义还会自环
    iptables -w 2 -t nat -A "$_new" -o lo -j RETURN
    # 精确豁免 dnsenc 的 bootstrap 查询：它用 root 身份问 $DNSENC_BOOTSTRAP 解析 DoH/DoT 主机名。
    # 目的地址必须挑一个「系统 DNS 不会用」的（这里 180.184.1.1）。早先用 223.5.5.5，
    # 结果运营商给的系统 DNS 里正好有 223.5.5.5，netd 的查询连同豁免一起绕过 AGH。
    iptables -w 2 -t nat -A "$_new" -m owner --uid-owner 0 -d "$DNSENC_BOOTSTRAP_IP" -p udp --dport 53 -j RETURN
    iptables -w 2 -t nat -A "$_new" -m owner --uid-owner 0 -d "$DNSENC_BOOTSTRAP_IP" -p tcp --dport 53 -j RETURN
    # 注意：不再有「uid 0 全豁免」。root 里除了 AGH/dnsenc，还有 netd ——
    # 系统解析器 dnsproxyd 就是 uid 0，全豁免等于让所有 App 的 DNS 绕过 AGH。
    if [ "$vpn_compat" = proxy ]; then
        # 出接口是隧道的查询属于 VPN 自己，抢了会成环 / 打乱 fake-ip
        for _o in tun tap ppp utun wg ipsec; do
            iptables -w 2 -t nat -A "$_new" -o "${_o}+" -j RETURN 2>/dev/null
        done
        for _u in $_uids; do
            iptables -w 2 -t nat -A "$_new" -m owner --uid-owner "$_u" -j RETURN 2>/dev/null
        done
        log_vpn "[INFO] vpn_compat=proxy：保留 DNS 劫持，已豁免隧道出流量${_vifs:+（当前 $_vifs）}与 VPN 应用自身的查询"
    else
        log_vpn "[INFO] vpn_compat=$vpn_compat：DNS 劫持已生效（未检测到 VPN 接口）"
    fi

    iptables -w 2 -t nat -A "$_new" -p udp --dport 53 -j REDIRECT --to-ports "$redir_port"
    iptables -w 2 -t nat -A "$_new" -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port"

    # ---- 第三步：原子切跳转，然后收掉旧链 ----
    swap_jump_to "$_new"
    drop_stale_v4 "$_new"

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
# --v6  ：只切 IPv6 模式时用，只碰 v6 的两套链，v4 链一律不动
if [ $ONCE -eq 1 ] || [ $V6ONLY -eq 1 ]; then
    if [ $V6ONLY -eq 1 ]; then
        . "$AGH_DIR/scripts/config.prop"
        [ -n "$vpn_compat" ] || vpn_compat=auto
        [ -n "$v6_dns" ] || v6_dns=auto
        _vifs=$(vpn_ifaces)
        _yield=0
        case "$vpn_compat" in
            proxy|off) _yield=0 ;;
            *)         [ -n "$_vifs" ] && _yield=1 ;;
        esac
        # 和 rebuild 共用同一把锁，避免与守护循环的 v6 重建交错
        _n=0
        while ! mkdir "$IPT_LOCK" 2>/dev/null; do
            _n=$((_n + 1))
            [ $_n -ge 40 ] && rm -rf "$IPT_LOCK"
            sleep 0.1
        done
        apply_v6 "$_yield"
        rmdir "$IPT_LOCK" 2>/dev/null
        rm -rf "$IPT_LOCK" 2>/dev/null
    else
        rebuild_rules
    fi
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
                    -bootstrap "$DNSENC_BOOTSTRAP" \
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
    # 链是 A/B 轮换的，体检必须看「当前活动的那一条」
    need_fix=0
    vnow=$(vpn_ifaces)
    V4C=$(active_v4)
    [ -n "$V4C" ] || V4C=ADGUARD
    if expect_hijack; then
        jump_present || need_fix=1
        iptables -w 2 -t nat -C "$V4C" -m owner --uid-owner 9999 -j RETURN 2>/dev/null || need_fix=1
        iptables -w 2 -t nat -C "$V4C" -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
        iptables -w 2 -t nat -C "$V4C" -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null || need_fix=1
    else
        # 已让路：跳转和 REDIRECT 都不该在
        jump_present && need_fix=1
        iptables -w 2 -t nat -C "$V4C" -p udp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
        iptables -w 2 -t nat -C "$V4C" -p tcp --dport 53 -j REDIRECT --to-ports "$redir_port" 2>/dev/null && need_fix=1
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

    # v6 auto 已改为确定性判定（见 v6_effective），网络变化由 vpnstate 里的
    # v6_effective 值驱动重建，不再跑 ping 自检，避免 keep/drop 反复横跳。

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

    # ---- 解析自愈看门狗 ----
    # 真机上偶尔会进入「链看着没问题、但系统解析全挂」的状态；实测把劫持链
    # 重建一次就恢复（换 Wi-Fi、AGH 重启、smartdns 重新绑定端口之后都可能出现）。
    # 每 12 轮（约 60 秒）探一次，连续 3 次失败（约 3 分钟）就强制重建一次，
    # 强制重建后仍不通就记 WARN 不再频繁动链（最多 10 分钟一次）。
    _tick=$((${_tick:-0} + 1))
    if [ $((_tick % 12)) -eq 0 ]; then
        if ping -c 1 -W 3 www.baidu.com >/dev/null 2>&1; then
            _dnsfail=0
        else
            _dnsfail=$((${_dnsfail:-0} + 1))
            if [ "$_dnsfail" -ge 3 ] && expect_hijack; then
                _now=$(date +%s)
                if [ $((${_lastheal:-0} + 600)) -le "$_now" ]; then
                    _lastheal=$_now
                    log_vpn "[WARN] 连续 $_dnsfail 次解析探测失败，强制重建 DNS 劫持链。"
                    rebuild_rules
                else
                    log_vpn "[WARN] 解析仍失败，距离上次自愈不足 10 分钟，暂不重建（请检查上游）。"
                fi
                _dnsfail=0
            fi
        fi
    fi

    sleep 5
done &
