#!/system/bin/sh
SCRIPT_DIR="/data/adb/agh/scripts"
ADGPATH="/data/adb/modules/AdGuardHome"
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
MAIN_LOG="$AGH_DIR/agh.log"
MODULES_DIR="/data/adb/modules"
AGH_MODULE_PROP="/data/adb/modules/AdGuardHome/module.prop"
SD_DIR="$AGH_DIR/smartdns"
SMARTDNS_BIN="$SD_DIR/usr/local/lib/smartdns/smartdns"
SD_CONF="$SD_DIR/etc/smartdns/smartdns.conf"
SD_SERVERS="$SD_DIR/etc/smartdns/servers.conf"
RULES_DIR="$ADGPATH/rules"
SUBS_DIR="$RULES_DIR/subscriptions"
WEBUI_DIR="$SCRIPT_DIR/webui"

log() { echo "$(date '+%F %T') $1" >> "$MAIN_LOG"; }

# ---------------------------------------------------------------
# 单实例保护：必须用原子操作（mkdir），不能用 pid 文件判重 ——
# 历史实现是「读 pid 文件 → 检查 /proc/<pid> 是否还是 service.sh → 写自己的 pid」，
# 三个阶段之间没有原子性：多个实例在锁文件里是已死 pid 时会同时通过检查、同时继续执行，
# 实测出现过 3 个 service.sh 并存（重复随机端口、重复拉起 smartdns/dnsenc）。
SVC_LOCK_DIR="$AGH_DIR/.service.lock"

if ! mkdir "$SVC_LOCK_DIR" 2>/dev/null; then
    # mkdir 成功与写入 pid 之间有一个极短窗口：此时锁目录存在但 pid 文件还是空的。
    # 旧实现读到空 pid 就当成「残留锁」直接 rm -rf 重抢，导致并发启动的 3 个实例
    # 互相清对方锁、全部继续执行（实测同时存活 3 个）。这里改成先等待持有者写入。
    _old=""
    _try=0
    while [ "$_try" -lt 15 ]; do
        _old=$(cat "$SVC_LOCK_DIR/pid" 2>/dev/null | tr -d ' \n\r')
        [ -n "$_old" ] && break
        sleep 0.2
        _try=$((_try+1))
    done

    if [ -n "$_old" ] && [ "$_old" != "$$" ] && [ -d "/proc/$_old" ] \
       && tr '\0' ' ' < "/proc/$_old/cmdline" 2>/dev/null | grep -q 'service.sh'; then
        # 旧版遗留：`pgrep || script &` 会留下 cmdline 仍是 service.sh 的后台子 shell，
        # 它持有常驻子脚本、永远不退出。这种进程没有 service.sh 的直接子进程，
        # 不能当成「正在运行的实例」，否则本次启动会被误拦。
        if [ -n "$(pgrep -P "$_old" 2>/dev/null)" ] || [ "$_old" = "$$" ]; then
            log "service.sh 已在运行（pid $_old），本次退出"
            exit 0
        fi
        log "清理残留的 service.sh 子 shell（pid $_old）"
        kill -9 "$_old" 2>/dev/null
    fi

    # 只有确认「pid 文件为空超过 3 秒」或「持有者进程已死」才清锁重抢。
    rm -rf "$SVC_LOCK_DIR" 2>/dev/null
    if ! mkdir "$SVC_LOCK_DIR" 2>/dev/null; then
        log "抢锁失败（并发启动），本次退出"
        exit 0
    fi
fi
echo "$$" > "$SVC_LOCK_DIR/pid" 2>/dev/null
trap 'rm -rf "$SVC_LOCK_DIR" 2>/dev/null' EXIT INT TERM HUP

# 解锁脚本防篡改保护
find "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \; 2>/dev/null

# 系统语言检测
locale=$(getprop persist.sys.locale)
[ -z "$locale" ] && locale="zh"
case $locale in zh*) lang=zh ;; *) lang=en ;; esac

# hosts 模块检测 —— 只警示，不再中止启动、更不再给别的模块打 remove 标记。
# 旧行为有两个真实危害：①本模块不用 /system/etc/hosts（拦截靠 AGH 自带过滤器），
# 这条检查已无必要；②touch "$module/remove" 会让 KernelSU 在重启后把用户
# 自己的别的模块执行 uninstall.sh 并整目录删除，属于静默破坏用户环境。
# 因此改为：只记录一条提示，启动继续。
found_hosts=""
for module in "$MODULES_DIR"/*; do
  [ -d "$module" ] || continue
  [ "$module" = "$ADGPATH" ] && continue
  if [ -f "$module/system/etc/hosts" ]; then
    found_hosts="$found_hosts $(basename "$module")"
  fi
done
if [ -n "$found_hosts" ]; then
  log "[WARN] 检测到自带 hosts 的模块:$found_hosts —— 本模块使用 AGH 自带本地 hosts 过滤器，不冲突，继续启动。"
fi

agh_running() { pgrep -f "$BIN_DIR/AdGuardHome" >/dev/null 2>&1; }
smartdns_running() { pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1; }

# ---------------------------------------------------------------
# 动态端口随机化（仅在 AGH 未运行时——避免重启时把正在用的端口改掉）
# ---------------------------------------------------------------
if ! agh_running; then
    R1=$((30000+RANDOM%35536)); R2=40251
    sed -i "/^dns:/,/^[^[:space:]]/ s/^\([[:space:]]*port:\) [0-9]*/\1 $R1/; s/^\([[:space:]]*address:\) [0-9.]*:[0-9]*/\1 0.0.0.0:$R2/" "$BIN_DIR/AdGuardHome.yaml"
    sed -i "s/^redir_port=.*/redir_port=$R1/" "$SCRIPT_DIR/config.prop"
fi

# ---------------------------------------------------------------
# SmartDNS（chroot，AGH 的上游）—— 无论 AGH 是否已在运行，都要确保它在
# ---------------------------------------------------------------
# ---------------------------------------------------------------
# SmartDNS 数据目录保护
# smartdns 的 UI 插件要在 data-dir 下建 smartdns.db。目录不存在或不可写时，
# UI 会把 free_disk_space 报成 0 → is_process_suspended=true →
# 「服务器请求处理已暂停」，所有查询被丢弃（48.5 实测复现）。
# 因此每次启动前都必须把目录建好并交给 nobody(9999)。
# ---------------------------------------------------------------
SD_VARDIR="$SD_DIR/var/lib/smartdns"
SD_VARCACHE="$SD_DIR/var/cache/smartdns"
SD_VARLOG="$SD_DIR/var/log/smartdns"
SD_DB="$SD_VARDIR/smartdns.db"

sd_datadir_guard() {
    mkdir -p "$SD_VARDIR" "$SD_VARCACHE" "$SD_VARLOG" 2>/dev/null
    chown 9999:9999 "$SD_VARDIR" "$SD_VARCACHE" 2>/dev/null
    chmod 755 "$SD_VARDIR" "$SD_VARCACHE" 2>/dev/null
    # 老版本配置还写着 /tmp/smartdns（tmpfs，重启必丢）→ 迁移到持久目录
    if [ -f "$SD_CONF" ] && grep -qE '^[[:space:]]*data-dir[[:space:]]+/tmp/' "$SD_CONF" 2>/dev/null; then
        sed -i "s|^[[:space:]]*data-dir[[:space:]].*|data-dir /var/lib/smartdns|" "$SD_CONF"
        log "已把 SmartDNS data-dir 从 tmpfs 迁移到 /var/lib/smartdns（修「请求处理已暂停」）"
    fi
    # 配置里完全没有 data-dir 时补一行
    if [ -f "$SD_CONF" ] && ! grep -qE '^[[:space:]]*data-dir[[:space:]]' "$SD_CONF" 2>/dev/null; then
        echo "data-dir /var/lib/smartdns" >> "$SD_CONF"
    fi
}

# SmartDNS 起来后确认没有因磁盘守卫被暂停；被暂停就重建目录并重启一次
sd_suspend_guard() {
    _bb=""
    for _c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
        [ -x "$_c" ] && { _bb="$_c"; break; }
    done
    [ -n "$_bb" ] || return 0
    _tok=$("$_bb" wget -qO- --post-data='{"username":"root","password":"root"}'         --header='Content-Type: application/json' http://127.0.0.1:6080/api/auth/login 2>/dev/null         | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$_tok" ] || return 0
    _ov=$("$_bb" wget -qO- --header="Authorization: Bearer $_tok" http://127.0.0.1:6080/api/stats/overview 2>/dev/null)
    case "$_ov" in
    *'"is_process_suspended":true'*|*'"free_disk_space":0'*|*'"database_size":0'*)
        log "[WARN] SmartDNS 数据目录不可用（磁盘守卫/建库失败），修复目录并重启 SmartDNS"
        sd_datadir_guard
        chmod 755 "$SD_VARDIR" "$SD_VARCACHE" 2>/dev/null
        chown 9999:9999 "$SD_VARDIR" "$SD_VARCACHE" 2>/dev/null
        rm -f "$SD_DB-shm" "$SD_DB-wal" 2>/dev/null
        pkill -f '/usr/local/lib/smartdns/smartdns' 2>/dev/null
        _w=0
        while pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1 && [ "$_w" -lt 20 ]; do
            sleep 0.5; _w=$((_w+1))
        done
        start_smartdns
        ;;
    esac
    return 0
}

sd_mounts() {
    mkdir -p "$SD_DIR/dev" "$SD_DIR/proc" "$SD_DIR/sys" "$SD_DIR/tmp" "$SD_DIR/run" 2>/dev/null
    mountpoint -q "$SD_DIR/dev"  || mount --bind /dev  "$SD_DIR/dev"  2>/dev/null
    mountpoint -q "$SD_DIR/proc" || mount --bind /proc "$SD_DIR/proc" 2>/dev/null
    mountpoint -q "$SD_DIR/sys"  || mount --bind /sys  "$SD_DIR/sys"  2>/dev/null
    mountpoint -q "$SD_DIR/tmp"  || mount -t tmpfs -o mode=0777,nosuid,nodev tmpfs "$SD_DIR/tmp" 2>/dev/null
    mountpoint -q "$SD_DIR/run"  || mount -t tmpfs -o mode=0777,nosuid,nodev tmpfs "$SD_DIR/run" 2>/dev/null
}

start_smartdns() {
    [ -x "$SMARTDNS_BIN" ] || return 1
    smartdns_running && return 0
    sd_datadir_guard
    sd_mounts
    setsid chroot "$SD_DIR" /usr/local/lib/smartdns/smartdns >/dev/null 2>&1 &
    sleep 1
    if smartdns_running; then
        [ "$lang" = "zh" ] && log "SmartDNS 启动成功 (chroot, :6053, UI :6080)。" || log "SmartDNS started (chroot, :6053, UI :6080)."
        return 0
    fi
    [ "$lang" = "zh" ] && log "SmartDNS 启动失败（AGH 将回退 fallback DoH）。" || log "SmartDNS failed to start, AGH will use fallback DoH."
    return 1
}

# 保证 servers.conf 存在、smartdns.conf 引用它（老版本升级迁移）
sd_config_guard() {
    [ -f "$SD_CONF" ] || return 0
    if [ ! -f "$SD_SERVERS" ]; then
        mkdir -p "$(dirname "$SD_SERVERS")" 2>/dev/null
        {
            echo "# SmartDNS 上游 DNS 服务器列表（每行一条：server <IP>[:端口]）"
            echo "# 可在 SmartDNS 网页「上游服务器 → 添加上游服务器」里增删"
        } > "$SD_SERVERS"
        # 把 smartdns.conf 里已有的 server 行搬过来
        grep -E '^[[:space:]]*server[[:space:]]' "$SD_CONF" 2>/dev/null | sed 's/^[[:space:]]*//' >> "$SD_SERVERS"
        sed -i '/^[[:space:]]*server[[:space:]]/d' "$SD_CONF" 2>/dev/null
    fi
    if ! grep -q '^[[:space:]]*conf-file[[:space:]].*servers\.conf' "$SD_CONF" 2>/dev/null; then
        # 在 bind 行之后插入（无 bind 则插到文件头）；用 awk，兼容 toybox sed 不支持 0,/re/
        awk -v cf="conf-file /etc/smartdns/servers.conf" '
            BEGIN { done=0; hasbind=0 }
            /^[[:space:]]*bind[[:space:]]/ && done==0 { print; print cf; done=1; hasbind=1; next }
            { print }
            END { if (done==0) print cf }
        ' "$SD_CONF" > "$SD_CONF.new.$$" 2>/dev/null
        if [ -s "$SD_CONF.new.$$" ]; then
            cat "$SD_CONF.new.$$" > "$SD_CONF" 2>/dev/null
        fi
        rm -f "$SD_CONF.new.$$" 2>/dev/null
        # 若文件里原本没有 bind 行，conf-file 落到了末尾；这种情况下保证它存在即可
        grep -q 'servers\.conf' "$SD_CONF" 2>/dev/null || \
            echo "conf-file /etc/smartdns/servers.conf" >> "$SD_CONF"
    fi
}
# ---------------------------------------------------------------
# 加密上游（DoH / DoH3 / DoT / DoQ / DNSCrypt）
# smartdns 构建没编译 TLS，所以由 dnsenc 在 127.0.0.1:6054 把加密 DNS
# 转成本地普通 DNS，smartdns 再当普通上游用。
# ---------------------------------------------------------------
SD_ENC="$SD_DIR/etc/smartdns/encrypted.conf"
SD_ENC_SRV="$SD_DIR/etc/smartdns/enc-servers.conf"
SD_RULES="$SD_DIR/etc/smartdns/domain-rules.conf"
DNSENC_BIN="$BIN_DIR/dnsenc"
DNSENC_PORT=6054

dnsenc_running() { pgrep -f "$DNSENC_BIN" >/dev/null 2>&1; }

# 等端口真正释放（pkill 之后内核回收 UDP 端口有延迟）
wait_port_free() {
    _p="$1"; _i=0
    while [ "$_i" -lt 12 ]; do
        if ! netstat -lun 2>/dev/null | grep -q "127.0.0.1:$_p "; then
            return 0
        fi
        sleep 0.5; _i=$((_i+1))
    done
    return 0
}

stop_dnsenc() {
    pkill -9 -f "$DNSENC_BIN" 2>/dev/null
    _i=0
    while [ "$_i" -lt 20 ]; do
        dnsenc_running || break
        sleep 0.25; _i=$((_i+1))
    done
    wait_port_free "$DNSENC_PORT"
}

enc_count() {
    [ -f "$SD_ENC" ] || { echo 0; return; }
    n=$(grep -vE '^[[:space:]]*(#|$)' "$SD_ENC" 2>/dev/null | grep -c . 2>/dev/null)
    [ -n "$n" ] || n=0
    echo "$n"
}

# 加密上游单独成组 enc，并且从默认组排除：
# 只有 domain-rules.conf 里写 -nameserver enc 的域名才走加密，其余域名不额外等 DoH。
sd_enc_guard() {
    mkdir -p "$(dirname "$SD_ENC_SRV")" 2>/dev/null
    n=$(enc_count)
    {
        echo "# 由 service.sh / 管理页自动生成，请勿手改。"
        if [ "$n" -gt 0 ]; then
            echo "server 127.0.0.1:$DNSENC_PORT -group enc -exclude-default-group"
        fi
    } > "$SD_ENC_SRV" 2>/dev/null
    if [ -f "$SD_CONF" ] && ! grep -q 'enc-servers\.conf' "$SD_CONF" 2>/dev/null; then
        echo "conf-file /etc/smartdns/enc-servers.conf" >> "$SD_CONF"
    fi
    if [ -f "$SD_CONF" ] && ! grep -q 'domain-rules\.conf' "$SD_CONF" 2>/dev/null; then
        echo "conf-file /etc/smartdns/domain-rules.conf" >> "$SD_CONF"
    fi
    # 没有可用加密上游时，把指向 enc 组的分流规则注释掉，避免引用不存在的组
    if [ -f "$SD_RULES" ]; then
        # 自愈：历史 sed 守卫没锚定行尾，会把文档示例行（含 →）误取消注释；
        # 那种行不是合法规则，smartdns 载入时会直接报错。这里统一重新注释。
        sed -i "/^[[:space:]]*domain-rules .*→/s/^/#/" "$SD_RULES" 2>/dev/null
        if [ "$n" -gt 0 ]; then
            sed -i "s/^#[[:space:]]*\(domain-rules \/[^/]*\/ -nameserver enc\)$/\1/" "$SD_RULES" 2>/dev/null
        else
            sed -i "s/^\(domain-rules \/[^/]*\/ -nameserver enc\)$/#\1/" "$SD_RULES" 2>/dev/null
        fi
    fi
}

start_dnsenc() {
    [ -x "$DNSENC_BIN" ] || return 1
    [ "$(enc_count)" -gt 0 ] || return 1
    dnsenc_running && return 0
    # 端口被残留实例占着（bind 会失败）→ 先清干净
    wait_port_free "$DNSENC_PORT"
    SSL_CERT_DIR=/system/etc/security/cacerts/ setsid "$DNSENC_BIN" \
        -listen "127.0.0.1:$DNSENC_PORT" -conf "$SD_ENC" \
        >> "$AGH_DIR/dnsenc.log" 2>&1 &
    _i=0
    while [ "$_i" -lt 10 ]; do
        netstat -lun 2>/dev/null | grep -q "127.0.0.1:$DNSENC_PORT " && break
        sleep 0.5; _i=$((_i+1))
    done
    if dnsenc_running; then
        [ "$lang" = "zh" ] && log "加密上游转发生效（$(enc_count) 条 → 127.0.0.1:$DNSENC_PORT）。" || log "Encrypted upstream bridge up ($(enc_count) entries -> :$DNSENC_PORT)."
        return 0
    fi
    [ "$lang" = "zh" ] && log "加密上游转发启动失败，检查 $SD_ENC 写法。" || log "dnsenc failed to start, check $SD_ENC."
    return 1
}

# 先修目录（权限/属主/data-dir 迁移），再谈启动；smartdns 已在跑时这条同样要执行，
# 否则「目录不可写」这类状态永远修不回来。
sd_datadir_guard
sd_config_guard
sd_enc_guard
start_dnsenc
start_smartdns
sd_suspend_guard

# ---------------------------------------------------------------
# 规则目录守护：所有规则文件（内置 + 我添加的 + 网络订阅下载的）都真实存放在
# 模块根目录 rules/ 下，数据目录里对应路径是软链接，供 AGH 读写。
# ---------------------------------------------------------------
mkdir -p "$RULES_DIR" "$SUBS_DIR" 2>/dev/null
# 白名单文件缺失时从备份恢复（原内置的 iptables-DROP规则.txt 已在 v19 移除）
if [ ! -f "$RULES_DIR/myallow.txt" ] && [ -f "$AGH_DIR/backup/rules/myallow.txt" ]; then
    cp -f "$AGH_DIR/backup/rules/myallow.txt" "$RULES_DIR/myallow.txt" 2>/dev/null
fi
# 旧版本留下的 iptables 加固链清理（v19 起该功能已移除）
for ch in AGH_HARDEN AGH_HARDEN6; do
    case "$ch" in
        *6) ipt="ip6tables" ;;
        *)  ipt="iptables" ;;
    esac
    while $ipt -w 2 -t filter -D OUTPUT -j "$ch" 2>/dev/null; do :; done
    $ipt -w 2 -t filter -F "$ch" 2>/dev/null
    $ipt -w 2 -t filter -X "$ch" 2>/dev/null
done

link_rules_dirs() {
    for pair in "$BIN_DIR/data/userfilters:$RULES_DIR" "$BIN_DIR/data/filters:$SUBS_DIR"; do
        dst=${pair%:*}
        src=${pair#*:}
        [ -d "$src" ] || mkdir -p "$src" 2>/dev/null
        if [ -d "$dst" ] && [ ! -L "$dst" ]; then
            for f in "$dst"/*; do
                [ -f "$f" ] || continue
                b=$(basename "$f")
                [ -f "$src/$b" ] || cp -f "$f" "$src/$b" 2>/dev/null
            done
            rm -rf "$dst"
        fi
        [ -L "$dst" ] && rm -f "$dst"
        ln -sfn "$src" "$dst" 2>/dev/null
    done
}
mkdir -p "$BIN_DIR/data" 2>/dev/null
link_rules_dirs

export SSL_CERT_DIR="/system/etc/security/cacerts/"

# ---------------------------------------------------------------
# 上游服务器管理小服务（SmartDNS 网页「上游服务器」页上的「+ 添加上游服务器」）
# busybox httpd + CGI，只监听 127.0.0.1:6081
# ---------------------------------------------------------------
find_busybox() {
    for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
             /system/xbin/busybox /system/bin/busybox /data/adb/bin/busybox; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}

start_webui() {
    [ -d "$WEBUI_DIR/cgi-bin" ] || return 0
    chmod 755 "$WEBUI_DIR/cgi-bin"/* 2>/dev/null
    pgrep -f 'httpd -p 127.0.0.1:6081' >/dev/null 2>&1 && return 0
    BB=$(find_busybox)
    if [ -z "$BB" ]; then
        [ "$lang" = "zh" ] && log "未找到 busybox，上游服务器管理页不可用（可用 sd-restart.sh 手动管理）。" || log "busybox not found, upstream manager disabled."
        return 0
    fi
    "$BB" httpd -p 127.0.0.1:6081 -h "$WEBUI_DIR" 2>/dev/null
    return 0
}
start_webui

# ---------------------------------------------------------------
# 启动 AdGuardHome
# ---------------------------------------------------------------
if ! agh_running; then
    # 校验yaml，损坏则恢复备份
    if ! "$BIN_DIR/AdGuardHome" --check-config -c "$BIN_DIR/AdGuardHome.yaml" >/dev/null 2>&1; then
        [ "$lang" = "zh" ] && log "yaml 校验失败，恢复备份。" || log "yaml check failed, restoring backup."
        for bak in "$AGH_DIR/backup/AdGuardHome.yaml" "$BIN_DIR/AdGuardHome.yaml.bak"; do
            if [ -f "$bak" ]; then cp -f "$bak" "$BIN_DIR/AdGuardHome.yaml"; break; fi
        done
    fi
    "$BIN_DIR/AdGuardHome" --no-check-update &
    sleep 1
    if agh_running; then
        [ "$lang" = "zh" ] && log "AdGuardHome 启动成功。" || log "AdGuardHome started successfully."
    else
        [ "$lang" = "zh" ] && log "AdGuardHome 启动失败，尝试重启..." || log "AdGuardHome failed to start, attempting restart..."
    fi
fi

# ---------------------------------------------------------------
# 启动模块附加脚本
# ---------------------------------------------------------------
# 注意：不能写 `pgrep ... || script.sh &`。
# mksh 会把 `||` 整条列表放进后台子 shell，子 shell 的 cmdline 仍然是
# `sh .../service.sh`，并且要一直等常驻子脚本（ModuleMOD/NoAdsService/ProxyConfig）
# 结束才退出 —— 结果留下多个「假 service.sh」，下次开机单实例锁会误判
# 「已在运行」直接 exit，服务再也不启动。这里改成显式 if + setsid。
start_helper() {
    _pat="$1"
    if pgrep -f "$_pat" >/dev/null 2>&1; then
        return 0
    fi
    setsid "$_pat" </dev/null >/dev/null 2>&1 &
    return 0
}
start_helper "$SCRIPT_DIR/iptables.sh"
start_helper "$SCRIPT_DIR/ModuleMOD.sh"
start_helper "$SCRIPT_DIR/NoAdsService.sh"
start_helper "$SCRIPT_DIR/ProxyConfig.sh"

# 执行脚本防篡改保护
#
# 只锁「不该被就地修改」的脚本，不锁 service.sh / customize.sh：
#   - service.sh 每次开机都被 ModuleMOD.sh 之外的流程读取，且需要升级替换；
#   - customize.sh 是安装入口，升级时必须能覆盖（否则模块永远停在旧版安装逻辑）。
# 历史实现锁了 ADGPATH 下全部 *.sh，导致：adb push 报 Operation not permitted、
# chmod 报 Operation not permitted、卸载时 uninstall.sh 自己也被锁住。
find "$ADGPATH" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null
for _f in action.sh uninstall.sh; do
    [ -f "$ADGPATH/$_f" ] && chattr +i "$ADGPATH/$_f" 2>/dev/null
done
for _f in "$SCRIPT_DIR"/*.sh; do
    [ -f "$_f" ] && chattr +i "$_f" 2>/dev/null
done

# 日志超限时清空
[ -f "$MAIN_LOG" ] && [ "$(wc -c < "$MAIN_LOG")" -ge 102400 ] && : > "$MAIN_LOG"

exit 0
