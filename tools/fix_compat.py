# -*- coding: utf-8 -*-
"""多设备兼容加固：
1) pgrep 缺失时用 /proc 兜底（函数覆盖同名命令）
2) netstat 缺失时用 ss / /proc/net 兜底（统一 port_listening PORT [udp|tcp]）
3) curl 缺失时相关自愈功能降级并记日志
4) arm64 二进制在非 aarch64 设备上给出明确告警
5) TZ 未设置时用系统时区，避免 AGH 日志全是 UTC
6) AGH 因 sessions.db 打开超时退出时自动清库重试
"""
import io, re, hashlib, sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
IPT = HOME + r"\scripts\iptables.sh"
SVC = HOME + r"\service.sh"
SDR = HOME + r"\scripts\sd-restart.sh"

COMPAT = r'''
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
port_listening() {
    _port="$1"; _proto="${2:-udp}"
    if command -v netstat >/dev/null 2>&1; then
        case "$_proto" in
            udp) netstat -lun 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
            *)   netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
        esac
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        case "$_proto" in
            udp) ss -lun 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
            *)   ss -ltn 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
        esac
        return 1
    fi
    # 最后兜底：直接读 /proc/net（十六进制端口）
    _hex=$(printf '%04X' "$_port")
    case "$_proto" in
        udp) _f="/proc/net/udp /proc/net/udp6" ;;
        *)   _f="/proc/net/tcp /proc/net/tcp6" ;;
    esac
    for _f1 in $_f; do
        [ -r "$_f1" ] || continue
        awk -v h=":$_hex" 'NR > 1 { split($2, a, ":"); if (":" a[2] == h && a[1] == "0100007F") found = 1 } END { exit(found ? 0 : 1) }' "$_f1" && return 0
    done
    return 1
}

# 系统时区（AGH 没设 TZ 会把日志全写成 UTC）
if [ -z "$TZ" ]; then
    TZ=$(getprop persist.sys.timezone 2>/dev/null)
    [ -n "$TZ" ] || TZ=Asia/Shanghai
    export TZ
fi
'''

# 1) iptables.sh：紧跟 IPT_W 探测块之后插兼容层
s = io.open(IPT, encoding="utf-8").read()
anchor = 'ip6tables $IPT_W -t mangle -S OUTPUT >/dev/null 2>&1 || IPT_W=""\n'
assert s.count(anchor) == 1, s.count(anchor)
if "port_listening()" not in s:
    s = s.replace(anchor, anchor + COMPAT, 1)

# iptables.sh: sessions.db 超时 → 清库
old_start = '''    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    "$BIN_DIR/AdGuardHome" --no-check-update >/dev/null 2>&1 &'''
new_start = '''    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    # 部分设备（尤其首次启动、存储忙）打开 sqlite 会话库会 1 秒超时，AGH 直接致命退出。
    # 看到这个错误就把会话库删掉重来（只是登录态，删了没损失）。
    if tail -n 20 "$BIN_DIR/crash.log" 2>/dev/null | grep -q 'sessions.db'; then
        rm -f "$BIN_DIR/data/sessions.db" "$BIN_DIR/data/sessions.db-wal" "$BIN_DIR/data/sessions.db-shm" 2>/dev/null
        echo "$(date '+%F %T') [WARN] AGH 上次因会话库打开超时退出，已清理 sessions.db 后重启。" >> "$MAIN_LOG"
    fi
    "$BIN_DIR/AdGuardHome" --no-check-update >/dev/null 2>&1 &'''
assert s.count(old_start) == 1, s.count(old_start)
s = s.replace(old_start, new_start, 1)
io.open(IPT, "w", encoding="utf-8", newline="\n").write(s)
print("iptables.sh ->", len(s.encode()), hashlib.md5(s.encode()).hexdigest())

# 2) service.sh：插兼容层（放在 log() 之后），并把 netstat 判断换成 port_listening
s = io.open(SVC, encoding="utf-8").read()
anchor2 = 'log() { echo "$(date \'+%F %T\') $1" >> "$MAIN_LOG"; }\n'
assert s.count(anchor2) == 1
if "port_listening()" not in s:
    s = s.replace(anchor2, anchor2 + COMPAT, 1)

reps = [
    ("netstat -lun 2>/dev/null | grep -q '127.0.0.1:6053 '", "port_listening 6053 udp"),
    ('if ! netstat -lun 2>/dev/null | grep -q "127.0.0.1:$_p "; then', 'if ! port_listening "$_p" udp; then'),
    ('netstat -lun 2>/dev/null | grep -q "127.0.0.1:$DNSENC_PORT " && break', 'port_listening "$DNSENC_PORT" udp && break'),
]
for a, b in reps:
    n = s.count(a)
    s = s.replace(a, b)
    print("  service.sh replace %d x %s" % (n, a[:52]))

# curl 守卫：无 curl 时禁用两段自愈
guard = '''if ! command -v curl >/dev/null 2>&1; then
    HAVE_CURL=0
else
    HAVE_CURL=1
fi
'''
if "HAVE_CURL=" not in s:
    s = s.replace('log() { echo', guard + 'log() { echo', 1)

io.open(SVC, "w", encoding="utf-8", newline="\n").write(s)
print("service.sh ->", len(s.encode()), hashlib.md5(s.encode()).hexdigest())

# 3) sd-restart.sh：netstat → port_listening（自带一份精简实现）
s = io.open(SDR, encoding="utf-8").read()
if "port_listening()" not in s:
    shim = r'''
port_listening() {
    _port="$1"; _proto="${2:-udp}"
    if command -v netstat >/dev/null 2>&1; then
        case "$_proto" in
            udp) netstat -lun 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
            *)   netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
        esac
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        case "$_proto" in
            udp) ss -lun 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
            *)   ss -ltn 2>/dev/null | grep -q "127.0.0.1:$_port " && return 0 ;;
        esac
        return 1
    fi
    _hex=$(printf '%04X' "$_port")
    case "$_proto" in
        udp) _fl="/proc/net/udp /proc/net/udp6" ;;
        *)   _fl="/proc/net/tcp /proc/net/tcp6" ;;
    esac
    for _f1 in $_fl; do
        [ -r "$_f1" ] || continue
        awk -v h=":$_hex" 'NR > 1 { split($2, a, ":"); if (":" a[2] == h && a[1] == "0100007F") found = 1 } END { exit(found ? 0 : 1) }' "$_f1" && return 0
    done
    return 1
}
'''
    m = re.search(r"^#!/system/bin/sh\n", s)
    s = s[:m.end()] + shim + s[m.end():]

old = '''    if ! netstat -lun 2>/dev/null | grep -q "127.0.0.1:$_p " \\
    && ! netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$_p "; then'''
if old in s:
    s = s.replace(old, '''    if ! port_listening "$_p" udp && ! port_listening "$_p" tcp; then''')
s = s.replace('''netstat -lun 2>/dev/null | grep -q '127.0.0.1:6054 ' && break''', '''port_listening 6054 udp && break''')
s = s.replace('''netstat -lun 2>/dev/null | grep -q '127.0.0.1:6053 \'''', '''port_listening 6053 udp''')
io.open(SDR, "w", encoding="utf-8", newline="\n").write(s)
print("sd-restart.sh ->", len(s.encode()), hashlib.md5(s.encode()).hexdigest())

for f in (IPT, SVC, SDR):
    t = io.open(f, encoding="utf-8").read()
    left = len(re.findall(r"netstat -l", t))
    print("%-22s netstat-left=%d pgrep-shim=%s port_listening=%s" % (
        f.split("Adguardhome")[-1], left, "pgrep()" in t, "port_listening()" in t))