#!/system/bin/sh
SCRIPTS_DIR="/data/adb/agh/scripts"
MOD_PATH=${MODPATH:-/data/adb/modules/AdGuardHome}
LAST_LOCALE="INIT"

# 防止重复启动
[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

DESC_ZH="[20261117] AdGuard Home 20261117 + SmartDNS 48.5-RC1。本次三件事：① 去掉导入规则的大小限制——AGH 原来把请求体卡在 64KiB（导入用户规则是 4MiB），现在完全不限，几十万条的规则表、大 client 列表都能直接导入/粘贴；查看规则文件的上限也从 4MiB 提到 64MiB。② 补上 IPv6 的 DNS 劫持：原来 ip6tables 没有 nat 表（Table does not exist）、TPROXY 在 OUTPUT 也不可用，运营商的 v6 DNS（2408:8888::8 之类）直接绕过过滤。现在 config.prop 新增 v6_dns=auto/redirect/drop/keep：auto 默认先尝试 modprobe ip6table_nat 用 nat REDIRECT，内核没有 nat 表就自动退到 mangle 丢弃 v6:53，系统解析器会回落到已被劫持的 v4 DNS（实测多花不到 1ms），规则放在自己的 AGH_V6DNS 链里、proxy 模式下同样豁免隧道出流量与 VPN 应用 uid，vpn_compat=auto 让路时 v6 一并撤掉。③ 版本号改成纯日期，不再带 v31 这种序号。另有：VPN 共存三模式（auto 让路 / proxy 串联 / off）、加密上游 DoH·DoH3·DoT·DoQ·DNSCrypt、按域名分流、过滤器自愈、卸载快照可恢复（AGH 40251 · smartdns 6080 · 上游管理 6081）④ 修掉一个更严重的旧 bug：原先 iptables 里有一条「uid 0 全豁免」，而 Android 的系统解析器 dnsproxyd 就跑在 netd（uid 0）里，等于所有 App 的 DNS 全部绕过 AGH。现在只豁免 SmartDNS(uid 9999)、回环(-o lo) 和 dnsenc 的 bootstrap(root 仅 180.184.1.1:53)，其余一律劫持 —— 实测改完后 AGH 立刻能看到真实客户端与真实域名查询，广告域名在系统层面被拦。"
DESC_EN="[20261117] AdGuard Home 20261117 + SmartDNS 48.5-RC1. Three things this round: (1) rule import is no longer size-limited -- AGH used to cap request bodies at 64 KiB (4 MiB for user-rule imports), which is now removed entirely, so multi-hundred-thousand-line lists and large client lists import/paste fine; the rule-file viewer cap also went from 4 MiB to 64 MiB. (2) IPv6 DNS hijacking is now covered: this kernel has no ip6tables nat table (Table does not exist) and TPROXY is unusable in OUTPUT, so carrier IPv6 resolvers (2408:8888::8 and friends) bypassed filtering. config.prop gained v6_dns=auto/redirect/drop/keep: auto tries modprobe ip6table_nat and uses a nat REDIRECT, and falls back to dropping v6:53 from our own AGH_V6DNS chain in mangle when the kernel has no nat table -- the system resolver then falls back to the already-hijacked v4 path (measured under 1 ms extra). The drop rules exempt tunnel egress and VPN app uids in proxy mode, and are removed entirely when vpn_compat=auto yields. (3) The version string is now a plain date instead of a v31-style counter. Also included: vpn_compat auto/proxy/off, encrypted upstreams (DoH/DoH3/DoT/DoQ/DNSCrypt), per-domain routing, filter self-heal, restorable uninstall snapshot (AGH 40251 / smartdns 6080 / upstream mgr 6081) (4) Fixed a serious old bug: the nat chain had a blanket "uid 0" exemption, and Android's resolver (dnsproxyd) runs inside netd, which is uid 0 -- so every app DNS query bypassed AGH. Now only SmartDNS (uid 9999), loopback (-o lo) and the dnsenc bootstrap (root, 180.184.1.1:53 only) are exempt; everything else is hijacked. Verified: AGH now sees real clients and real queries, and ad domains are blocked at the system resolver level."

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