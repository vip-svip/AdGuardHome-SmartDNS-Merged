import io
p = r"F:\BUG\AdguardHome-Magisk\Adguardhome\customize.sh"
s = io.open(p, encoding="utf-8").read()

# BUG: PROXY_URL 用 printf "%s" 追加（无换行），下一行会被拼到它后面
#      实测 PROXY_URL="http://1.2.3.4:7890"vpn_compat=proxy → vpn_compat 失效
old = 'printf "%s" "$old_line" >> "$SCRIPT_DIR/config.prop"'
assert s.count(old) == 1, "printf anchor %d" % s.count(old)
s = s.replace(old, 'printf "%s\\n" "$old_line" >> "$SCRIPT_DIR/config.prop"')

# vpn 保留段追加前先补换行（万一备份里最后一行无换行）
old2 = ('    sed -i "/^[[:space:]]*$_k=/d" "$SCRIPT_DIR/config.prop" 2>/dev/null\n'
        '    printf "%s\\n" "$_kv" >> "$SCRIPT_DIR/config.prop"\n')
new2 = ('    sed -i "/^[[:space:]]*$_k=/d" "$SCRIPT_DIR/config.prop" 2>/dev/null\n'
        '    [ -n "$(tail -c 1 "$SCRIPT_DIR/config.prop" 2>/dev/null)" ] && printf "\\n" >> "$SCRIPT_DIR/config.prop"\n'
        '    printf "%s\\n" "$_kv" >> "$SCRIPT_DIR/config.prop"\n')
assert s.count(old2) == 1, "vpn append anchor %d" % s.count(old2)
s = s.replace(old2, new2)

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("OK bytes=%d" % len(s.encode("utf-8")))