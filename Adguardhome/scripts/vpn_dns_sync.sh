#!/system/bin/sh
# VPN DNS 共存：把 AGH 的 DNS 端口注入到常见 VPN / 内核代理的配置里，
# 让「VPN 开着时」的域名解析也经过 AGH（DNS 过滤 / 家长控制 / 脚本拦截照常生效）。
#
# 背景：VPN（VpnService fake-ip 模式）会在自己的 tun 里劫持 DNS，
# 应用查询根本到不了 AGH；只有把 VPN 自己的上游 nameserver 指向 AGH，
# VPN 才会带着真实解析请求回到 AGH。
#
# 设计要点：
#   1) 端口以 AGH 的 yaml 为准（AGH 端口被占用时会随机回退，写死会失效）
#   2) 只「插入」不「删除」用户自己的 DNS 项，幂等
#   3) 每 20 秒巡检一次：VPN 应用重启会重写配置文件，需要补回
#   4) 全部失败静默退出，不影响主流程

AGH_DIR=/data/adb/agh
YAML="$AGH_DIR/bin/AdGuardHome.yaml"
LOG="$AGH_DIR/vpn_dns.log"
STATE="$AGH_DIR/vpn_dns.state"

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

# yaml 里声明的 DNS 端口
yaml_port() {
    [ -f "$YAML" ] || return 1
    awk '/^dns:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$YAML" 2>/dev/null
}

# AGH 进程实际监听的 DNS 端口。
# 为什么不能只信 yaml：AGH 启动时若发现端口被占用会静默回退到随机端口，
# 并且不会把新端口写回 yaml——此时按 yaml 注入会让 VPN 指向没人监听的端口，
# 表现为「VPN 连上后解析全挂」。所以优先以实际监听端口为准。
agh_port() {
    _ap=$(yaml_port)
    _pid=$(pidof AdGuardHome 2>/dev/null | awk '{print $1}')
    if [ -n "$_pid" ]; then
        _live=$(netstat -ulnp 2>/dev/null | grep "$_pid/AdGuardHome" | awk '{print $4}' \
                | sed 's/.*://' | grep -E '^[0-9]+$' | grep -vx 53 | head -1)
        [ -z "$_live" ] && _live=$(ss -ulnp 2>/dev/null | grep "pid=$_pid" | awk '{print $4}' \
                | sed 's/.*://' | grep -E '^[0-9]+$' | grep -vx 53 | head -1)
        if [ -n "$_live" ]; then
            # 实际端口与 yaml 不一致 → 把 yaml 校正回来（下次启动才稳定）
            if [ -n "$_ap" ] && [ "$_live" != "$_ap" ]; then
                _ln=$(grep -n "port:" "$YAML" 2>/dev/null | sed -n '2p' | cut -d: -f1)
                [ -n "$_ln" ] && sed -i "${_ln}s/.*/  port: $_live/" "$YAML" 2>/dev/null \
                    && log "port drift: yaml $_ap -> actual $_live (yaml corrected)"
            fi
            echo "$_live"; return 0
        fi
    fi
    [ -n "$_ap" ] && echo "$_ap"
}

# 需要处理的配置（glob），覆盖常见的 Android VPN / 内核代理应用
CONFIGS="
/data/data/com.follow.clash/files/profiles/*.yaml
/data/data/com.follow.clash/files/config.yaml
/data/data/com.github.metacubex.clash.meta/files/profiles/*.yaml
/data/data/com.github.metacubex.clash.meta/files/config.yaml
/data/data/com.github.kr328.clash/files/profiles/*.yaml
/data/data/io.nekohasekai.sfa/files/*.json
/data/adb/box_bll/clash/*.yaml
/data/adb/box/mihomo/*.yaml
/data/clash/*.yaml
"

# 在 nameserver 里注入 127.0.0.1:PORT（flow / block 两种写法）
inject_one() {
    _f="$1"; _port="$2"
    [ -f "$_f" ] || return 1
    # 已经有就不动
    grep -q "127\.0\.0\.1:$_port" "$_f" 2>/dev/null && return 1
    # 只处理含 dns 段与 nameserver 的文件
    grep -q "^[[:space:]]*nameserver:" "$_f" 2>/dev/null || return 1

    _tmp="$_f.aghtmp"
    # flow 风格：nameserver: ['a', 'b']  →  nameserver: ['127.0.0.1:PORT', 'a', 'b']
    sed -E "s|^([[:space:]]*nameserver:[[:space:]]*)\[|\1['127.0.0.1:$_port', |" "$_f" > "$_tmp" 2>/dev/null
    # block 风格：nameserver: 下一行是 "- xxx"，在 nameserver: 行后插一行
    if ! grep -q "127\.0\.0\.1:$_port" "$_tmp" 2>/dev/null; then
        awk -v p="$_port" '
            { print }
            /^[[:space:]]*nameserver:[[:space:]]*$/ && !done {
                match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
                print ind "  - \"127.0.0.1:" p "\""
                done = 1
            }
        ' "$_f" > "$_tmp" 2>/dev/null
    fi
    if grep -q "127\.0\.0\.1:$_port" "$_tmp" 2>/dev/null; then
        # 保持原文件权限与属主
        cat "$_tmp" > "$_f" 2>/dev/null && {
            log "injected 127.0.0.1:$_port -> $_f"
            rm -f "$_tmp"
            return 0
        }
    fi
    rm -f "$_tmp"
    return 1
}

sync_once() {
    _port=$(agh_port)
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    _changed=0
    for _pat in $CONFIGS; do
        for _f in $_pat; do
            [ -f "$_f" ] || continue
            inject_one "$_f" "$_port" && _changed=1
        done
    done
    [ "$_changed" = 1 ] && echo "$(date +%s) $_port" > "$STATE" 2>/dev/null
    return 0
}

case "$1" in
    --once) sync_once; exit 0 ;;
esac

# 守护循环
log "vpn_dns_sync started"
while :; do
    sync_once
    sleep 20
done
