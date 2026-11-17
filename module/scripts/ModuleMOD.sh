#!/system/bin/sh
SCRIPTS_DIR="/data/adb/agh/scripts"
MOD_PATH=${MODPATH:-/data/adb/modules/AdGuardHome}
LAST_LOCALE="INIT"

# 防止重复启动
[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

DESC_ZH="[v30] AdGuard Home 20261116-v30（上游入口只留在 SmartDNS「上游服务器」页刷新按钮右边，AGH 侧栏里那个入口已移除；上游管理页新增「返回」按钮；加密上游预设换成实测最快的一批 —— 阿里 DoH(IP) 105ms / DoH(IP2) 107ms / DoT(IP2) 108ms / DoT(IP) 110ms / 阿里 DoQ 115ms / 阿里 DoH(域名) 134ms / DoT(域名) 138ms / 360 DoH 138ms / DNSPod DoH 178ms / DNSPod DoT 183ms / 腾讯 DoT 244ms / 腾讯 DoH 250ms；已剔除 dns.google、Cloudflare、AdGuard、dns.qq.com 等全部超时项） + SmartDNS 48.5-RC1 + data-dir 持久化修「请求处理已暂停」 + 卸载数据快照可恢复（AGH 40251 · smartdns 6080 · 上游管理 6081）"
DESC_EN="[v30] AdGuard Home 20261116-v30 (the upstream entry now lives only in the SmartDNS upstream-servers page, right next to Refresh; the AdGuard Home sidebar entry is gone; the upstream manager got a Back button; encrypted-upstream presets replaced with the fastest measured set -- AliDNS DoH(IP) 105ms / DoH(IP2) 107ms / DoT(IP2) 108ms / DoT(IP) 110ms / AliDNS DoQ 115ms / AliDNS DoH 134ms / AliDNS DoT 138ms / 360 DoH 138ms / DNSPod DoH 178ms / DNSPod DoT 183ms / Tencent DoT 244ms / Tencent DoH 250ms; all timing-out entries such as dns.google, Cloudflare, AdGuard and dns.qq.com removed) + SmartDNS 48.5-RC1 + persistent data-dir fixing the 'processing suspended' state + restorable uninstall snapshot (AGH 40251 · smartdns 6080 · upstream mgr 6081)"

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