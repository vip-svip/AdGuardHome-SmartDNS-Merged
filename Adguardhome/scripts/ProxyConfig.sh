#!/system/bin/sh
CONFIG_FILE="$(dirname "$0")/config.prop"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
LOCAL_DNS="127.0.0.1:${redir_port}"
# 老版 config.prop 里没有这个键
[ -n "$vpn_compat" ] || vpn_compat=auto

# 出接口是 VPN / 代理隧道就认为 VPN 在跑（排除内核自带的 tunl0：tun+l0 不是 tun+数字）
vpn_ifaces() {
    ip -o link show up 2>/dev/null | awk -F': ' '{
        n = $2
        sub(/@.*/, "", n)
        if (n ~ /^(tun|tap|ppp|utun|wg|ipsec)[0-9]+$/) printf "%s ", n
    }'
}

# redir_port 以 AGH 的 yaml 为准：config.prop 被覆盖时会指向没人监听的端口，
# 代理 yaml 里塞的 "- 127.0.0.1:<错误端口>" 会让代理解析全挂。这里先校正一次。
YAML="/data/adb/agh/bin/AdGuardHome.yaml"
sync_redir_port() {
    [ -f "$YAML" ] || return 0
    _p=$(awk '/^dns:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$YAML" 2>/dev/null)
    case "$_p" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$_p" = "$redir_port" ] && return 0
    redir_port="$_p"
    LOCAL_DNS="127.0.0.1:${redir_port}"
    sed -i "s/^redir_port=.*/redir_port=$_p/" "$CONFIG_FILE" 2>/dev/null
}
sync_redir_port

# 防止重复启动
[ $(pgrep -f "$0" | wc -l) -gt 1 ] && exit

# 在这里添加需要处理的配置文件
# 格式: "配置文件路径|服务重启命令"
PROXY_CONFIGS=(
    "/data/adb/box_bll/clash/*.yaml|/data/adb/box_bll/scripts/box.service restart"
    "/data/adb/box/mihomo/*.yaml|/data/adb/box/scripts/box.service restart"
    "/data/clash/*.yaml|/data/clash/scripts/clash.service -k && /data/clash/scripts/clash.service -s"
    "/data/media/0/Android/Clash/*.yaml|/data/adb/modules/Clash/Scripts/Clash.Service stop; /data/adb/modules/Clash/Scripts/Clash.Service start"
)

# 提取共用section列表
ALL_SECTIONS="direct-nameserver: proxy-server-nameserver: nameserver: default-nameserver: [Rr][Uu][Ll][Ee]-[Ss][Ee][Tt] [Gg][Ee][Oo][Ss][Ii][Tt][Ee] "

# binder 可用性探测（KSU 早期启动阶段 /dev/binderfs 可能尚未挂载）
binder_available() {
    command -v settings >/dev/null 2>&1 || return 1
    command -v am >/dev/null 2>&1 || return 1
    settings get global airplane_mode_on >/dev/null 2>&1
}

# 重启服务并刷新网络
restart_service() {
    $1
    if binder_available; then
        for s in 1 0; do
            settings put global airplane_mode_on $s 2>/dev/null
            am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
        done
    fi
}

# 检查是否是标准情况 
is_standard_config() {
    [ -f "$1" ] || return 1
    [ -z "$PROXY_URL" ] || grep -qF "$PROXY_URL" "$1" || return 1
    grep -q "^[[:space:]]*dns:" "$1" && grep -q "^[[:space:]]*enhanced-mode:[[:space:]]*redir-host" "$1" || return 1
    for section in $ALL_SECTIONS; do
        grep -q "^[[:space:]]*['\"]*${section}" "$1" || continue
        section_content=$(sed -n "/^[[:space:]]*['\"]*${section}/,/^[^[:space:]#]/p" "$1")
        has_local_dns=$(echo "$section_content" | grep -c "^[[:space:]]*-[[:space:]]*$LOCAL_DNS")
        other_dns=$(echo "$section_content" | grep "^[[:space:]]*- " | grep -v "^[[:space:]]*- *#" | grep -v "$LOCAL_DNS" | wc -l)
        commented_local_dns=$(echo "$section_content" | grep -c "^[[:space:]]*#.*-[[:space:]]*$LOCAL_DNS")
        [ $commented_local_dns -gt 0 ] && return 1
        [ $has_local_dns -eq 0 ] || [ $other_dns -gt 0 ] && return 1
    done
    return 0
}

# 清理配置文件中的旧DNS设置
clean_config() {
    [ ! -f "$1" ] && return 1
    for section in $ALL_SECTIONS; do
        sed -i "/^[[:space:]]*['\"]*${section}/,/^[^[:space:]]/{/^[[:space:]]*#\{0,1\}[[:space:]]*-[[:space:]]*127\.0\.0\.1:[0-9][0-9]*$/d;s/^\([[:space:]]*\)#[[:space:]]*\(-[[:space:]]*[^#].*\)/\1\2/}" "$1"
    done
}

# 通用配置文件处理
process_config() {
    is_standard_config "$1" && return 1
    local modified=0
    [ -z "$PROXY_URL" ] || grep -qF "$PROXY_URL" "$1" || {
        sed -i "/proxy-providers:/,/url:/{s|^\([[:space:]]*\)url:.*|\1url: \"${PROXY_URL//&/\\&}\"|}" "$1" && modified=1
    }
    (grep -q "^[[:space:]]*dns:" "$1" && grep -q "^[[:space:]]*enhanced-mode:[[:space:]]*redir-host" "$1") || {
        sed -i '/^[[:space:]]*dns:/,/^[^[:space:]]/s/^\([[:space:]]*enhanced-mode:\).*/\1 redir-host/' "$1" && modified=1
    }
    clean_config "$1"
    for section in $ALL_SECTIONS; do
        sed -i "/^[[:space:]]*['\"]*${section}/,/^[[:space:]]*[^[:space:]#'\"=-]/{/- $LOCAL_DNS/! s/^\\([[:space:]]*\\)\\(-[[:space:]]*[^#].*\\)/\\1# \\2/;/- $LOCAL_DNS/b;/^[[:space:]]*['\"]*${section}/{n;:l;/^[[:space:]]*#*[[:space:]]*-/!{n;bl};/- $LOCAL_DNS/!{s/^\\([[:space:]]*\\)\\(#*[[:space:]]*-[[:space:]]*.*\\)/\\1- $LOCAL_DNS\\
\\1# \\2/}}}" "$1"
    done
    [ $modified -eq 1 ] && return 0
    grep -q "$LOCAL_DNS" "$1"
    return $?
}

# 主函数
i=0
while :; do
    . "$CONFIG_FILE"
    [ -n "$vpn_compat" ] || vpn_compat=auto
    IFS='|' read -r config_file restart_cmd <<< "${PROXY_CONFIGS[$i]}"

    # ---------------------------------------------------------------
    # VPN 让路模式（vpn_compat=auto 且检测到隧道接口）：
    # 之前的逻辑会在代理的 yaml 里塞一行 "nameserver: - 127.0.0.1:<redir_port>"，
    # 让代理的解析指向 AGH。但 VPN 开着的时候 AGH 自己的上游查询会走隧道，
    # 被 Clash/mihomo 的 DNS 劫持再转回 AGH —— 形成解析环，表现是「VPN 连上但上不了网」。
    # 所以让路模式下要把这行撤回去（clean_config 只删 127.0.0.1:<redir_port>，
    # 不动用户自己的其它 DNS 项），让代理用回自己的 DNS。
    # ---------------------------------------------------------------
    if [ "$vpn_compat" = auto ] && [ -n "$(vpn_ifaces)" ]; then
        _dirty=0
        for _f in $config_file; do
            [ -f "$_f" ] || continue
            grep -qF -- "- $LOCAL_DNS" "$_f" 2>/dev/null || continue
            clean_config "$_f"
            _dirty=1
        done
        if [ "$_dirty" -eq 1 ]; then
            restart_service "$restart_cmd"
        fi
        i=$(( (i+1) % ${#PROXY_CONFIGS[@]} ))
        sleep 5
        continue
    fi

    need_restart=0
    for config_file in $config_file; do
        [ ! -f "$config_file" ] && continue
        [ "$1" = "--clean" ] && clean_config "$config_file" && continue
        process_config "$config_file"
        [ $? -eq 0 ] && need_restart=1
    done
    if [ "$1" = "--clean" ]; then
        if [ $((i+1)) -eq ${#PROXY_CONFIGS[@]} ]; then
            exit 0
        fi
        i=$((i+1))
        continue
    fi
    [ $need_restart -eq 1 ] && restart_service "$restart_cmd"
    i=$(( (i+1) % ${#PROXY_CONFIGS[@]} ))
    sleep 5
done