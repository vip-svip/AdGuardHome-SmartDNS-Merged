import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\cgi-bin\upstream"
s = io.open(P, encoding="utf-8").read()
orig = len(s.encode("utf-8"))

# ---------------------------------------------------------------
# 1. 变量：配置文件路径 + VPN 相关常量
# ---------------------------------------------------------------
var_anchor = 'DNSENC=/data/adb/agh/bin/dnsenc\nENCPORT=6054\n'
assert var_anchor in s
var_add = var_anchor + """
# ---- VPN 共存 ----
CFG=/data/adb/agh/scripts/config.prop
[ -f "$CFG" ] || CFG=/data/adb/modules/AdGuardHome/scripts/config.prop
VPN_PKGS_DEFAULT="com.github.metacubex.clash.meta com.github.kr328.clash com.follow.clash \\
com.nebula.clashmi com.getsurfboard com.v2ray.ang com.v2ray.ang.fdroid \\
io.nekohasekai.sagernet com.hxtunnel.vpn com.netrino.v2rayapp dev.minios.tgwsproxy"
"""
s = s.replace(var_anchor, var_add, 1)

# ---------------------------------------------------------------
# 2. 函数：插在 emit_enc 定义之前（保证定义在所有 action 之前）
# ---------------------------------------------------------------
fn_anchor = "emit_enc() {\n"
assert fn_anchor in s

fns = r"""
# =============================================================
# VPN 共存
# =============================================================
# 出接口是隧道就认为 VPN / 代理在跑。
# 必须排除内核自带的 tunl0（它的名字是 tun+l0，不是 tun+数字），否则恒判有 VPN。
vpn_ifaces() {
    ip -o link show up 2>/dev/null | awk -F': ' '{
        n = $2
        sub(/@.*/, "", n)
        if (n ~ /^(tun|tap|ppp|utun|wg|ipsec)[0-9]+$/) printf "%s ", n
    }'
}

vpn_mode() {
    m=""
    [ -f "$CFG" ] && m=$(sed -n 's/^[[:space:]]*vpn_compat=//p' "$CFG" 2>/dev/null | tail -1 | tr -d ' \r\n"')
    case "$m" in
        auto|proxy|off) ;;
        *) m=auto ;;
    esac
    printf '%s' "$m"
}

vpn_apps_raw() {
    a=""
    [ -f "$CFG" ] && a=$(sed -n 's/^[[:space:]]*vpn_apps=//p' "$CFG" 2>/dev/null | tail -1)
    a=$(printf '%s' "$a" | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')
    printf '%s' "$a"
}

pkg_uid() {
    _u=$(stat -c %u "/data/data/$1" 2>/dev/null)
    case "$_u" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$_u"; return 0 ;;
    esac
    pm list packages -U 2>/dev/null | sed -n "s/^package:$1 uid:\([0-9]*\).*/\1/p" | head -1
}

vpn_uids() {
    for _p in $VPN_PKGS_DEFAULT $(vpn_apps_raw); do
        _u=$(pkg_uid "$_p")
        case "$_u" in ''|*[!0-9]*) continue ;; esac
        printf '%s\n' "$_u"
    done | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//'
}

jump_present() {
    iptables -w 2 -t nat -C OUTPUT -j ADGUARD >/dev/null 2>&1
}

agh_rule_count() {
    n=$(iptables -w 2 -t nat -S ADGUARD 2>/dev/null | grep -c '^-A ADGUARD' 2>/dev/null)
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

agh_redirect_count() {
    n=$(iptables -w 2 -t nat -S ADGUARD 2>/dev/null | grep -c 'REDIRECT --to-ports' 2>/dev/null)
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

emit_vpn() {
    _mode=$(vpn_mode)
    _ifs=$(vpn_ifaces)
    _active=0
    [ -n "$(printf '%s' "$_ifs" | tr -d ' ')" ] && _active=1
    _jump=0; jump_present && _jump=1
    _rules=$(agh_rule_count)
    _red=$(agh_redirect_count)
    _hij=0
    [ "$_jump" -eq 1 ] && [ "$_red" -gt 0 ] && _hij=1
    _note=""
    if [ "$_mode" = auto ] && [ "$_active" -eq 1 ]; then
        _note="检测到 VPN，DNS 劫持已让路；VPN 断开后 5 秒内自动恢复"
    elif [ "$_mode" = auto ]; then
        _note="未检测到 VPN，DNS 劫持生效中"
    elif [ "$_mode" = proxy ]; then
        _note="串联模式：隧道出流量与 VPN 应用自身的查询不劫持"
    else
        _note="off：不做 VPN 判断，全量劫持"
    fi
    printf '{"ok":true,"mode":"%s","ifaces":"%s","vpn_active":%s,"jump":%s,"rules":%s,"redirect":%s,"hijack":%s,"uids":"%s","note":"%s"}' \
        "$(_json "$_mode")" "$(_json "$_ifs")" \
        "$([ "$_active" -eq 1 ] && echo true || echo false)" \
        "$([ "$_jump" -eq 1 ] && echo true || echo false)" \
        "$_rules" "$_red" \
        "$([ "$_hij" -eq 1 ] && echo true || echo false)" \
        "$(_json "$(vpn_uids)")" "$(_json "$_note")"
}

# 状态里的字符串也可能带引号/反斜杠，和 json_esc 走同一套
_json() { json_esc "$1"; }

# 等 iptables 守护循环（5s 一跳）把规则改成目标状态
wait_vpn_settle() {
    _want="$1"
    _n=0
    while [ "$_n" -lt 24 ]; do
        _m=$(vpn_mode)
        [ "$_m" = "$_want" ] || { sleep 0.3; _n=$((_n+1)); continue; }
        _ifs=$(vpn_ifaces)
        _has=$(printf '%s' "$_ifs" | tr -d ' ')
        case "$_m" in
            auto)
                if [ -n "$_has" ]; then
                    jump_present || return 0
                else
                    jump_present && [ "$(agh_redirect_count)" -gt 0 ] && return 0
                fi
                ;;
            *)
                jump_present && [ "$(agh_redirect_count)" -gt 0 ] && return 0
                ;;
        esac
        sleep 0.3
        _n=$((_n+1))
    done
    return 1
}

emit_enc() {
"""
s = s.replace(fn_anchor, fns.lstrip("\n"), 1)

# ---------------------------------------------------------------
# 3. action 分支：插在 encrestart 之后、*) 之前
# ---------------------------------------------------------------
act_anchor = """*)
    fail "未知 action：$action"
    ;;
esac"""
assert act_anchor in s

acts = r"""vpnstatus)
    hdr
    emit_vpn
    ;;

vpnmode)
    hdr
    m=$(trim "$(printf '%s' "${mode:-}" )")
    case "$m" in
        auto|proxy|off) ;;
        *) fail "mode 只能是 auto / proxy / off" ;;
    esac
    [ -f "$CFG" ] || fail "找不到配置文件：$CFG"
    if grep -qE '^[[:space:]]*vpn_compat=' "$CFG"; then
        sed -i "s|^[[:space:]]*vpn_compat=.*|vpn_compat=$m|" "$CFG"
    else
        [ -n "$(tail -c 1 "$CFG" 2>/dev/null)" ] && printf '\n' >> "$CFG"
        printf 'vpn_compat=%s\n' "$m" >> "$CFG"
    fi
    if wait_vpn_settle "$m"; then
        printf '{"ok":true,"msg":"已切换为 %s，规则已按新模式重建","mode":"%s"' "$m" "$m"
    else
        printf '{"ok":true,"msg":"已写入 %s，规则重建中（守护循环 5 秒内生效）","mode":"%s"' "$m" "$m"
    fi
    printf ',"ifaces":"%s","vpn_active":%s' \
        "$(_json "$(vpn_ifaces)")" \
        "$([ -n "$(printf '%s' "$(vpn_ifaces)" | tr -d ' ')" ] && echo true || echo false)"
    _j=0; jump_present && _j=1
    printf ',"jump":%s,"rules":%s,"redirect":%s' \
        "$([ "$_j" -eq 1 ] && echo true || echo false)" "$(agh_rule_count)" "$(agh_redirect_count)"
    _h=0
    [ "$_j" -eq 1 ] && [ "$(agh_redirect_count)" -gt 0 ] && _h=1
    printf ',"hijack":%s,"uids":"%s","note":"%s"}' \
        "$([ "$_h" -eq 1 ] && echo true || echo false)" \
        "$(_json "$(vpn_uids)")" "模式已切换为 $m"
    ;;

*)
    fail "未知 action：$action"
    ;;
esac"""

s = s.replace(act_anchor, acts, 1)

# ---------------------------------------------------------------
# 4. 参数解析加 mode
# ---------------------------------------------------------------
s = s.replace('''action=""
srv=""
dom=""
target=""
''', '''action=""
srv=""
dom=""
target=""
mode=""
''', 1)
s = s.replace('''        target) target=$(urldecode "$v") ;;''',
              '''        target) target=$(urldecode "$v") ;;
        mode)   mode=$(urldecode "$v") ;;''', 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("cgi-bin/upstream:", orig, "->", len(s.encode("utf-8")), "B")
for k in ("vpn_ifaces", "emit_vpn", "vpnstatus)", "vpnmode)", "wait_vpn_settle", "mode=$(urldecode"):
    print("  ", k, "x", s.count(k))