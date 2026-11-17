import io, hashlib, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\customize.sh"
s = io.open(P, encoding="utf-8").read()
before = len(s.encode("utf-8"))

ANCHOR = 'mkdir -p "$AGH_DIR" "$BIN_DIR" "$SCRIPT_DIR" "$BACKUP_DIR"'
assert s.count(ANCHOR) == 1, ("anchor count", s.count(ANCHOR))

BLOCK = ANCHOR + r'''

# 卸载时 uninstall.sh 会把用户数据搬到 /data/adb/agh-uninstalled-<时间>/ 保留下来。
# 若是卸载后重装（BACKUP_DIR 为空），自动把最新快照灌回 BACKUP_DIR，
# 让后面的“恢复原有配置”逻辑照常生效，用户不必手动搬文件。
restore_uninstall_snapshot() {
    [ -f "$BACKUP_DIR/AdGuardHome.yaml" ] && return 0    # 已有备份，无需快照
    _snap=""
    for _d in /data/adb/agh-uninstalled-*; do
        [ -d "$_d" ] || continue
        if [ -z "$_snap" ] || [ "$_d" \> "$_snap" ]; then _snap="$_d"; fi
    done
    [ -n "$_snap" ] || return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    # 快照里的 backup/ 就是原来的 BACKUP_DIR 内容
    if [ -d "$_snap/backup" ]; then
        cp -rf "$_snap/backup/." "$BACKUP_DIR/" 2>/dev/null
    fi
    [ -f "$_snap/AdGuardHome.yaml" ] && cp -f "$_snap/AdGuardHome.yaml" "$BACKUP_DIR/AdGuardHome.yaml" 2>/dev/null
    if [ -d "$_snap/smartdns-etc" ]; then
        mkdir -p "$BACKUP_DIR/smartdns" 2>/dev/null
        cp -rf "$_snap/smartdns-etc/." "$BACKUP_DIR/smartdns/" 2>/dev/null
    fi
    if [ -d "$_snap/rules" ]; then
        mkdir -p "$BACKUP_DIR/rules" 2>/dev/null
        for _f in "$_snap"/rules/*; do
            [ -f "$_f" ] || continue
            case "$(basename "$_f")" in
                iptables-DROP*) continue ;;
            esac
            cp -f "$_f" "$BACKUP_DIR/rules/" 2>/dev/null
        done
    fi
    [ -f "$_snap/hosts/hosts" ] && cp -f "$_snap/hosts/hosts" "$BACKUP_DIR/hosts" 2>/dev/null
    i18n_print "- Restored user data from $_snap" "- 已从卸载快照恢复用户数据：$_snap"
    return 0
}
restore_uninstall_snapshot'''

s = s.replace(ANCHOR, BLOCK, 1)
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(P, "rb").read()
print("before:", before, "after:", len(raw), "delta:", len(raw) - before)
print("md5:", hashlib.md5(raw).hexdigest())
print("anchor left:", s.count(ANCHOR))
print("func count:", s.count("restore_uninstall_snapshot"))