import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
p = r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh"
s = io.open(p, encoding="utf-8").read()

# 1) 主流程无条件执行目录保护（原来只在 start_smartdns 内部、且被 running 提前 return 跳过）
old = '''sd_config_guard
sd_enc_guard
start_dnsenc
start_smartdns
sd_suspend_guard'''
new = '''# 先修目录（权限/属主/data-dir 迁移），再谈启动；smartdns 已在跑时这条同样要执行，
# 否则「目录不可写」这类状态永远修不回来。
sd_datadir_guard
sd_config_guard
sd_enc_guard
start_dnsenc
start_smartdns
sd_suspend_guard'''
assert s.count(old) == 1
s = s.replace(old, new, 1)

# 2) 自愈判据放宽：suspended=true 或 free_disk_space=0 或 database_size=0 都要修
old2 = '''    case "$_ov" in
    *'"is_process_suspended":true'*)
        log "[WARN] SmartDNS 因磁盘空间守卫暂停了请求处理，重建数据目录并重启 SmartDNS"'''
new2 = '''    case "$_ov" in
    *'"is_process_suspended":true'*|*'"free_disk_space":0'*|*'"database_size":0'*)
        log "[WARN] SmartDNS 数据目录不可用（磁盘守卫/建库失败），修复目录并重启 SmartDNS"'''
assert s.count(old2) == 1
s = s.replace(old2, new2, 1)

# 3) 自愈里显式恢复权限
old3 = '''        sd_datadir_guard
        rm -f "$SD_DB-shm" "$SD_DB-wal" 2>/dev/null'''
new3 = '''        sd_datadir_guard
        chmod 755 "$SD_VARDIR" "$SD_VARCACHE" 2>/dev/null
        chown 9999:9999 "$SD_VARDIR" "$SD_VARCACHE" 2>/dev/null
        rm -f "$SD_DB-shm" "$SD_DB-wal" 2>/dev/null'''
assert s.count(old3) == 1
s = s.replace(old3, new3, 1)

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(p, "rb").read()
print("service.sh", len(raw), hashlib.md5(raw).hexdigest())
print("sd_datadir_guard calls:", s.count("sd_datadir_guard"))
print("sd_suspend_guard calls:", s.count("sd_suspend_guard"))