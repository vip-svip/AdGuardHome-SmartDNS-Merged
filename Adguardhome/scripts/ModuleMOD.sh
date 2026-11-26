#!/system/bin/sh
SCRIPTS_DIR="/data/adb/agh/scripts"
MOD_PATH=${MODPATH:-/data/adb/modules/AdGuardHome}
LAST_LOCALE="INIT"

# 防止重复启动
[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

DESC_ZH='[20261125] AdGuard Home 20261119 + SmartDNS 48.5-RC1。本轮重点：多手机兼容。①ROM/内核差异兜底：iptables 的 -w 参数先探测再决定用不用（老 1.4.x 带 -w 会整链建不起来）、pgrep/netstat/ss/mountpoint/setsid/dirname/basename 缺失时全部有纯 shell 或 /proc 兜底、busybox 多路径探测、curl 缺失则跳过联网自愈、TZ 未设置时从 persist.sys.timezone 补齐（日志不再是 UTC）、非 arm64 设备直接给出明确 ABIs 不匹配提示而不是静默失败。②单实例竞态修复：service.sh 与 iptables.sh 的守护循环都会「检测不到 AGH 就拉起」，开机瞬间可能起两个实例抢端口；现在两边共用 .agh.start.lock 原子锁，实测并发启动后只有 1 个实例。③启动可靠性：AGH 若因会话库打开超时退出，自动清 data/sessions.db* 后重启；SmartDNS 以「6053 真的在监听」为启动判据，进程活着但不监听会自动重启；过滤器自愈改成先轮询 AGH API 就绪（首次启动曾因路由未注册拿到 404 而空转）、刷新失败自动重试。④IPv6：v6_dns=auto 是确定性的——内核有 ip6tables nat 表就走 nat REDIRECT，没有就 keep（完全不碰 v6 DNS）。为什么没有 nat 表时不 drop：真机实测丢 v6:53 后 netd 不会可靠回落 v4，整机解析会挂；要强行拦 v6 请手动 v6_dns=drop。⑤DNS 劫持不再全豁免 uid 0（netd/dnsproxyd 就是 uid 0，全豁免等于系统 DNS 绕过 AGH），只精确豁免 dnsenc 的 bootstrap 解析（119.28.28.28:53）。另有：VPN 共存 auto/proxy/off、内置拦截列表（ABP 语法，168574 域名，不联网也能拦）、加密上游 DoH·DoH3·DoT·DoQ·DNSCrypt、按域名分流、卸载快照可恢复（AGH 40251 · smartdns 6080 · 上游管理 6081）⑥开机不再卡顿：root 实现会等 service.sh 退出才走 late_start，原来脚本里的过滤器自愈（curl 最长 9 分钟）、smartdns 健康检查、iptables 的 pm 查询全在开机关键路径上。现在 service.sh 立刻把整套启动甩到 setsid 后台并 0 秒退出，等 sys.boot_completed=1 后再等 12 秒才真正启动，实测冷启动 62 秒完成、模块随后自行起来。⑦延迟与无效功能清理：加密上游改成 IP 直连 DoH（223.5.5.5 / 1.12.12.12），不再需要解析主机名，也就不再被 bootstrap 拖慢（域名式 DoH + 旧 bootstrap 首查 6386ms，IP 直连 180-314ms）；bootstrap 统一为 119.28.28.28:53 且三处必须一致（service.sh / iptables.sh / yaml），否则豁免规则对不上会形成 nat 环；dnsenc 守护加参数漂移自愈（比对 /proc/<pid>/cmdline，不一致就重启），修掉「改了配置但守护里还跑旧参数」与「两条启动路径抢 6054」两个真事故；删掉 yaml 从未引用过、只会显示成 rules=0 的三个空规则文件（反诈规则本来就在 user_rules 里）；adblock.conf 从 727B 纯注释改成 25 条私有网段 PTR 本地秒回；上游管理页去掉全部写死的假延迟数字。实测 AGH 自身 elapsedMs 中位 0.5ms / p90 2.8ms，热查 4-6ms，冷查 0.1-1.2s 全部来自上游 ISP 递归对生僻域名的首次解析（cross A/B 证明与配置无关）。⑧SNI 拦截内置于 AdGuard Home（fork 内置 snifilter，思路源自 nora-adblock，作者桉桉）：仪表盘 DNS 设置页有独立开关，开启后模块脚本在 filter OUTPUT 挂 AGH_SNI NFQUEUE 链（443/8443，queue 7，--queue-bypass fail-open），解析 TLS ClientHello 的 SNI 命中过滤列表即 RST 断流，与 DNS 层共用同一份名单；ECH 加密 SNI 与 QUIC/HTTP3 不可见。'
DESC_EN='[20261125] AdGuard Home + SmartDNS 48.5-RC1. Multi-ROM compatibility: iptables -w probing, shell/PROC fallbacks for missing pgrep/netstat/setsid, single-instance lock, session-db self-heal, port-based SmartDNS liveness, deterministic IPv6 auto (nat REDIRECT when the kernel has ip6tables nat, otherwise keep), no blanket uid-0 DNS bypass, async service.sh so boot never blocks. Low latency: encrypted upstreams switched to IP-direct DoH so no bootstrap lookup (6386ms -> 180-314ms), bootstrap unified to 119.28.28.28 in all three places, dnsenc drift self-heal, dead rule files removed, private-range PTR answered locally. (8) SNI (TLS/HTTP) filtering built into AdGuard Home (fork snifilter, idea from nora-adblock, author 桉桉): a standalone switch in the dashboard DNS settings page (control/sni/status|set) turns it on; the module script then installs the AGH_SNI NFQUEUE chain on filter OUTPUT (ports 443/8443, queue 7, --queue-bypass fail-open); the TLS ClientHello SNI is matched against the filter lists and blocked connections are reset; shares one blocklist with the DNS layer. Limits: ECH-encrypted SNI and QUIC/HTTP3 are invisible.'
ESC_EN="[20261125] AdGuard Home 20261119 + SmartDNS 48.5-RC1. Focus of this round: running on more phones. (1) ROM/kernel differences are probed instead of assumed: iptables gets -w only when the local xtables accepts it (old 1.4.x rejects -w and the whole chain fails to build); pgrep/netstat/ss/mountpoint/setsid/dirname/basename each fall back to pure-shell or /proc implementations; busybox is looked up on several paths; missing curl only disables the online self-heal; TZ is filled from persist.sys.timezone so logs stop being UTC; non-arm64 devices get an explicit ABIs mismatch message instead of failing silently. (2) Single-instance race fixed: both service.sh and the iptables.sh daemon start AdGuardHome when they cannot find it, so a boot could end up with two instances fighting for the port; both now share the .agh.start.lock mkdir lock (verified: concurrent start still leaves exactly one instance). (3) Startup reliability: AGH restarts after clearing data/sessions.db* when it died on a session-storage timeout; SmartDNS counts as started only when 127.0.0.1:6053 is really listening (a live process that is not listening gets restarted); the filter self-heal now polls the AGH API until it is ready (a first boot used to get 404 while routes were still being registered) and retries a failed refresh. (4) IPv6: with v6_dns=auto, keep is used when the kernel has no ip6tables nat table - dropping v6 DNS makes netd fail to fall back to v4 and breaks resolution machine-wide - and REDIRECT is used when the nat table does exist; drop stays available for people who verified they have working v4 resolvers. (5) The DNS hijack no longer exempts uid 0 wholesale (netd/dnsproxyd runs as uid 0, so that exemption meant the system resolver bypassed AGH); only dnsenc's bootstrap lookups to 180.184.1.1:53 are exempted. Also included: vpn_compat auto/proxy/off, a bundled ABP blocklist (168,574 domains, works offline), encrypted upstreams (DoH/DoH3/DoT/DoQ/DNSCrypt), per-domain routing, restorable uninstall snapshot (AGH 40251 / smartdns 6080 / upstream manager 6081)(6) Boot no longer hangs: the root implementation waits for service.sh to exit before it continues late_start, and the old script did the filter self-heal (up to 9 minutes of curl), the smartdns health check and iptables' pm lookup right on that critical path. service.sh now hands the whole startup off to a detached setsid child and exits in 0 s, then waits for sys.boot_completed=1 plus 12 more seconds before actually starting anything -- measured 62 s cold boot with the module auto-starting afterwards. (8) SNI (TLS/HTTP) filtering built into AdGuard Home (fork snifilter, idea from nora-adblock, author 桉桉): a standalone switch in the dashboard DNS settings page (control/sni/status|set) turns it on; the module script then installs the AGH_SNI NFQUEUE chain on filter OUTPUT (ports 443/8443, queue 7, --queue-bypass fail-open); the TLS ClientHello SNI is matched against the filter lists and blocked connections are reset; shares one blocklist with the DNS layer. Limits: ECH-encrypted SNI and QUIC/HTTP3 are invisible."

write_prop() {
    [ -f "$MOD_PATH/module.prop" ] || return 0
    grep -v '^author=' "$MOD_PATH/module.prop" | grep -v '^description=' > "$MOD_PATH/module.prop.tmp" 2>/dev/null
    {
        cat "$MOD_PATH/module.prop.tmp" 2>/dev/null
        echo "author=$1"
        echo "description=$2"
    } > "$MOD_PATH/module.prop.new" 2>/dev/null
    cat "$MOD_PATH/module.prop.new" > "$MOD_PATH/module.prop" 2>/dev/null
    rm -f "$MOD_PATH/module.prop.tmp" "$MOD_PATH/module.prop.new" 2>/dev/null
    return 0
}

# 语言检测：语言变更时更新模块说明

# --- root 保活：守护/AGH 缺失即拉起（复用本进程，不新增守护进程） ---
echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
# 只在「真正的主守护」存在时才算活着；--v6selftest/--once/--source-only 都是临时进程，不能算
_daemon_pid() {
    for _p in /proc/[0-9]*; do
        _c=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) || continue
        case "$_c" in
            *--v6selftest*|*--once*|*--source-only*|*_monitor*) continue ;;
            *scripts/iptables.sh*) echo "${_p#/proc/}"; return 0 ;;
        esac
    done
    return 1
}

# 单实例：只允许一个 ModuleMOD 在跑（否则每次开机多一个，两个循环同时改描述/拉守护）
MM_PIDF=/data/adb/agh/.modulemod.pid
MM_LOCK=/data/adb/agh/.modulemod.lock
# 原子锁：set -C（noclobber）保证并发启动时只有一个能建文件
if ! ( set -C; echo $$ > "$MM_LOCK" ) 2>/dev/null; then
    _lp=$(cat "$MM_LOCK" 2>/dev/null)
    if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && [ -d "/proc/$_lp" ]; then
        echo "[INFO] ModuleMOD 已在运行(pid=$_lp)，本次退出。"
        exit 0
    fi
    rm -f "$MM_LOCK"
    ( set -C; echo $$ > "$MM_LOCK" ) 2>/dev/null || exit 0
fi
echo $$ > "$MM_PIDF"
_sweep_self
trap 'rm -f "$MM_LOCK"' EXIT
# 启动即清扫同名的其它实例（历史版本没有锁，可能残留多个）
_sweep_self() {
    for _p in /proc/[0-9]*; do
        _pid=${_p#/proc/}
        [ "$_pid" = "$$" ] && continue
        _c=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) || continue
        echo "$_c" | grep -q 'ModuleMOD\.sh' && kill -9 "$_pid" 2>/dev/null
    done
}
_keep_alive() {
    _d=$(_daemon_pid)
    if [ -z "$_d" ]; then
        setsid sh /data/adb/agh/scripts/iptables.sh </dev/null >/dev/null 2>&1 &
    fi
    _a=$(pidof AdGuardHome 2>/dev/null | awk '{print $1}')
    if [ -n "$_a" ]; then
        echo -1000 > /proc/$_a/oom_score_adj 2>/dev/null
    fi
    [ -n "$_d" ] && echo -1000 > /proc/$_d/oom_score_adj 2>/dev/null
}
while true; do
    _keep_alive
    CURRENT_LOCALE=$(getprop persist.sys.locale)
    [ -z "$CURRENT_LOCALE" ] && CURRENT_LOCALE="zh"
    if [ "$LAST_LOCALE" = "INIT" ] || [ "$LAST_LOCALE" != "$CURRENT_LOCALE" ]; then
        case "$CURRENT_LOCALE" in
            zh*) write_prop "vip-svip" "$DESC_ZH" ;;
            *)   write_prop "ChunmengWuhen" "$DESC_EN" ;;
        esac
        LAST_LOCALE="$CURRENT_LOCALE"
    fi
    # 延迟启动
    sleep 5
done