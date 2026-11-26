#!/system/bin/sh
# 主机侧自检：用 busybox sh 跑真实 CGI 脚本（不依赖手机）
# 用法（Windows）：busybox sh tests/host_selftest.sh
#      （设备）  ：sh /data/adb/agh/tests/host_selftest.sh
#
# 断言对象是仓库里的真实脚本，路径镜像成 /data/adb/... 后执行。
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1  << $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1" "want=[$3] got=[$2]"; }

AGH=/data/adb/agh
MOD=/data/adb/modules/AdGuardHome
CGI=$AGH/scripts/webui/cgi-bin
RW=$AGH/scripts/rewrite
OUT=$MOD/rules/脚本拦截.txt

echo "=== 环境 ==="
[ -d "$CGI" ] && ok "CGI 目录存在" || { bad "CGI 目录缺失" "$CGI"; exit 1; }
for f in scripts certs mitm; do
    [ -f "$CGI/$f" ] && ok "存在 CGI $f" || bad "缺失 CGI $f" "$CGI/$f"
done

echo "=== 语法检查（真实脚本，逐文件）==="
for f in "$CGI"/*; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then ok "语法 $(basename "$f")"; else bad "语法 $(basename "$f")" "sh -n failed"; fi
done

echo "=== T1 各格式域名抽取（scripts CGI ?apply=1）==="
mkdir -p "$RW" "$MOD/rules" 2>/dev/null
rm -f "$RW"/* 2>/dev/null
cat > "$RW/f1.rewrite" <<'EOS'
^https?://t-rewrite.test/x url reject
^https?://t-rewrite2.test/y url reject-200
EOS
cat > "$RW/f2.plugin" <<'EOS'
[Rule]
DOMAIN-SUFFIX,t-plugin.test,REJECT
DOMAIN-SUFFIX,t-plugin2.test,REJECT-TINYGIF
[URL Rewrite]
^https?://t-plugin3.test/z url reject
EOS
cat > "$RW/f3.conf" <<'EOS'
[rewrite_local]
^https?://t-qx.test/a url reject
hostname = %APPEND% t-qx2.test, t-qx3.test
[mitm]
hostname = t-qx4.test
EOS
cat > "$RW/f4.sgmodule" <<'EOS'
[Rule]
DOMAIN-SUFFIX,t-surge.test,REJECT
[URL Rewrite]
^https?://t-surge2.test/b url reject
EOS
cat > "$RW/f5.yaml" <<'EOS'
rules:
  - DOMAIN-SUFFIX,t-clash.test,REJECT
  - DOMAIN,t-clash2.test,REJECT
EOS
cat > "$RW/f6.json" <<'EOS'
{"route":{"rules":[{"action":"reject","domain_suffix":["t-sb.test","t-sb2.test"]}]}}
EOS
cat > "$RW/f7.list" <<'EOS'
0.0.0.0 t-hosts.test
127.0.0.1 t-hosts2.test
EOS
cat > "$RW/f8.list2" <<'EOS'
address=/t-dnsmasq.test/0.0.0.0
EOS
cat > "$RW/f9.txt" <<'EOS'
||t-agh.test^
t-agh2.test
EOS
mv "$RW/f8.list2" "$RW/f8.dnsmasq.list" 2>/dev/null

REQUEST_METHOD=GET QUERY_STRING="apply=1" sh "$CGI/scripts" > /tmp/_apply.json 2>/tmp/_apply.err
echo "  CGI 输出: $(head -c 120 /tmp/_apply.json)"
[ -f "$OUT" ] && ok "输出文件已生成" || bad "输出文件未生成" "$OUT"

LIST=$(tr -d '|^' < "$OUT" 2>/dev/null | grep -E '^[a-z0-9]' | sort)
for d in t-rewrite.test t-rewrite2.test t-plugin.test t-plugin2.test t-plugin3.test \
         t-qx.test t-qx2.test t-qx3.test t-qx4.test t-surge.test t-surge2.test \
         t-clash.test t-clash2.test t-sb.test t-sb2.test t-hosts.test t-hosts2.test \
         t-dnsmasq.test t-agh.test t-agh2.test; do
    echo "$LIST" | grep -qx "$d" && ok "抽取 $d" || bad "抽取 $d" missing
done
eq "域名总条数" "$(echo "$LIST" | grep -c .)" "20"

echo "=== T2 头部格式（AGH 过滤语法）==="
eq "首行注释" "$(head -1 "$OUT")" "! 由脚本页汇总：小火箭/Loon/Surge/QX/Clash/sing-box/V2Ray/hosts/dnsmasq"
eq "首条规则前缀" "$(sed -n '2p' "$OUT" | cut -c1-2)" "||"
eq "规则以 ^ 结尾" "$(sed -n '2p' "$OUT" | rev | cut -c1)" "^"

echo "=== T3 停用后不参与汇总（scripts CGI ?toggle=）==="
: > /tmp/_t.json
REQUEST_METHOD=GET QUERY_STRING="toggle=f5.yaml" sh "$CGI/scripts" > /tmp/_t.json 2>/dev/null
eq "toggle 返回 enabled=0" "$(grep -o '"enabled":0' /tmp/_t.json | head -1)" '"enabled":0'
REQUEST_METHOD=GET QUERY_STRING="apply=1" sh "$CGI/scripts" >/dev/null 2>&1
eq "停用后域名数" "$(grep -c '^||' "$OUT" 2>/dev/null)" "18"
eq "停用项已排除" "$(grep -c 't-clash' "$OUT" 2>/dev/null)" "0"
REQUEST_METHOD=GET QUERY_STRING="toggle=f5.yaml" sh "$CGI/scripts" >/dev/null 2>&1
REQUEST_METHOD=GET QUERY_STRING="apply=1" sh "$CGI/scripts" >/dev/null 2>&1
eq "恢复后域名数" "$(grep -c '^||' "$OUT" 2>/dev/null)" "20"

echo "=== T4 列表 JSON（scripts CGI GET）==="
REQUEST_METHOD=GET QUERY_STRING="" sh "$CGI/scripts" > /tmp/_list.json 2>/dev/null
eq "JSON 有 dir 字段" "$(grep -c '"dir"' /tmp/_list.json)" "1"
eq "JSON 有 out 字段" "$(grep -c '"out"' /tmp/_list.json)" "1"
eq "脚本条目数" "$(grep -o '"name":"' /tmp/_list.json | grep -c .)" "9"
eq "含 enabled 标记" "$(grep -o '"enabled":1' /tmp/_list.json | grep -c .)" "9"

echo "=== T5 证书 CGI（状态 + 下载）==="
for f in https-ca.crt https-ca.key mitm-ca.crt mitm-ca.key meta.txt; do
    [ -f "$MOD/certs/$f" ] && ok "证书文件 $f" || bad "证书文件缺失 $f" "$MOD/certs/$f"
done
REQUEST_METHOD=GET QUERY_STRING="" sh "$CGI/certs" > /tmp/_certs.json 2>/dev/null
eq "https 段存在" "$(grep -c '"https"' /tmp/_certs.json)" "1"
eq "mitm 段存在" "$(grep -c '"mitm"' /tmp/_certs.json)" "1"
eq "meta 主题非空" "$(grep -o '"subject":"CN=AGH Local HTTPS CA[^"]*"' /tmp/_certs.json | grep -c 'CN=AGH')" "1"
eq "到期日（两证书各一处）" "$(grep -o '"expires":"2036-11-25"' /tmp/_certs.json | grep -c .)" "2"
eq "SHA256 冒号个数" "$(grep -o '"sha256":"[^"]*"' /tmp/_certs.json | head -1 | tr -cd ':' | wc -c | tr -d ' ')" "32"
REQUEST_METHOD=GET QUERY_STRING="download=mitm" sh "$CGI/certs" > /tmp/_dl.txt 2>/dev/null
eq "下载首行 PEM" "$(grep -m1 'BEGIN CERTIFICATE' /tmp/_dl.txt | tr -d '\r')" "-----BEGIN CERTIFICATE-----"
eq "下载含附名" "$(grep -c 'filename="mitm-ca.crt"' /tmp/_dl.txt)" "1"

echo "=== T6 mitm CGI 状态字段 ==="
REQUEST_METHOD=GET QUERY_STRING="" sh "$CGI/mitm" > /tmp/_mitm.json 2>/dev/null
for k in '"running"' '"pid"' '"port":8899' '"uids"' '"rules"'; do
    eq "含 $k" "$(grep -c "$k" /tmp/_mitm.json)" "1"
done

echo "=== T7 证书链校验（Go 侧，若可用）==="
if command -v go >/dev/null 2>&1; then ok "go 可用（链校验由 go test 覆盖）"; else echo "SKIP  证书链校验：主机无 go"; fi

echo
echo "======== 汇总 ========"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "RESULT: ALL PASS" || echo "RESULT: $FAIL FAILED"