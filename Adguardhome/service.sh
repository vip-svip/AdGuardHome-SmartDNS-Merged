#!/system/bin/sh
SCRIPT_DIR="/data/adb/agh/scripts"
ADGPATH="/data/adb/modules/AdGuardHome"

# ---------------------------------------------------------------
# CPU 架构守卫：模块自带的是 arm64 静态二进制。32 位设备上一跑就是
# "Exec format error"，日志里很难看出原因，所以启动前先判一次并写清楚。
# ---------------------------------------------------------------
ARCH_OK=1
case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
    arm64*|aarch64*) ARCH_OK=1 ;;
    x86*|i386*|i686*) ARCH_OK=0 ;;
    armeabi*|arm*) ARCH_OK=0 ;;
    *) case "$(uname -m 2>/dev/null)" in aarch64|arm64) ARCH_OK=1 ;; *) ARCH_OK=0 ;; esac ;;
esac
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

if ! command -v curl >/dev/null 2>&1; then
    HAVE_CURL=0
else
    HAVE_CURL=1
fi
log() { echo "$(date '+%F %T') $1" >> "$MAIN_LOG"; }

# ---------------------------------------------------------------
# 紧急开关（诊断用）：touch /data/adb/agh/.no_start 后，本脚本只记一行就退出。
# 用来判断「开机卡住」到底是本模块的启动流程造成的，还是别的原因。
# ---------------------------------------------------------------
if [ -f "$AGH_DIR/.no_start" ]; then
    log "[WARN] 检测到 $AGH_DIR/.no_start，跳过全部启动步骤（诊断模式）。"
    exit 0
fi

# ---------------------------------------------------------------
# 设备兼容层：不同 ROM / root 方案下外部命令的可用性差异
#   pgrep    个别 ROM 的 toybox 里被裁掉了 → 用 /proc 兜底
#   netstat  较新的 toybox 已移除 → 用 ss 或 /proc/net 兜底
#   curl     Android 10+ 一般自带；缺失时相关自愈功能降级
# ---------------------------------------------------------------
if ! command -v pgrep >/dev/null 2>&1; then
    pgrep() {
        _m="$1"; shift
        case "$_m" in
            -P) _pp="$1"
                for _d in /proc/[0-9]*; do
                    _st=$(cat "$_d/stat" 2>/dev/null) || continue
                    _ppid=$(printf '%s' "$_st" | awk '{print $4}')
                    [ "$_ppid" = "$_pp" ] && echo "${_d#/proc/}"
                done ;;
            -f) for _d in /proc/[0-9]*; do
                    [ -r "$_d/cmdline" ] || continue
                    tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -q -- "$1" && echo "${_d#/proc/}"
                done ;;
            *)  for _d in /proc/[0-9]*; do
                    [ "$(cat "$_d/comm" 2>/dev/null)" = "$1" ] && echo "${_d#/proc/}"
                done ;;
        esac
    }
fi

# PORT [udp|tcp] → 0 表示本机 127.0.0.1 上有人在听
# PORT [udp|tcp] → 0 表示本机有人在听这个端口（含绑 0.0.0.0 / [::] 的服务）
port_listening() {
    _port="$1"; _proto="${2:-udp}"
    if command -v netstat >/dev/null 2>&1; then
        case "$_proto" in
            udp) netstat -lun 2>/dev/null | grep -qE "(^|[^0-9.])($_port) " && return 0 ;;
            *)   netstat -ltn 2>/dev/null | grep -qE "(^|[^0-9.])($_port) " && return 0 ;;
        esac
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        case "$_proto" in
            udp) ss -lun 2>/dev/null | grep -q "[:.]$_port " && return 0 ;;
            *)   ss -ltn 2>/dev/null | grep -q "[:.]$_port " && return 0 ;;
        esac
        return 1
    fi
    # 最后兜底：直接读 /proc/net（端口是十六进制；绑 0.0.0.0 或 [::] 也算在听）
    _hex=$(printf '%04X' "$_port")
    case "$_proto" in
        udp) _fl="/proc/net/udp /proc/net/udp6" ;;
        *)   _fl="/proc/net/tcp /proc/net/tcp6" ;;
    esac
    for _f1 in $_fl; do
        [ -r "$_f1" ] || continue
        awk -v h=":$_hex" -v want="$_proto" '
            NR > 1 {
                split($2, a, ":")
                if (":" a[2] != h) next
                # 本地地址：127.0.0.1 / 0.0.0.0 / :: 都算可达
                ip = toupper(a[1])
                if (ip != "0100007F" && ip !~ /^0+$/ && ip !~ /0{16}FFFF0100007F$/) next
                if (want == "udp") { if ($4 == "07") found = 1 }
                else               { if ($4 == "0A") found = 1 }
            }
            END { exit(found ? 0 : 1) }' "$_f1" && return 0
    done
    return 1
}

# ---------------------------------------------------------------
# 设备兼容层（第二批）：
#   mountpoint  部分老 toybox 没有 → 用 /proc/mounts 兜底
#   setsid      极少数 ROM 裁掉 → 退回 nohup + &
#   chroot      缺失时给出明确报错，而不是静默不启动 SmartDNS
# ---------------------------------------------------------------
if ! command -v mountpoint >/dev/null 2>&1; then
    mountpoint() {
        _q=""
        [ "$1" = "-q" ] && { _q=1; shift; }
        grep -qs " $1 " /proc/mounts
    }
fi

if ! command -v dirname >/dev/null 2>&1; then
    dirname() { printf '%s\n' "${1%/*}"; }
fi
if ! command -v basename >/dev/null 2>&1; then
    basename() {
        _s="${1%/}"
        printf '%s\n' "${_s##*/}"
    }
fi

if ! command -v setsid >/dev/null 2>&1; then
    setsid() {
        # 没有 setsid：直接后台（不依赖 nohup —— 少数 ROM 两个都没有）
        "$@" </dev/null >/dev/null 2>&1 &
    }
fi

# ---------------------------------------------------------------
# AGH_BOOT_ASYNC_MARK
# 开机关键路径零负担：root 实现（ksud/magiskd）会等本脚本退出才继续
# late_start，脚本一慢开机就卡。所以这里立刻把整套启动甩到后台，
# 并且等 sys.boot_completed=1 之后再真正干活，避开 dexopt / 低内存高峰。
#   .no_start         -> 只记一行，什么都不起（诊断用）
#   service.sh --run  -> 后台真正执行的那一份
# ---------------------------------------------------------------
if [ "$1" != "--run" ]; then
    log "[INFO] service.sh 转入后台执行（--run），开机关键路径不等待本脚本。"
    setsid sh "$0" --run </dev/null >>"$AGH_DIR/agh-boot.log" 2>&1 &
    exit 0
fi

mkdir -p "$AGH_DIR" 2>/dev/null

# 等系统真正开机完成（最多 180 秒），再让系统喘 12 秒
_w=0
while [ "$_w" -lt 180 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
    sleep 1
    _w=$((_w + 1))
done
if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    log "[INFO] 已等到 sys.boot_completed=1（${_w}s），12 秒后启动 DNS 服务。"
else
    log "[WARN] 等待 sys.boot_completed 超时（${_w}s），仍继续启动 DNS 服务。"
fi
sleep 12

sd_chroot_ok() {
    command -v chroot >/dev/null 2>&1 && return 0
    log "[ERROR] 本机没有 chroot 命令，SmartDNS 无法在容器内运行；请改用其他机型或内置的替代上游。"
    return 1
}

# 系统时区（AGH 没设 TZ 会把日志全写成 UTC）
if [ -z "$TZ" ]; then
    TZ=$(getprop persist.sys.timezone 2>/dev/null)
    [ -n "$TZ" ] || TZ=Asia/Shanghai
    export TZ
fi

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

# 权限自愈：老版本的包只给 sd-restart.sh / iptables.sh 赋了 755，其余脚本和
# bin/ 下三个二进制靠 unzip 的 umask，某些 KernelSU/Magisk 版本会丢 exec 位
# （真机实测 aghmitm / certs_install.sh 装完是 644），表现是「进程起不来、
# 证书装不上，但面板和日志一切正常」。每次开机无条件补齐。
for _h in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/certs_install.sh; do
    [ -f "$_h" ] && chmod 755 "$_h" 2>/dev/null
done
for _h in "$BIN_DIR"/AdGuardHome "$BIN_DIR"/aghmitm "$BIN_DIR"/dnsenc; do
    [ -f "$_h" ] && chmod 755 "$_h" 2>/dev/null
done
for _h in "$SCRIPT_DIR"/webui/cgi-bin/*; do
    [ -f "$_h" ] && chmod 755 "$_h" 2>/dev/null
done
chmod 644 "$SCRIPT_DIR"/config.prop "$SCRIPT_DIR"/sni_filter.awk 2>/dev/null

# 开机尽早建 SNI/QUIC 链：原来这一段要等到 AGH 起来、boot_completed+12s 之后才跑，
# 真机 trace 实测 NFQUEUE 拦截在开机后约 70 秒才出现（这段时间 SNI/QUIC 完全不拦）。
# 建链本身不依赖 AGH（--queue-bypass 保证 AGH 不在时直通），所以这里先建一次，
# 后面的「开机确定性重建」只做校验与兜底。
if [ -f "$SCRIPT_DIR/iptables.sh" ]; then
    sh "$SCRIPT_DIR/iptables.sh" --sni-force >/dev/null 2>&1
fi

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

agh_running() {
    _ap=$(pidof AdGuardHome 2>/dev/null | awk '{print $1}')
    [ -n "$_ap" ] || return 1
    [ "$(awk '{print $3}' "/proc/$_ap/stat" 2>/dev/null)" = "Z" ] && return 1
    return 0
}
smartdns_running() { pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1; }

# ---------------------------------------------------------------
# DNS 端口分配（仅在 AGH 未运行时——避免重启时把正在用的端口改掉）
#
# 旧实现每次开机随机 30000-65535：与「端口固定 5591 防漂移」的设计目标自相矛盾，
# 端口一变，vpn_dns_sync 注入的 nameserver、aghmitm -dns、面板排查记录全部对不上；
# 而且随机区间与内核临时端口段（32768-60999）重叠，REDIRECT 偶尔会撞上已占用端口。
#
# 现在改成确定性分配：优先 redir_port（默认 5591），被占用才向后顺延探测，
# 20 个候选都不行才退回随机。结果写回 config.prop，下一次开机继续用同一个。
# ---------------------------------------------------------------
if ! agh_running; then
    _want=$(sed -n 's/^redir_port=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null | tail -1)
    case "$_want" in ''|*[!0-9]*) _want=5591 ;; esac
    # 升级/重启瞬间旧 AGH 的 socket 可能还没释放，此时视「端口被占」就会改端口，
    # 真机上踩到过：5591 被占 → 换成 44781 → 面板/书签/vpn_dns_sync 全对不上。
    # 所以先等最多 10 秒让残留 socket 消失；只有当 AGH 进程确实不在、端口仍在听
    # （说明是别的程序占着）才顺延。
    _wait=0
    while [ "$_wait" -lt 10 ] && port_listening "$_want" udp && ! pidof AdGuardHome >/dev/null 2>&1; do
        sleep 1
        _wait=$((_wait + 1))
    done
    _r1=""
    _try=0
    _cand=$_want
    while [ "$_try" -lt 20 ]; do
        if ! port_listening "$_cand" udp; then
            _r1=$_cand
            break
        fi
        _cand=$((_cand + 1))
        _try=$((_try + 1))
    done
    [ -n "$_r1" ] || _r1=$((31000 + RANDOM % 20000))
    sed -i "/^dns:/,/^[^[:space:]]/ s/^\([[:space:]]*port:\) [0-9]*/\1 $_r1/" "$BIN_DIR/AdGuardHome.yaml"
    # 面板端口不做二次改写：原来的 address 替换写在 dns: 范围里，永远匹配不到
    # http: 段的 address，是死代码，已删除（面板端口以 yaml 原值为准）。
    chattr -i "$SCRIPT_DIR/config.prop" 2>/dev/null
    sed -i "s/^redir_port=.*/redir_port=$_r1/" "$SCRIPT_DIR/config.prop"
    # 模块目录那份是升级时的「恢复源」：不同步的话下次升级 customize 会把旧端口
    # 再恢复回来（运行 44781 / 模块 5591 → 一升级端口跳回，nat 链指错端口 DNS 断）
    if [ -f "$ADGPATH/scripts/config.prop" ]; then
        chattr -i "$ADGPATH/scripts/config.prop" 2>/dev/null
        sed -i "s/^redir_port=.*/redir_port=$_r1/" "$ADGPATH/scripts/config.prop" 2>/dev/null
    fi
    [ "$_r1" = "$_want" ] || log "[INFO] DNS 端口 $_want 被占用，改用 $_r1（已写回两处 config.prop）。"
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
# 启动后实测 SmartDNS 能否解析；不能就清缓存重启一次（装机/升级后首次启动
# 偶尔会带着旧缓存或旧配置起来，表现为 6053 全挂、手动 sd-restart.sh 才好）。

sd_suspend_guard() {

    if [ "${HAVE_CURL:-1}" != "1" ]; then
        log "[WARN] 本机没有 curl，跳过 SmartDNS 挂起自检（请打开 6080 面板确认磁盘空间）。"
        return 0
    fi
    _bb=""
    for _c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
        [ -x "$_c" ] && { _bb="$_c"; break; }
    done
    [ -n "$_bb" ] || return 0
    _su=$(sed -n 's/^[[:space:]]*sd_user=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null | head -1)
    _sp=$(sed -n 's/^[[:space:]]*sd_pass=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null | head -1)
    [ -n "$_su" ] || _su=root
    [ -n "$_sp" ] || _sp=root
    _json=$(printf '{"username":"%s","password":"%s"}' "$_su" "$_sp")
    _tok=$("$_bb" wget -qO- --post-data="$_json" --header='Content-Type: application/json' http://127.0.0.1:6080/api/auth/login 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
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

# ---------------------------------------------------------------
# 本地规则文件守卫：yaml 里引用的 rules/*.txt 若不存在，AGH 每次启动都会报
# chtimes .../filters/xxx.txt: no such file or directory，且该过滤器恒为 0 条。
# 这里只补空文件，不覆盖已有内容（用户自己写规则不会丢）。
# ---------------------------------------------------------------
agh_rules_guard() {
    _rd="$MODULES_DIR/AdGuardHome/rules"
    [ -d "$_rd" ] || return 0
    # 只补 yaml 真正引用的那一个（whitelist_filters -> rules/myallow.txt）。
    # 旧版还会造 反诈.txt / 反诈类.txt / NoAppDownload.txt，但 yaml 里没有任何地方
    # 引用它们，建出来只是三个 0 字节垃圾文件（反诈规则已经写在 yaml 的 user_rules 里）。
    [ -f "$_rd/myallow.txt" ] || : > "$_rd/myallow.txt" 2>/dev/null
    return 0
}

# 6053 是否真的在监听（进程在但没监听 = 假运行，最隐蔽的故障）

sd_listening() {
    port_listening 6053 udp
}

# 当前是否真的有网（主路由表里有默认路由）
# 开机早阶段、飞行模式、没连 Wi-Fi 时都没有 —— 这种时候 ping 域名必然失败，
# 不能据此判定「DNS 坏了」而去重启 SmartDNS、清缓存。
net_up() {
    [ -n "$(ip route show default 2>/dev/null)" ] && return 0
    [ -n "$(ip route show table main default 2>/dev/null)" ] && return 0
    # 极老的 toybox 没有 "ip route show default"
    ip route 2>/dev/null | grep -q '^default ' && return 0
    # vgate/虚拟网关类 ROM 没有 default 路由但有全局 src（OPPO vgate0 实测）
    ip -4 addr show 2>/dev/null | grep -q 'scope global' && return 0
    return 1
}
start_smartdns() {
    [ -x "$SMARTDNS_BIN" ] || return 1
    smartdns_running && sd_listening && return 0
    if smartdns_running && ! sd_listening; then
        [ "$lang" = "zh" ] && log "[WARN] SmartDNS 进程在但 6053 未监听，重启它。" \
                            || log "[WARN] SmartDNS process alive but not listening on 6053; restarting."
        pkill -9 -f '/usr/local/lib/smartdns/smartdns' 2>/dev/null
        _i=0
        while [ "$_i" -lt 24 ]; do
            pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1 || break
            sleep 0.25; _i=$((_i+1))
        done
        wait_port_free 6053
    fi
    sd_datadir_guard
    sd_mounts
    rm -f "$SD_DIR"/run/*.pid "$SD_DIR"/var/run/*.pid 2>/dev/null
    sd_chroot_ok || return 1
    setsid chroot "$SD_DIR" /usr/local/lib/smartdns/smartdns </dev/null >/dev/null 2>&1 &
    _i=0
    while [ "$_i" -lt 20 ]; do
        sleep 0.5
        sd_listening && break
        _i=$((_i+1))
    done
    if smartdns_running && sd_listening; then
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
# dnsenc 解析 DoH/DoT 主机名用的明文 bootstrap。必须挑一个「系统 DNS 不会用」的地址，
# 否则 nat 链给它的豁免会把 netd 的查询一起放过去（系统 DNS 里出现过 223.5.5.5 就是这个坑）。
DNSENC_BOOTSTRAP="119.28.28.28:53"

dnsenc_running() { pgrep -f "$DNSENC_BIN" >/dev/null 2>&1; }

# 等端口真正释放（pkill 之后内核回收 UDP 端口有延迟）
wait_port_free() {
    _p="$1"; _i=0
    while [ "$_i" -lt 12 ]; do
        if ! port_listening "$_p" udp; then
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
        -bootstrap "$DNSENC_BOOTSTRAP" \
        </dev/null >> "$AGH_DIR/dnsenc.log" 2>&1 &
    _i=0
    while [ "$_i" -lt 10 ]; do
        port_listening "$DNSENC_PORT" udp && break
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
# v6 auto 的实网自检（内核无 ip6tables nat 表时判断该 drop 还是 keep）
if [ -f "$SCRIPT_DIR/iptables.sh" ]; then
    sh "$SCRIPT_DIR/iptables.sh" --v6selftest >/dev/null 2>&1 &
fi

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
# 上游服务器管理小服务（SmartDNS 侧栏「Upstream Manage」页面）
# busybox httpd + CGI：监听 0.0.0.0:6081，手机从局域网 IP 打开面板时
# 页面 fetch 的 hostname:6081 才能连上（只绑 127.0.0.1 会 Failed to fetch）。
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
    # 自愈：模块目录里有、运行目录里没有的 CGI 补过来，并统一给执行权限。
    # 历史 bug：升级 / 旧安装只带了 upstream，certs/scripts/mitm/apps 缺失，
    # 前端请求直接 404（表现为「证书界面读取证书失败」「脚本页空列表」）。
    _modcgi="$ADGPATH/scripts/webui/cgi-bin"
    if [ -d "$_modcgi" ]; then
        for _c in "$_modcgi"/*; do
            [ -f "$_c" ] || continue
            _n=${_c##*/}
            if [ ! -f "$WEBUI_DIR/cgi-bin/$_n" ]; then
                cp -f "$_c" "$WEBUI_DIR/cgi-bin/$_n" 2>/dev/null
                log "webui: 补装缺失 CGI $_n"
            fi
        done
    fi
    chmod 755 "$WEBUI_DIR/cgi-bin"/* 2>/dev/null
    pgrep -f 'httpd -p 0.0.0.0:6081' >/dev/null 2>&1 && return 0
    # 老版本可能还绑着 127.0.0.1:6081，先停掉再换监听地址
    pkill -f 'httpd -p 127.0.0.1:6081' 2>/dev/null
    sleep 1
    BB=$(find_busybox)
    if [ -z "$BB" ]; then
        [ "$lang" = "zh" ] && log "未找到 busybox，上游服务器管理页不可用（可用 sd-restart.sh 手动管理）。" || log "busybox not found, upstream manager disabled."
        return 0
    fi
    "$BB" httpd -p 0.0.0.0:6081 -h "$WEBUI_DIR" </dev/null >/dev/null 2>&1
    return 0
}
start_webui

# 6081 管理面缓存预热：scripts/apps/certs/mitm 的列表响应冷算要 0.3~1.6s，
# 首访时前端会先渲染空态再填充（看起来像「刷新后先是空的」）。
# 这里开机后台各打一次强制重建，页面首访就是直接命中缓存。
(
    sleep 3
    curl -s -m 10 -o /dev/null "http://127.0.0.1:6081/cgi-bin/privacy?sync=1" 2>/dev/null
    for _c in scripts apps certs mitm; do
        curl -s -m 15 -o /dev/null "http://127.0.0.1:6081/cgi-bin/$_c?rebuild=1" 2>/dev/null
    done
) >/dev/null 2>&1 &

# ---------------------------------------------------------------
# 过滤器自愈：全新安装 / 升级后 rules/subscriptions 被清空时，AGH 不会主动
# 重新下载（要等 filters_update_interval 到期），表现是「装了模块但广告照样弹」。
# 这里在「所有过滤器 rules_count 全为 0」时用本地 API 触发一次刷新。
# 凭据取 scripts/config.prop 的 agh_user / agh_pass（默认 root/root）。
# ---------------------------------------------------------------
# 启动后做一次端到端健康检查：系统解析 → 劫持 → AGH → SmartDNS。
# 装机/升级后首次启动曾出现「SmartDNS 带着旧配置起来、6053 全挂」，
# 表现为整机解析失败、手动 sd-restart.sh 才好。这里实测一次，失败就清缓存重启。

# ---------------------------------------------------------------
# AGH API 端口与凭据：yaml 里的 http.address 端口才是真的（dns.port 是 DNS 端口，
# 两者不同）；账号密码优先用 config.prop 的 agh_user / agh_pass。
# ---------------------------------------------------------------
agh_api_port() {
    _ap=$(awk '/^http:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*address:/{print $2;exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/.*://')
    case "$_ap" in ''|*[!0-9]*) _ap=40251 ;; esac
    printf '%s' "$_ap"
}
agh_api_user() { printf '%s' "${agh_user:-root}"; }
agh_api_pass() { printf '%s' "${agh_pass:-root}"; }

sd_health_guard() {
    if ! net_up; then
        [ "$lang" = "zh" ] && log "[INFO] 当前没有默认路由（未联网 / 飞行模式），跳过 DNS 健康检查。" \
                            || log "[INFO] No default route yet (offline or airplane mode); skipping the DNS health check."
        return 0
    fi
    _try=0
    while [ "$_try" -lt 2 ]; do
        # 首先确认 6053 真的在听（ping 可能被 AGH 缓存骗过，端口不会说谎）
        if sd_listening && ping -c 1 -W 3 www.baidu.com >/dev/null 2>&1; then
            return 0
        fi
        # 中途断网（换 Wi-Fi / 蜂窝掉线）就别再重启 SmartDNS 了
        if ! net_up; then
            [ "$lang" = "zh" ] && log "[INFO] DNS 健康检查期间网络断开，跳过重启。" \
                                || log "[INFO] Network went away during the DNS health check; skipping restart."
            return 0
        fi
        _try=$((_try + 1))
        [ "$lang" = "zh" ] && log "[WARN] 启动后 DNS 解析失败（第 $_try 次），清 SmartDNS 缓存并重启。" \
                            || log "[WARN] DNS resolution failed right after boot (try $_try); clearing SmartDNS cache and restarting."
        pkill -9 -f '/usr/local/lib/smartdns/smartdns' 2>/dev/null
        rm -f "$SD_DIR"/var/lib/smartdns/smartdns.db-wal \
              "$SD_DIR"/var/lib/smartdns/smartdns.db-shm \
              "$SD_DIR"/run/*.pid "$SD_DIR"/var/run/*.pid 2>/dev/null
        _i=0
        while [ "$_i" -lt 24 ]; do
            pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1 || break
            sleep 0.25; _i=$((_i+1))
        done
        wait_port_free 6053
        start_smartdns
        sleep 2
    done
    [ "$lang" = "zh" ] && log "[WARN] DNS 仍不通，请检查上游 / 网络。" \
                        || log "[WARN] DNS still failing; check the upstreams and the network."
    return 0
}

agh_filter_heal() {

    if ! net_up; then
        [ "$lang" = "zh" ] && log "[INFO] 当前没有默认路由（未联网），跳过过滤器自愈，等下次联网后再补。" \
                            || log "[INFO] No default route yet; skipping the filter self-heal until the network is back."
        return 0
    fi

    if [ "${HAVE_CURL:-1}" != "1" ]; then
        log "[WARN] 本机没有 curl，跳过过滤器自愈（请手动在 6081/80 管理页刷新）。"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || return 0
    _port=$(awk '/^http:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*address:/{print $2;exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null)
    _port=${_port##*:}
    [ -n "$_port" ] || _port=40251
    _u=$(sed -n 's/^[[:space:]]*agh_user=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    _p=$(sed -n 's/^[[:space:]]*agh_pass=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    [ -n "$_u" ] || _u=root
    [ -n "$_p" ] || _p=root
    _ck="/data/local/tmp/.agh_ck.$$"
    # AGH 刚起来时 /control/* 路由可能还没注册完（首次启动实测返回
    # "404 page not found"，随后让整个自愈流程空转），所以这里轮询到登录成功。
    _lc=""
    _i=0
    while [ "$_i" -lt 20 ]; do
        _lc=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -c "$_ck" \
              -H "Content-Type: application/json" \
              -d "{\"name\":\"$_u\",\"password\":\"$_p\"}" \
              "http://127.0.0.1:$_port/control/login" 2>/dev/null)
        [ "$_lc" = "200" ] && break
        _i=$((_i + 1))
        sleep 1
    done
    if [ "$_lc" != "200" ]; then
        rm -f "$_ck"
        [ "$lang" = "zh" ] && log "[WARN] 无法登录 AGH API（HTTP ${_lc:-none}，改 config.prop 的 agh_user/agh_pass），跳过过滤器自愈。" \
                           || log "[WARN] AGH API login failed (HTTP ${_lc:-none}); set agh_user/agh_pass in config.prop to enable filter self-heal."
        return 0
    fi
    # 模块自带的拦截列表：没注册就先注册（不联网也能生效，装完立刻有拦截）
    _st=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null)
    _bl="$ADGPATH/rules/拦截列表.txt"
    if [ -f "$_bl" ] && ! printf '%s' "$_st" | grep -q '拦截列表\.txt'; then
        curl -s -m 120 -b "$_ck" -H "Content-Type: application/json" \
             -d "{\"data\":{\"name\":\"内置拦截列表\",\"url\":\"$_bl\",\"enabled\":true},\"url\":\"$_bl\",\"whitelist\":false}" \
             "http://127.0.0.1:$_port/control/filtering/add_url" >/dev/null 2>&1
        [ "$lang" = "zh" ] && log "已注册模块内置拦截列表：$_bl" \
                           || log "Registered the bundled blocklist: $_bl"
        _st=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null)
    fi
    # 模块内置的本地过滤器（OPPO 实测同款）：没注册就自动补注册
    # 色情网站/水印/反诈三件套/NoAppDownload/adaway/antiadblock
    for _bf in 色情网站.txt 水印.txt 反诈.txt 反诈类.txt 反诈和广告.txt NoAppDownload.txt adaway_hosts.txt antiadblockfilters.txt 应用隐私.txt 运营商追踪.txt 反诈上报.txt 腾讯广告.txt 基站WiFi隐私.txt; do
        _bfp="$ADGPATH/rules/$_bf"
        [ -f "$_bfp" ] || continue
        if ! printf '%s' "$_st" | grep -qF "$_bf"; then
            curl -s -m 120 -b "$_ck" -H "Content-Type: application/json" \
                 -d "{\"data\":{\"name\":\"${_bf%.txt}\",\"url\":\"$_bfp\",\"enabled\":true},\"url\":\"$_bfp\",\"whitelist\":false}" \
                 "http://127.0.0.1:$_port/control/filtering/add_url" >/dev/null 2>&1
            [ "$lang" = "zh" ] && log "已注册模块内置过滤器：$_bf" \
                               || log "Registered the bundled filter: $_bf"
            _st=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null)
        fi
    done
    # 内置过滤器自动注册后，AGH 用 URL 生成的名字是 "List <id>"，
    # 直接改 yaml 里的 name，仪表盘显示中文名
    _yf="$BIN_DIR/AdGuardHome.yaml"
    for _nm in 色情网站 水印 反诈 反诈类 反诈和广告 NoAppDownload adaway_hosts antiadblockfilters 拦截列表 应用隐私 运营商追踪 反诈上报 腾讯广告 基站WiFi隐私; do
        _lid=$(awk '/rules\/'"$_nm"'\.txt$/{getline; getline; if ($1=="id:") print $2}' "$_yf" 2>/dev/null)
        [ -n "$_lid" ] || continue
        sed -i "s/name: List $_lid/name: $_nm/" "$_yf" 2>/dev/null
    done
    _total=$(printf '%s' "$_st" | tr ',' '\n' | awk -F: '/rules_count/{gsub(/[^0-9]/,"",$2); s+=$2} END{print s+0}')
    # 零计数过滤器也要刷新：AGH fork 重启只解析部分本地过滤器，
    # 只要任何一个 filters 规则数为 0，就把它单独 refresh 一遍
    _zero_ids=$(awk '/^filters:/{f=1;next} f&&/^[^[:space:]-]/{exit} {if ($0 ~ /^[[:space:]]+id:/) {gsub(/[^0-9]/,"",$2); _id=$2} if ($0 ~ /^[[:space:]]+rules_count:/) {gsub(/[^0-9]/,"",$2); if (_id!="" && $2+0==0) printf "%s,", _id}}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/,$//')
    if [ -n "$_zero_ids" ]; then
        _r=""
        _i=0
        while [ "$_i" -lt 3 ]; do
            _r=$(curl -s -m 180 -b "$_ck" -H "Content-Type: application/json" \
                 -d "{\"whitelist\":false,\"ids\":[$_zero_ids]}" \
                 "http://127.0.0.1:$_port/control/filtering/refresh" 2>/dev/null)
            case "$_r" in
                *'"updated"'*) break ;;
            esac
            _i=$((_i + 1))
            sleep 2
        done
        [ "$lang" = "zh" ] && log "部分过滤器规则数为 0，已刷新：${_r:-noresp}" \
                           || log "Some filters had 0 rules; refreshed them: ${_r:-no response}"
    fi
    if [ "${_total:-0}" -eq 0 ]; then
        _ids=$(awk '/^filters:/{f=1;next} f&&/^[^[:space:]-]/{exit} f&&/^[[:space:]]+id:/{gsub(/[^0-9]/,"",$2); printf "%s,", $2}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/,$//')
        if [ -z "$_ids" ]; then
            rm -f "$_ck"
            return 0
        fi
        _r=""
        _i=0
        while [ "$_i" -lt 3 ]; do
            _r=$(curl -s -m 180 -b "$_ck" -H "Content-Type: application/json" \
                 -d "{\"whitelist\":false,\"ids\":[$_ids]}" \
                 "http://127.0.0.1:$_port/control/filtering/refresh" 2>/dev/null)
            # 路由未就绪时 busybox/AGH 会回 "404 page not found"，重试即可
            case "$_r" in
                *'"updated"'*) break ;;
            esac
            _i=$((_i + 1))
            sleep 2
        done
        [ "$lang" = "zh" ] && log "过滤器缓存为空，已触发重新下载：${_r:-noresp}" \
                           || log "Filter caches were empty; triggered a fresh download: ${_r:-no response}"
        _after=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null \
                 | tr ',' '\n' | awk -F: '/rules_count/{gsub(/[^0-9]/,"",$2); s+=$2} END{print s+0}')
        [ "$lang" = "zh" ] && log "过滤器自愈完成，规则总数 ${_after:-0}" \
                           || log "Filter self-heal done; total rules ${_after:-0}"
    else
        rm -f "$_ck"
    fi
}

# ---------------------------------------------------------------
# 启动 AdGuardHome
# ---------------------------------------------------------------
# ---------------------------------------------------------------
# 启动锁：service.sh 与 scripts/iptables.sh 的守护循环都会
# 「检测不到 AGH 就拉起」。开机瞬间两边可能同时判定「没在跑」，
# 于是各起一个实例抢同一个端口（实测出现过双 AGH 进程）。
# 用 mkdir 原子锁串行化：拿到锁才能启动，启动完释放；
# 拿不到锁就等对方把 AGH 拉起来，等到就跳过。
# ---------------------------------------------------------------
start_agh_locked() {
    _aghlk="$AGH_DIR/.agh.start.lock"
    if ! mkdir "$_aghlk" 2>/dev/null; then
        _i=0
        while [ "$_i" -lt 24 ]; do
            agh_running && break
            sleep 0.5
            _i=$((_i + 1))
        done
        if agh_running; then
            [ "$lang" = "zh" ] && log "AdGuardHome 已由其它进程启动，跳过。" \
                               || log "AdGuardHome already started by another process, skipping."
            return 0
        fi
        # 对方没能在 12 秒内拉起来，认为锁是残留，清掉后自己启动
        rm -rf "$_aghlk" 2>/dev/null
        mkdir "$_aghlk" 2>/dev/null || return 0
    fi
    if agh_running; then
        rm -rf "$_aghlk" 2>/dev/null
        return 0
    fi
    # yaml 的 dns.port 和 config.prop 的 redir_port 必须同源：
    # AGH 遇到端口占用会自己换端口并把新端口写回 yaml，写回来的只有 yaml，
    # config.prop 还留着旧值；nat 链是按 config.prop 建的，两者一旦分叉，
    # AGH 在新端口上跑、DNS 全打到旧端口 → 解析全断（实测漂到 44781 那回就是这样）。
    # 以 config.prop 为准回写 yaml（config.prop 才是 iptables 链的真理源）。
    _prop_port=$(sed -n 's/^redir_port=//p' "$AGH_DIR/scripts/config.prop" 2>/dev/null | tail -1)
    _yaml_port=$(sed -n '/^dns:/,/^[a-z]/s/^[ \t]*port:[ \t]*\([0-9][0-9]*\).*/\1/p' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | head -1)
    if [ -n "$_prop_port" ] && [ "$_prop_port" != "$_yaml_port" ]; then
        [ "$lang" = "zh" ] && log "yaml dns.port=$_yaml_port 与 config.prop redir_port=$_prop_port 不一致，按 config.prop 回写 yaml。" \
                           || log "yaml dns.port=$_yaml_port != config.prop redir_port=$_prop_port, rewriting yaml."
        awk -v P="$_prop_port" '
            /^dns:/ { f=1; print; next }
            f && /^[a-z]/ { f=0 }
            f && /^[ \t]*port:/ { sub(/port:[ \t]*[0-9]+/, "port: " P); f=0 }
            { print }
        ' "$BIN_DIR/AdGuardHome.yaml" > "$AGH_DIR/.yaml.tmp" 2>/dev/null \
            && mv -f "$AGH_DIR/.yaml.tmp" "$BIN_DIR/AdGuardHome.yaml"
    fi
    # 校验yaml，损坏则恢复备份
    if ! "$BIN_DIR/AdGuardHome" --check-config -c "$BIN_DIR/AdGuardHome.yaml" >/dev/null 2>&1; then
        [ "$lang" = "zh" ] && log "yaml 校验失败，恢复备份。" || log "yaml check failed, restoring backup."
        for bak in "$AGH_DIR/backup/AdGuardHome.yaml" "$BIN_DIR/AdGuardHome.yaml.bak"; do
            if [ -f "$bak" ]; then cp -f "$bak" "$BIN_DIR/AdGuardHome.yaml"; break; fi
        done
    fi
    # 学 SmartDNS：setsid 起独立会话/进程组，避免被外层进程组的冻结/清理连带
    setsid "$BIN_DIR/AdGuardHome" --no-check-update </dev/null >>"$AGH_DIR/agh-stdout.log" 2>&1 &
    sleep 1
    if agh_running; then
        [ "$lang" = "zh" ] && log "AdGuardHome 启动成功。" || log "AdGuardHome started successfully."
    else
        [ "$lang" = "zh" ] && log "AdGuardHome 启动失败，尝试重启..." || log "AdGuardHome failed to start, attempting restart..."
    fi
    rm -rf "$_aghlk" 2>/dev/null
    return 0
}

if ! agh_running; then
    start_agh_locked
fi

# 端到端健康检查：解析不通就重启 SmartDNS（装/升级后首次启动的老毛病）
# 注意：sd_health_guard / agh_filter_heal 都要发网络请求、还会重启 SmartDNS，
# 慢的时候能拖几十秒到几分钟。root 实现（ksud / magiskd）执行 service.sh 时
# 会等这个脚本退出，脚本里一阻塞，开机就会被拖住。所以这两步一律丢到后台，
# 前台只管「把进程拉起来」这件事。
(
    sd_health_guard
    agh_filter_heal
) </dev/null >>"$MAIN_LOG" 2>&1 &

# 修复 dnsproxyd socket 权限：init 创建的 /dev/socket/dnsproxyd 默认 srw-rw---- root:inet，
# uid 2000(shell) 不在 inet 组 → EACCES → DNS 解析直接失败（curl 等 shell 工具全断）。
# chmod 666 让所有用户都能连 dnsproxyd，DNS 查询经 netd → nat REDIRECT → AGH 正常解析。
if [ -e /dev/socket/dnsproxyd ]; then
    chmod 666 /dev/socket/dnsproxyd 2>/dev/null
    if [ "$lang" = "zh" ]; then log "dnsproxyd socket 权限已修复:666。"; else log "dnsproxyd socket permission fixed 666."; fi
fi


# 确保 yaml 里 sni_filter 配置完整：enabled=true，端口覆盖 80/443/8443 + Cloudflare 备用 TLS 端口，drop_quic=true
ensure_sni_filter() {
    _y="$BIN_DIR/AdGuardHome.yaml"
    [ -f "$_y" ] || return 0
    _af="$BIN_DIR/scripts/sni_filter.awk"
    [ -f "$_af" ] || return 0
    if grep -q '^sni_filter:' "$_y" 2>/dev/null; then
        _yt="$_y.sni.$$"
        awk -f "$_af" "$_y" > "$_yt" 2>/dev/null && cat "$_yt" > "$_y" 2>/dev/null
        rm -f "$_yt"
    else
        cat >> "$_y" <<SNI_EOF

sni_filter:
  enabled: true
  ports:
    - 80
    - 443
    - 8443
    - 2053
    - 2054
    - 2083
    - 2087
    - 2089
    - 2091
    - 2096
    - 2480
  queue_num: 7
  drop_quic: true
SNI_EOF
    fi
}

# 确保 SNI 过滤器配置完整（端口覆盖 + drop_quic），AGH 启动时强制执行
ensure_sni_filter

# 关闭 querylog 文件日志：AGH 默认间隔 1 天轮转写日志，规则加强后命中量暴增，
# 每天写 2GB 日志（累计 6.5GB 打满磁盘），AGH 与守护 I/O 压力巨大，被 ColorOS OFreezer
# 冻结连锁杀。只保留内存日志（面板查询够用），不落盘。
ensure_querylog_off() {
    _y="$BIN_DIR/AdGuardHome.yaml"
    [ -f "$_y" ] || return 0
    sed -i 's/^  file_enabled: true/  file_enabled: false/' "$_y" 2>/dev/null
    return 0
}
ensure_querylog_off

# 应用隐私防护规则（防 DNS/VPN/IP 泄露，配置在 /data/adb/agh/privacy.conf）
# 系统级 CA 幂等安装（HTTP S / MITM），保证 overlay 每次开机都在位
# ---- 内置默认脚本：缺失即释放 ----
# 目的：脚本页首次打开就有可用条目，而不是空表；用户可停用/删除，不会反复覆盖。
_REWRITE_DIR="$AGH_DIR/scripts/rewrite"
mkdir -p "$_REWRITE_DIR" 2>/dev/null
if [ ! -f "$_REWRITE_DIR/default.rewrite" ]; then
    for _src in "$AGH_DIR/scripts/rewrite/default.rewrite" "$MODDIR/scripts/rewrite/default.rewrite" \
                "/data/adb/modules/AdGuardHome/scripts/rewrite/default.rewrite"; do
        [ -f "$_src" ] && { cp -f "$_src" "$_REWRITE_DIR/default.rewrite" 2>/dev/null; break; }
    done
fi
if [ ! -f "$_REWRITE_DIR/privacy.rewrite" ]; then
    for _src in "$AGH_DIR/scripts/rewrite/privacy.rewrite" "$MODDIR/scripts/rewrite/privacy.rewrite" \
                "/data/adb/modules/AdGuardHome/scripts/rewrite/privacy.rewrite"; do
        [ -f "$_src" ] && { cp -f "$_src" "$_REWRITE_DIR/privacy.rewrite" 2>/dev/null; break; }
    done
fi
_certs_sh="$SCRIPT_DIR/certs_install.sh"
[ -f "$_certs_sh" ] && sh "$_certs_sh" >/dev/null 2>&1 &
# 改写脚本运行时：aghmitm（用模块内置 MITM CA 做 TLS 解密 + URL 重写）
# 建 /data/adb/agh/mitm_on 后开机自启，监听 127.0.0.1:8899
if [ -f "$AGH_DIR/mitm_on" ] && [ -x "$BIN_DIR/aghmitm" ]; then
    # 与守护循环里的 mitm_proc_guard 共用一把启动锁，避免开机同时起两个（抢 8899）
    _ml="$AGH_DIR/.mitm.start.lock"
    if mkdir "$_ml" 2>/dev/null; then
    date +%s > "$_ml/ts" 2>/dev/null
    if ! pgrep -f "$BIN_DIR/aghmitm" >/dev/null 2>&1; then
        _AGHD=$(awk '/^dns:/{f=1} f&&/^[[:space:]]+port:/{print $2; exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null)
        case "$_AGHD" in ''|*[!0-9]*)
            _AGHD=$(netstat -tlnup 2>/dev/null | grep AdGuardHome | grep udp | sed -n 's/.*[:.]\([0-9]*\) .*/\1/p' | head -1) ;;
        esac
        case "$_AGHD" in ''|*[!0-9]*) _AGHD=$(grep -oE '^redir_port=[0-9]+' "$AGH_DIR/scripts/config.prop" 2>/dev/null | cut -d= -f2) ;; esac
        setsid "$BIN_DIR/aghmitm" -listen 127.0.0.1:8899 -rules "$AGH_DIR/scripts/rewrite" -dns "127.0.0.1:${_AGHD:-5591}" >>"$AGH_DIR/mitm.log" 2>&1 &
fi
    rm -rf "$_ml" 2>/dev/null
    fi
fi
_privacy_cgi="$SCRIPT_DIR/webui/cgi-bin/privacy"
if [ -f "$_privacy_cgi" ]; then
    [ -f "$AGH_DIR/privacy.conf" ] || printf 'dns=1\nvpn=1\nip=1\nsb=0\npar=0\nntp=1\ndhcp=1\nsmb=1\ntcp=1\nsnmp=1\n' > "$AGH_DIR/privacy.conf" 2>/dev/null
    sh "$_privacy_cgi" --apply >/dev/null 2>&1 &
fi
# VPN DNS 共存：把 AGH 端口注入常见 VPN / 内核代理的 nameserver，
# 让 VPN 开着时应用解析仍走 AGH（否则 fake-ip 会完全接管 DNS，过滤失效）
_vpn_dns="$SCRIPT_DIR/vpn_dns_sync.sh"
if [ -f "$_vpn_dns" ]; then
    if ! pgrep -f "$_vpn_dns" >/dev/null 2>&1; then
        setsid sh "$_vpn_dns" >>"$AGH_DIR/vpn_dns.log" 2>&1 &
    fi
fi
# 过滤器缓存为空时自动重新下载（全新安装 / 跨版本升级后必备，否则没有拦截效果）
agh_rules_guard


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
# 模块目录里的文件一律不加 immutable：KernelSU/Magisk 应用更新时要把旧目录整棵
# rm -rf 再搬 modules_update 进来，只要有一个 +i（含目录上的 I 标志）就会删不动，
# 表现是「包刷进去了、res? 重启后还是旧版」。真机复现过一次：模块目录里
# scripts/webui/cgi-bin 及若干 cgi 带 I/i 标志，模块停在 11-25 的旧构建。
# 防篡改只锁 $SCRIPT_DIR（/data/adb/agh/scripts，不在模块目录里，替换不经过它）。
for _f in "$SCRIPT_DIR"/*.sh; do
    [ -f "$_f" ] && chattr +i "$_f" 2>/dev/null
done

# 日志超限时清空
[ -f "$MAIN_LOG" ] && [ "$(wc -c < "$MAIN_LOG")" -ge 102400 ] && : > "$MAIN_LOG"

# ---- 开机确定性重建：SNI/QUIC 链 ----
# 实测：开机早期 AGH 尚未就绪时，守护的首次 sni_sync 不会建成链，链会空上几分钟，
# 期间 SNI/QUIC 层完全没有拦截。这里等 AGH 起来后强制重建一次，直到 11 条 NFQUEUE 就位，
# 最长等 40 秒；之后仍有守护每 5 秒的自愈兜底。
_boot_built=0
_boot_t0=$(date +%s)
while [ $(( $(date +%s) - _boot_t0 )) -lt 40 ]; do
    if pidof AdGuardHome >/dev/null 2>&1 && \
       [ "$(iptables -S AGH_SNI 2>/dev/null | grep -c NFQUEUE)" -ge 11 ]; then
        _boot_built=1
        break
    fi
    if [ -f "$SCRIPT_DIR/iptables.sh" ]; then
        sh "$SCRIPT_DIR/iptables.sh" --sni-force >/dev/null 2>&1
    fi
    sleep 3
done
if [ "$_boot_built" = "1" ]; then
    log "[BOOT] SNI/QUIC 链已确定性重建完成（11 条 NFQUEUE）。"
else
    log "[WARN] [BOOT] 40 秒内未建成 SNI 链，交由守护自愈。"
fi

exit 0
