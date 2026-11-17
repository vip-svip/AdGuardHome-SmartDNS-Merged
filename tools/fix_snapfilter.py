import io, hashlib, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\customize.sh"
s = io.open(P, encoding="utf-8").read()
before = len(s.encode("utf-8"))

OLD = '''    # 快照里的 backup/ 就是原来的 BACKUP_DIR 内容
    if [ -d "$_snap/backup" ]; then
        cp -rf "$_snap/backup/." "$BACKUP_DIR/" 2>/dev/null
    fi
'''
NEW = '''    # 快照里的 backup/ 就是原来的 BACKUP_DIR 内容。
    # 逐个复制而不是 cp -rf 整个，避免把 v19 起已移除的 iptables-DROP规则.txt 带回来。
    if [ -d "$_snap/backup" ]; then
        for _bf in "$_snap"/backup/*; do
            [ -e "$_bf" ] || continue
            case "$(basename "$_bf")" in
                iptables-DROP*) continue ;;
                rules)
                    mkdir -p "$BACKUP_DIR/rules" 2>/dev/null
                    for _rf in "$_bf"/*; do
                        [ -f "$_rf" ] || continue
                        case "$(basename "$_rf")" in
                            iptables-DROP*) continue ;;
                        esac
                        cp -f "$_rf" "$BACKUP_DIR/rules/" 2>/dev/null
                    done
                    ;;
                *)
                    if [ -d "$_bf" ]; then
                        cp -rf "$_bf" "$BACKUP_DIR/" 2>/dev/null
                    else
                        cp -f "$_bf" "$BACKUP_DIR/" 2>/dev/null
                    fi
                    ;;
            esac
        done
    fi
'''

assert s.count(OLD) == 1, ("block count", s.count(OLD))
s = s.replace(OLD, NEW, 1)
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(P, "rb").read()
print("before:", before, "after:", len(raw), "delta:", len(raw) - before)
print("md5:", hashlib.md5(raw).hexdigest())