#!/system/bin/sh
# 6081 管理面自检（真机跑）：sh tests/webui_check.sh
# 覆盖：存活 / 延迟 / 只读性（GET 不改规则）/ JSON 形态 / 关键端口 / 隐私规则覆盖
# 退出码 0 = 全过，1 = 有 FAIL
HOST=127.0.0.1
PORT=6081
BASE="http://$HOST:$PORT/cgi-bin"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
info() { printf '\n[%s]\n' "$1"; }

# 单次请求：输出 "耗时秒|首字节|总字节"
req() { # $1=url  $2=输出文件
    curl -s -o "$2" -w '%{time_total}|%{http_code}|%{size_download}' "$1" 2>/dev/null
}
ms() { echo "$1" | awk -F'|' '{printf "%d", $1*1000}'; }
code() { echo "$1" | awk -F'|' '{print $2}'; }
size() { echo "$1" | awk -F'|' '{print $3}'; }

json_ok() { # 粗校验：以 { 开头、以 } 结尾、括号配平
    _s=$(tr -d ' \r\n' < "$1" 2>/dev/null)
    case "$_s" in
        \{*\}) ;;
        *) return 1 ;;
    esac
    _open=$(printf '%s' "$_s" | tr -cd '{' | wc -c)
    _close=$(printf '%s' "$_s" | tr -cd '}' | wc -c)
    [ "$_open" = "$_close" ]
}

info "1. 端口与进程"
netstat -tln 2>/dev/null | grep -q ":$PORT " && ok "httpd 监听 $PORT" || bad "httpd 未监听 $PORT"
netstat -tlnp 2>/dev/null | grep -q AdGuardHome && ok "AdGuardHome 在跑" || bad "AdGuardHome 不在"
pidof smartdns >/dev/null 2>&1 && ok "smartdns 在跑" || bad "smartdns 不在"
pidof aghmitm >/dev/null 2>&1 && ok "aghmitm 在跑" || bad "aghmitm 不在"

info "2. 各 CGI 延迟（目标：GET ≤400ms，冷缓存首访）"
for c in privacy scripts apps certs mitm upstream; do
    _r=$(req "$BASE/$c" "/data/local/tmp/_chk_$c")
    _m=$(ms "$_r")
    if [ "$(code "$_r")" != "200" ]; then bad "$c HTTP $(code "$_r")"; continue; fi
    if [ "$_m" -le 400 ]; then ok "$c ${_m}ms $(size "$_r")B"; else bad "$c ${_m}ms 超 400ms"; fi
    json_ok "/data/local/tmp/_chk_$c" || bad "$c 输出不是合法 JSON 形态"
done

info "3. GET 只读性：连续 5 次 privacy GET 不得改动 AGH_PRIV"
_b1=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
_b6=$(ip6tables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
for i in 1 2 3 4 5; do curl -s -o /dev/null "$BASE/privacy" 2>/dev/null; done
_a1=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
_a6=$(ip6tables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
if [ "$_b1" = "$_a1" ]; then
    ok "v4 AGH_PRIV 未被 GET 改动"
else
    # xtables 锁被 netd/AGH 短暂占用时 -S 会吐空串 → 重采样两次仍不一致才算真改
    _r1=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | md5sum); sleep 2
    _r2=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
    if [ -n "$_r1" ] && [ "$_r1" = "$_r2" ]; then ok "v4 AGH_PRIV 未被 GET 改动（重采样一致）"
    else bad "v4 AGH_PRIV 被 GET 重建（$(echo "$_b1" | cut -c1-8) → $(echo "$_a1" | cut -c1-8)）"; fi
fi
[ "$_b6" = "$_a6" ] && ok "v6 AGH_PRIV 未被 GET 改动" || bad "v6 AGH_PRIV 被 GET 重建"

info "4. 隐私规则覆盖（按当前开关）"
_rs=$(iptables -w 2 -S AGH_PRIV 2>/dev/null)
for p in 5353 3478 161; do
    echo "$_rs" | grep -q -- "$p" && ok "规则含 $p" || bad "规则缺 $p"
done
echo "$_rs" | grep -q -- "-p 41" && ok "规则含 6to4 承载（-p 41）" || bad "规则缺 -p 41"
iptables -S OUTPUT 2>/dev/null | grep -c -- "-j AGH_PRIV" | grep -qx 1 && ok "OUTPUT 只有一处 AGH_PRIV 跳转" || bad "OUTPUT 跳转数异常"
iptables -S 2>/dev/null | grep -q "^-N AGH_PRIV_N" && bad "残留暂存链 AGH_PRIV_N" || ok "无残留暂存链"

info "5. 脚本列表 / 应用列表内容形态"
_sz=$(wc -c < /data/local/tmp/_chk_scripts 2>/dev/null | tr -d ' ')
[ "${_sz:-0}" -gt 40 ] && ok "scripts 响应 ${_sz}B" || bad "scripts 响应过小"
grep -q '"scripts"' /data/local/tmp/_chk_scripts 2>/dev/null && ok "scripts 含 scripts 数组" || bad "scripts 缺 scripts 数组"
grep -q '"apps"' /data/local/tmp/_chk_apps 2>/dev/null && ok "apps 含 apps 数组" || bad "apps 缺 apps 数组"

info "6. 证书"
grep -q '"https"' /data/local/tmp/_chk_certs 2>/dev/null && grep -q '"mitm"' /data/local/tmp/_chk_certs 2>/dev/null \
    && ok "certs 含 https/mitm 两张 CA" || bad "certs 缺 CA 条目"
_r=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/certs?download=mitm" 2>/dev/null)
[ "$_r" = "200" ] && ok "certs?download=mitm 可下载" || bad "mitm CA 下载失败（$_r）"

info "7. 源码/页面一致性"
_w=/data/adb/agh/scripts/webui
[ -f "$_w/privacy.html" ] && grep -q 'localStorage' "$_w/privacy.html" && ok "privacy.html 为新版（含本地缓存）" || bad "privacy.html 仍是旧版"
[ "$(md5sum "$_w/cgi-bin/privacy" 2>/dev/null | cut -d' ' -f1)" = "$(md5sum /data/adb/modules/AdGuardHome/scripts/webui/cgi-bin/privacy 2>/dev/null | cut -d' ' -f1)" ] \
    && ok "两处 privacy CGI 一致" || bad "两处 privacy CGI 版本不一致"

printf '\n结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
