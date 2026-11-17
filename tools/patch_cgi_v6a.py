import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

CGI = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\cgi-bin\upstream"
s = io.open(CGI, encoding="utf-8").read()

# ---------- 1) 新增 v6 相关函数（插在 emit_vpn 之前） ----------
FUNCS = '''# ---- IPv6 的 DNS 劫持状态（v6_dns：auto / redirect / drop / keep）----
v6_mode_raw() {
    m=""
    [ -f "$CFG" ] && m=$(sed -n 's/^[[:space:]]*v6_dns=//p' "$CFG" 2>/dev/null | tail -1)
    m=$(printf '%s' "$m" | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//')
    printf '%s' "$m"
}

v6_nat_ok() {
    ip6tables -w 2 -t nat -L -n >/dev/null 2>&1
}

v6_effective_mode() {
    m=$(v6_mode_raw)
    case "$m" in
        keep|drop|redirect) printf '%s' "$m" ;;
        *) if v6_nat_ok; then printf 'redirect'; else printf 'drop'; fi ;;
    esac
}

v6_hijack_on() {
    case "$(v6_effective_mode)" in
        drop)     ip6tables -w 2 -t mangle -C OUTPUT -j AGH_V6DNS >/dev/null 2>&1 ;;
        redirect) ip6tables -w 2 -t nat -C OUTPUT -j ADGUARD6 >/dev/null 2>&1 ;;
        *)        return 1 ;;
    esac
}

emit_vpn() {'''

assert "emit_vpn() {" in s
s = s.replace("emit_vpn() {", FUNCS, 1)

# ---------- 2) emit_vpn 里补 v6 字段 ----------
OLD_NOTE_TAIL = '''    printf '{"ok":true,"mode":"%s","ifaces":"%s","vpn_active":%s,"jump":%s,"rules":%s,"redirect":%s,"hijack":%s,"uids":"%s","note":"%s"}' \\'''
NEW_NOTE_TAIL = '''    _v6m=$(v6_effective_mode)
    _v6on=0
    v6_hijack_on && _v6on=1
    printf '{"ok":true,"mode":"%s","ifaces":"%s","vpn_active":%s,"jump":%s,"rules":%s,"redirect":%s,"hijack":%s,"v6_mode":"%s","v6_hijack":%s,"v6_nat":%s,"uids":"%s","note":"%s"}' \\'''
assert OLD_NOTE_TAIL in s
s = s.replace(OLD_NOTE_TAIL, NEW_NOTE_TAIL, 1)

OLD_ARGS = '''        "$(_json "$(vpn_uids)")" "$(_json "$_note")"'''
NEW_ARGS = '''        "$(_json "$_v6m")" \\
        "$([ "$_v6on" -eq 1 ] && echo true || echo false)" \\
        "$([ "$(v6_nat_ok)" ] && echo true || echo false)" \\
        "$(_json "$(vpn_uids)")" "$(_json "$_note")"'''
assert OLD_ARGS in s
s = s.replace(OLD_ARGS, NEW_ARGS, 1)
# v6_nat_ok 是函数，不是值 —— 修正成子 shell
s = s.replace('"$([ "$(v6_nat_ok)" ] && echo true || echo false)"',
              '"$(if v6_nat_ok; then echo true; else echo false; fi)"')

io.open(CGI, "w", encoding="utf-8", newline="\n").write(s)
print("CGI(第一阶段):", len(s.encode()), hashlib.md5(s.encode()).hexdigest())