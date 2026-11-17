import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

BASE = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
def rd(p): return io.open(p, encoding="utf-8").read()
def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)
    raw = io.open(p, "rb").read()
    return len(raw), hashlib.md5(raw).hexdigest()

# ============ 1. smartdns.conf: data-dir 移到持久目录 ============
p = BASE + r"\smartdns\etc\smartdns\smartdns.conf"
s = rd(p)
old = "data-dir /tmp/smartdns"
assert s.count(old) == 1, s.count(old)
new = ("# 数据目录必须是持久路径！smartdns 的 UI 插件把 smartdns.db（查询日志/客户端/上游统计）\n"
       "# 建在 data-dir 下；若 data-dir 落在 tmpfs（旧版的 /tmp/smartdns），开机时目录不存在→\n"
       "# 建库失败→UI 的 statvfs 返回 0→is_process_suspended=true→「服务器请求处理已暂停」，\n"
       "# 所有查询直接被丢弃。放到 /var/lib/smartdns（真实磁盘）后该问题不再复现。\n"
       "data-dir /var/lib/smartdns")
s = s.replace(old, new, 1)
if "smartdns-ui.max-query-log-age" not in s:
    s = s.rstrip("\n") + "\n# UI 数据库保留 7 天查询日志，避免 smartdns.db 无限增长\nsmartdns-ui.max-query-log-age 7\n"
print("smartdns.conf", wr(p, s))

# ============ 2. service.sh ============
p = BASE + r"\service.sh"
s = rd(p)

# 2a. 在 sd_mounts 之前插入 data-dir 保护函数
anchor = '''sd_mounts() {
    mkdir -p "$SD_DIR/dev" "$SD_DIR/proc" "$SD_DIR/sys" "$SD_DIR/tmp" "$SD_DIR/run" 2>/dev/null'''
assert s.count(anchor) == 1

SD_DATADIR = '''# ---------------------------------------------------------------
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
    [ "$lang" = "zh" ] >/dev/null 2>&1
    _bb=""
    for _c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
        [ -x "$_c" ] && { _bb="$_c"; break; }
    done
    [ -n "$_bb" ] || return 0
    _tok=$("$_bb" wget -qO- --post-data='{"username":"root","password":"root"}' \
        --header='Content-Type: application/json' http://127.0.0.1:6080/api/auth/login 2>/dev/null \
        | sed -n 's/.*"token":"\\([^"]*\\)".*/\\1/p')
    [ -n "$_tok" ] || return 0
    _ov=$("$_bb" wget -qO- --header="Authorization: Bearer $_tok" http://127.0.0.1:6080/api/stats/overview 2>/dev/null)
    case "$_ov" in
    *'"is_process_suspended":true'*)
        log "[WARN] SmartDNS 因磁盘空间守卫暂停了请求处理，重建数据目录并重启 SmartDNS"
        sd_datadir_guard
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
    mkdir -p "$SD_DIR/dev" "$SD_DIR/proc" "$SD_DIR/sys" "$SD_DIR/tmp" "$SD_DIR/run" 2>/dev/null'''
s = s.replace(anchor, SD_DATADIR, 1)

# 2b. start_smartdns 里先执行 guard
old_start = '''start_smartdns() {
    [ -x "$SMARTDNS_BIN" ] || return 1
    smartdns_running && return 0
    sd_mounts'''
new_start = '''start_smartdns() {
    [ -x "$SMARTDNS_BIN" ] || return 1
    smartdns_running && return 0
    sd_datadir_guard
    sd_mounts'''
assert s.count(old_start) == 1
s = s.replace(old_start, new_start, 1)

# 2c. 启动顺序里加 suspend guard
old_call = '''sd_config_guard
sd_enc_guard
start_dnsenc
start_smartdns'''
new_call = '''sd_config_guard
sd_enc_guard
start_dnsenc
start_smartdns
sd_suspend_guard'''
assert s.count(old_call) == 1
s = s.replace(old_call, new_call, 1)
print("service.sh", wr(p, s))

# ============ 3. sd-restart.sh ============
p = BASE + r"\scripts\sd-restart.sh"
s = rd(p)
old = '''mkdir -p "$SD/dev" "$SD/proc" "$SD/sys" "$SD/tmp" "$SD/run"'''
assert s.count(old) == 1
new = '''mkdir -p "$SD/dev" "$SD/proc" "$SD/sys" "$SD/tmp" "$SD/run"
# SmartDNS UI 数据库目录（必须持久且可写，否则 UI 判定磁盘空间为 0 会暂停请求处理）
mkdir -p "$SD/var/lib/smartdns" "$SD/var/cache/smartdns" "$SD/var/log/smartdns" 2>/dev/null
chown 9999:9999 "$SD/var/lib/smartdns" "$SD/var/cache/smartdns" 2>/dev/null
# 老配置 data-dir 还在 tmpfs 上就迁走
if [ -f "$CONF" ] && grep -qE '^[[:space:]]*data-dir[[:space:]]+/tmp/' "$CONF" 2>/dev/null; then
    sed -i "s|^[[:space:]]*data-dir[[:space:]].*|data-dir /var/lib/smartdns|" "$CONF"
fi'''
s = s.replace(old, new, 1)
print("sd-restart.sh", wr(p, s))

# ============ 4. CGI flush：不删数据库 ============
p = BASE + r"\scripts\webui\cgi-bin\upstream"
s = rd(p)
old = 'rm -rf "$SD/tmp/smartdns" 2>/dev/null'
assert s.count(old) == 1, s.count(old)
new = ('# 只清缓存文件，绝不删 data-dir 目录本身：smartdns.db（UI 数据库）在里面，\n'
       '    # 目录被删会导致 UI 报「服务器请求处理已暂停」并丢弃所有查询。\n'
       '    rm -f "$SD/var/lib/smartdns/smartdns.cache" "$SD/var/cache/smartdns/smartdns.cache" 2>/dev/null\n'
       '    rm -f "$SD/tmp/smartdns.cache" "$SD/tmp/smartdns/smartdns.cache" 2>/dev/null')
s = s.replace(old, new, 1)
print("cgi upstream", wr(p, s))

# ============ 5. customize.sh：安装时建目录 ============
p = BASE + r"\customize.sh"
s = rd(p)
anchor = 'i18n_print "- Extracting SmartDNS chroot files" "- 正在解压 SmartDNS 文件"'
assert s.count(anchor) == 1
add = anchor + '''

# SmartDNS UI 数据库目录必须是持久可写目录（data-dir 指向这里）。
# 装完立刻建好，避免首次启动时 UI 建库失败 → 报「服务器请求处理已暂停」。
for _sdv in "var/lib/smartdns" "var/cache/smartdns" "var/log/smartdns"; do
    mkdir -p "$AGH_DIR/smartdns/$_sdv" 2>/dev/null
done
chown 9999:9999 "$AGH_DIR/smartdns/var/lib/smartdns" "$AGH_DIR/smartdns/var/cache/smartdns" 2>/dev/null
chmod 755 "$AGH_DIR/smartdns/var/lib/smartdns" "$AGH_DIR/smartdns/var/cache/smartdns" 2>/dev/null'''
s = s.replace(anchor, add, 1)
print("customize.sh", wr(p, s))
print("\nALL PATCHED")