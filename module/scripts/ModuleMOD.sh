#!/system/bin/sh
SCRIPTS_DIR="/data/adb/agh/scripts"
MOD_PATH=${MODPATH:-/data/adb/modules/AdGuardHome}
LAST_LOCALE="INIT"

# 防止重复启动
[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

DESC_ZH="[20261119] AdGuard Home 20261119 + SmartDNS 48.5-RC1。本轮重点：多手机兼容。①ROM/内核差异兜底：iptables 的 -w 参数先探测再决定用不用（老 1.4.x 带 -w 会整链建不起来）、pgrep/netstat/ss/mountpoint/setsid/dirname/basename 缺失时全部有纯 shell 或 /proc 兜底、busybox 多路径探测、curl 缺失则跳过联网自愈、TZ 未设置时从 persist.sys.timezone 补齐（日志不再是 UTC）、非 arm64 设备直接给出明确 ABIs 不匹配提示而不是静默失败。②单实例竞态修复：service.sh 与 iptables.sh 的守护循环都会「检测不到 AGH 就拉起」，开机瞬间可能起两个实例抢端口；现在两边共用 .agh.start.lock 原子锁，实测并发启动后只有 1 个实例。③启动可靠性：AGH 若因会话库打开超时退出，自动清 data/sessions.db* 后重启；SmartDNS 以「6053 真的在监听」为启动判据，进程活着但不监听会自动重启；过滤器自愈改成先轮询 AGH API 就绪（首次启动曾因路由未注册拿到 404 而空转）、刷新失败自动重试。④IPv6：v6_dns=auto 时先试 nat REDIRECT，内核没有 ip6tables nat 表就退回 mangle 丢弃 v6:53，并且会自测一次——丢完 ping 得通就保持 drop，ping 不通立刻自动改回 keep（有些网络只给 v6 DNS，丢了整机解析就挂）。⑤DNS 劫持不再全豁免 uid 0（netd/dnsproxyd 就是 uid 0，全豁免等于系统 DNS 绕过 AGH），只精确豁免 dnsenc 的 bootstrap 解析（180.184.1.1:53）。另有：VPN 共存 auto/proxy/off、内置拦截列表（ABP 语法，168574 域名，不联网也能拦）、加密上游 DoH·DoH3·DoT·DoQ·DNSCrypt、按域名分流、卸载快照可恢复（AGH 40251 · smartdns 6080 · 上游管理 6081）⑥开机不再卡顿：root 实现会等 service.sh 退出才走 late_start，原来脚本里的过滤器自愈（curl 最长 9 分钟）、smartdns 健康检查、iptables 的 pm 查询全在开机关键路径上。现在 service.sh 立刻把整套启动甩到 setsid 后台并 0 秒退出，等 sys.boot_completed=1 后再等 12 秒才真正启动，实测冷启动 62 秒完成、模块随后自行起来。"
DESC_EN="[20261119] AdGuard Home 20261119 + SmartDNS 48.5-RC1. Focus of this round: running on more phones. (1) ROM/kernel differences are probed instead of assumed: iptables gets -w only when the local xtables accepts it (old 1.4.x rejects -w and the whole chain fails to build); pgrep/netstat/ss/mountpoint/setsid/dirname/basename each fall back to pure-shell or /proc implementations; busybox is looked up on several paths; missing curl only disables the online self-heal; TZ is filled from persist.sys.timezone so logs stop being UTC; non-arm64 devices get an explicit ABIs mismatch message instead of failing silently. (2) Single-instance race fixed: both service.sh and the iptables.sh daemon start AdGuardHome when they cannot find it, so a boot could end up with two instances fighting for the port; both now share the .agh.start.lock mkdir lock (verified: concurrent start still leaves exactly one instance). (3) Startup reliability: AGH restarts after clearing data/sessions.db* when it died on a session-storage timeout; SmartDNS counts as started only when 127.0.0.1:6053 is really listening (a live process that is not listening gets restarted); the filter self-heal now polls the AGH API until it is ready (a first boot used to get 404 while routes were still being registered) and retries a failed refresh. (4) IPv6: with v6_dns=auto, keep is used when the kernel has no ip6tables nat table - dropping v6 DNS makes netd fail to fall back to v4 and breaks resolution machine-wide - and REDIRECT is used when the nat table does exist; drop stays available for people who verified they have working v4 resolvers. (5) The DNS hijack no longer exempts uid 0 wholesale (netd/dnsproxyd runs as uid 0, so that exemption meant the system resolver bypassed AGH); only dnsenc's bootstrap lookups to 180.184.1.1:53 are exempted. Also included: vpn_compat auto/proxy/off, a bundled ABP blocklist (168,574 domains, works offline), encrypted upstreams (DoH/DoH3/DoT/DoQ/DNSCrypt), per-domain routing, restorable uninstall snapshot (AGH 40251 / smartdns 6080 / upstream manager 6081)(6) Boot no longer hangs: the root implementation waits for service.sh to exit before it continues late_start, and the old script did the filter self-heal (up to 9 minutes of curl), the smartdns health check and iptables' pm lookup right on that critical path. service.sh now hands the whole startup off to a detached setsid child and exits in 0 s, then waits for sys.boot_completed=1 plus 12 more seconds before actually starting anything -- measured 62 s cold boot with the module auto-starting afterwards."

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
while true; do
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