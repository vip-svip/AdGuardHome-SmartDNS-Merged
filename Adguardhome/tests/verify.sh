#!/system/bin/sh
# 模块自检：逐条验证此前交付的能力，输出 PASS/FAIL/SKIP
# 用法：sh /data/adb/agh/tests/verify.sh
MODDIR=/data/adb/modules/AdGuardHome
AGH_DIR=/data/adb/agh
REWRITE=$AGH_DIR/scripts/rewrite
OUT=$MODDIR/rules/脚本拦截.txt
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1  << $2"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP  $1  << $2"; }
eq() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1" "want=[$3] got=[$2]"; }
ge() { [ "${2:-0}" -ge "$3" ] 2>/dev/null && ok "$1 ($2>=$3)" || bad "$1" "want>=$3 got=[$2]"; }
cnt() { echo "$1" | wc -w | tr -d ' '; }

echo "=== T1 关键文件 ==="
for f in bin/AdGuardHome bin/aghmitm bin/dnsenc certs/https-ca.crt certs/https-ca.key \
         certs/mitm-ca.crt certs/mitm-ca.key certs/meta.txt \
         scripts/iptables.sh scripts/certs_install.sh service.sh customize.sh \
         scripts/webui/cgi-bin/privacy scripts/webui/cgi-bin/certs \
         scripts/webui/cgi-bin/scripts scripts/webui/cgi-bin/mitm; do
    [ -f "$MODDIR/$f" ] && ok "存在 $f" || bad "缺失 $f" "not found"
done

echo "=== T2 进程单实例 ==="
eq "AdGuardHome 实例数" "$(cnt "$(pidof AdGuardHome)")" "1"
eq "aghmitm 实例数" "$(cnt "$(pidof aghmitm)")" "1"
# 一次性取 ps，避免逐条扫 /proc（设备上数千进程，逐条 tr 会拖到十几分钟）
PSOUT=$(ps -A -o PID,PPID,ARGS 2>/dev/null)
d=$(printf '%s\n' "$PSOUT" | awk '
    /scripts\/iptables\.sh/ && !/--once/ && !/--v6selftest/ && !/awk/ { n++; pid[n]=$1; pp[n]=$2 }
    END { for (i=1;i<=n;i++) { c=0; for (j=1;j<=n;j++) if (pp[i]==pid[j]) c=1; if (!c) k++ } print k+0 }')
eq "iptables.sh 守护实例" "$d" "1"
m=0
# 只数「根实例」：排除某个 ModuleMOD 进程的子壳（脚本内部 $(...) 会 fork 出同名子进程）
PSOUT=$(ps -A -o PID,PPID,ARGS 2>/dev/null)
m=$(printf '%s\n' "$PSOUT" | awk '/ModuleMOD\.sh/ { n++; pid[n]=$1; pp[n]=$2 } END { for (i=1;i<=n;i++) { c=0; for (j=1;j<=n;j++) if (pp[i]==pid[j]) c=1; if (!c) k++ } print k+0 }')
eq "ModuleMOD 实例" "$m" "1"

echo "=== T3 面板与页面 ==="
eq "面板 40251" "$(curl -s -o /dev/null -w '%{http_code}' -m 6 http://127.0.0.1:40251/)" "302"
CK=/data/local/tmp/_vck.$$
curl -s -c $CK -H "Content-Type: application/json" -d '{"name":"root","password":"root"}' http://127.0.0.1:40251/control/login -o /dev/null
BN=$(curl -s -b $CK http://127.0.0.1:40251/ | grep -oE 'main\.[a-z0-9]+\.js' | head -1)
B=$(curl -s -b $CK "http://127.0.0.1:40251/$BN")
for kw in 高级设置 隐私 证书 脚本; do
    ge "bundle 含「$kw」" "$(echo "$B" | grep -c "$kw")" 1
done
eq "bundle 不含「应用分流」(应为 0)" "$(echo "$B" | grep -c 应用分流)" "0"
rm -f $CK

echo "=== T4 规则集计数 ==="
curl -s -u root:root http://127.0.0.1:40251/control/filtering/status > /data/local/tmp/_vfs.json
getn() {
    tr ',' '\n' < /data/local/tmp/_vfs.json | tr -d '" ' \
      | awk -F: -v n="$1" '$1=="name"&&$2==n{f=1;next} f&&$1=="rules_count"{print $2;exit}'
}
eq "色情网站"       "$(getn 色情网站)" "162"
eq "应用隐私"       "$(getn 应用隐私)" "175"
eq "运营商追踪"     "$(getn 运营商追踪)" "108"
eq "反诈上报"       "$(getn 反诈上报)" "60"
eq "基站WiFi隐私"   "$(getn 基站WiFi隐私)" "35"
eq "腾讯广告"       "$(getn 腾讯广告)" "22"
eq "脚本拦截已注册" "$(grep -c '脚本拦截' /data/local/tmp/_vfs.json)" "1"
rm -f /data/local/tmp/_vfs.json

echo "=== T5 系统信任库 ==="
CAC=/system/etc/security/cacerts
ge "系统 CA 总数" "$(ls $CAC 2>/dev/null | wc -l)" 125
[ -f "$CAC/2c637461.0" ] && ok "HTTPS CA 已进系统库" || bad "HTTPS CA 未进系统库" missing
[ -f "$CAC/e2b6a4fd.0" ] && ok "MITM CA 已进系统库" || bad "MITM CA 未进系统库" missing
mount 2>/dev/null | grep -q " $CAC " && ok "cacerts 挂载为 tmpfs" || skip "cacerts 非 tmpfs" overlay

echo "=== T6 SNI / QUIC 链 ==="
eq "SNI NFQUEUE 条数" "$(iptables -S AGH_SNI 2>/dev/null | grep -c NFQUEUE)" "11"
eq "QUIC UDP DROP 条数" "$(iptables -S AGH_SNI 2>/dev/null | grep -c 'udp.*DROP')" "11"
PORTS=$(iptables -S AGH_SNI 2>/dev/null | grep NFQUEUE | grep -oE 'dport [0-9]+' | grep -oE '[0-9]+' | sort -n | tr '\n' ',')
EXP=$(echo "80 443 8443 2053 2054 2083 2087 2089 2091 2096 2480" | tr ' ' '\n' | sort -n | tr '\n' ',')
eq "SNI 端口集合" "$PORTS" "$EXP"

echo "=== T7 各格式域名抽取 ==="
mkdir -p "$REWRITE"
rm -f "$REWRITE"/v_* "$REWRITE/uidtest.rewrite" "$REWRITE/dbg.rewrite" 2>/dev/null
printf '^https?://v-rewrite.test/x url reject\n' > "$REWRITE/v_rewrite.rewrite"
printf '[Rule]\nDOMAIN-SUFFIX,v-plugin.test,REJECT\n' > "$REWRITE/v_plugin.plugin"
printf '[rewrite_local]\n^https?://v-qx.test/a url reject\nhostname = %%APPEND%% v-qx2.test, v-qx3.test\n' > "$REWRITE/v_qx.conf"
printf '[Rule]\nDOMAIN-SUFFIX,v-surge.test,REJECT-TINYGIF\n' > "$REWRITE/v_surge.sgmodule"
printf 'rules:\n  - DOMAIN-SUFFIX,v-clash.test,REJECT\n' > "$REWRITE/v_clash.yaml"
printf '{"route":{"rules":[{"action":"reject","domain_suffix":["v-sb.test"]}]}}\n' > "$REWRITE/v_sb.json"
printf '0.0.0.0 v-hosts.test\n' > "$REWRITE/v_hosts.list"
printf 'address=/v-dnsmasq.test/0.0.0.0\n' > "$REWRITE/v_dnsmasq.list"
printf '||v-agh.test^\n' > "$REWRITE/v_agh.txt"
sleep 1
curl -s -m 25 "http://127.0.0.1:6081/cgi-bin/scripts?apply=1" >/dev/null 2>&1
LIST=$(tr -d '|^' < "$OUT" 2>/dev/null)
for d in v-rewrite v-plugin v-qx v-qx2 v-qx3 v-surge v-clash v-sb v-hosts v-dnsmasq v-agh; do
    echo "$LIST" | grep -q "^$d\.test$" && ok "抽取 $d.test" || bad "抽取 $d.test" missing
done
rm -f "$REWRITE"/v_* 2>/dev/null
curl -s -m 25 "http://127.0.0.1:6081/cgi-bin/scripts?apply=1" >/dev/null 2>&1
eq "清理夹具后无测试域名（内置脚本可保留）" "$(grep -cE "\|\|(v-|t-)" "$OUT" 2>/dev/null)" "0"

echo "=== T8 MITM：reject / 302 / body 改写 / 透明 ==="
M=http://127.0.0.1:8899
TMPWWW=/data/local/tmp/_vwww
mkdir -p $TMPWWW
printf 'hello world' > $TMPWWW/index.html
pkill -f "httpd.*8088" 2>/dev/null; sleep 1
setsid busybox httpd -p 127.0.0.1:8088 -h $TMPWWW </dev/null >/dev/null 2>&1 &
HPID=$!
sleep 3
BASE=$(curl -s -m 5 http://127.0.0.1:8088/index.html 2>/dev/null)
eq "httpd 基线" "$BASE" "hello world"
printf '^https?://example\\.com/vb url reject\n^https?://example\\.com/v302 url 302 https://www.baidu.com/\n^http://127\\.0\\.0\\.1:8088/ url-body-replace hello HELLO\n' > "$REWRITE/v_mitm.rewrite"
sleep 7
eq "reject -> 403" "$(curl -sk -x $M -o /dev/null -w '%{http_code}' -m 12 https://example.com/vb)" "403"
eq "302 -> 302" "$(curl -sk -x $M -o /dev/null -w '%{http_code}' -m 12 https://example.com/v302)" "302"
eq "302 Location" "$(curl -sk -x $M -o /dev/null -w '%{redirect_url}' -m 12 https://example.com/v302)" "https://www.baidu.com/"
eq "body 改写" "$(i=0; B=; while [ $i -lt 3 ]; do B=$(curl -sk -x $M -m 10 http://127.0.0.1:8088/ 2>/dev/null | head -c 20); [ "$B" = "HELLO world" ] && break; i=$((i+1)); sleep 3; done; echo "$B")" "HELLO world"
eq "透明模式 reject -> 403" "$(curl -sk --connect-to example.com:443:127.0.0.1:8899 -o /dev/null -w '%{http_code}' -m 12 https://example.com/vb)" "403"
eq "非命中直接转发 -> 200" "$(curl -sk -x $M -o /dev/null -w '%{http_code}' -m 15 https://www.baidu.com/)" "200"
pkill -f "httpd.*8088" 2>/dev/null; kill $HPID 2>/dev/null
rm -rf $TMPWWW

echo "=== T9 JS 脚本 ==="
cat > "$REWRITE/v_ok.js" <<'EOS'
// @match ^https?://example\.com/vjs
$done({ status: 403, body: 'js-blocked' });
EOS
cat > "$REWRITE/v_syntax.js" <<'EOS'
// @match ^https?://example\.com/vsyntax
this is not javascript ===
EOS
LOOPJS="v_loop_$$.js"
cat > "$REWRITE/$LOOPJS" <<'EOS'
// @match ^https?://example\.com/vloop
while (true) {}
EOS
sleep 7
eq "JS 短路 403" "$(curl -sk -x $M -o /dev/null -w '%{http_code}' -m 12 https://example.com/vjs)" "403"
eq "JS 响应体长度" "$(curl -sk -x $M -m 12 https://example.com/vjs 2>/dev/null | wc -c | tr -d ' ')" "10"
T0=$(date +%s)
curl -sk -x $M -o /dev/null -m 12 https://example.com/vloop 2>/dev/null
DT=$(( $(date +%s) - T0 ))
[ "$DT" -le 5 ] && ok "JS 死循环被硬超时中断 (${DT}s)" || bad "JS 死循环未被中断" "cost=${DT}s"
ge "语法错误脚本不影响服务（日志记录）" "$(grep -c 'js .*error' $AGH_DIR/mitm.log)" 1
eq "aghmitm 仍存活" "$(cnt "$(pidof aghmitm)")" "1"
rm -f "$REWRITE"/v_*.js "$REWRITE/v_loop_"*.js "$REWRITE/v_mitm.rewrite"

echo "=== T10 uid 透明分流生命周期 ==="
: > $AGH_DIR/mitm_uids.txt; sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1; sleep 2
eq "空名单规则数" "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" "0"
echo 10253 > $AGH_DIR/mitm_uids.txt; sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1; sleep 2
eq "加 uid 后规则数" "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" "1"
: > $AGH_DIR/mitm_uids.txt; sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1; sleep 2
eq "清空后规则数" "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" "0"

echo "=== T11 自愈与韧性 ==="
OLD=$(pidof AdGuardHome)
[ -n "$OLD" ] && kill -9 $OLD 2>/dev/null
sleep 14
NEW=$(pidof AdGuardHome)
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && ok "AGH 被杀后守护拉起 ($OLD->$NEW)" || bad "AGH 未被拉起" "old=$OLD new=$NEW"
eq "重启后 SNI 链完好" "$(iptables -S AGH_SNI 2>/dev/null | grep -c NFQUEUE)" "11"
eq "重启后面板" "$(curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:40251/)" "302"

echo "=== T12 各 CGI 功能面 ==="
eq "privacy CGI" "$(curl -s -m 8 http://127.0.0.1:6081/cgi-bin/privacy | grep -c '"applied"')" "1"
eq "certs CGI installed 数" "$(curl -s -m 8 http://127.0.0.1:6081/cgi-bin/certs | grep -o '"installed":[0-9]' | grep -c '"installed":1')" "2"
eq "certs 下载 PEM" "$(curl -s -m 8 'http://127.0.0.1:6081/cgi-bin/certs?download=mitm' | head -1)" "-----BEGIN CERTIFICATE-----"
eq "mitm CGI running" "$(curl -s -m 8 http://127.0.0.1:6081/cgi-bin/mitm | grep -o '"running":[0-9]')" '"running":1'
eq "apps CGI 已删除" "$(curl -s -o /dev/null -w '%{http_code}' -m 6 http://127.0.0.1:6081/cgi-bin/apps)" "404"

echo
echo "=== T13 SNI 层真实拦截（双路径：MITM 接管 502 / SNI RST exit35）==="
if su 10253 -c "id -u" >/dev/null 2>&1; then
    echo 10253 > $AGH_DIR/mitm_uids.txt
    sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1
    sleep 2
    CB=$(su 10253 -c "curl -s -o /dev/null -w '%{http_code}' -m 10 --resolve umeng.com:443:223.5.5.5 https://umeng.com/" 2>/dev/null)
    eq "被拦域（经 MITM）-> 502" "$CB" "502"
    CO=$(su 10253 -c "curl -s -o /dev/null -w '%{http_code}' -m 12 --resolve www.baidu.com:443:223.5.5.5 https://www.baidu.com/" 2>/dev/null)
    eq "正常域（经 MITM）-> 200" "$CO" "200"
    : > $AGH_DIR/mitm_uids.txt
    sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1
    sleep 2
    RB=$(timeout 10 su 10253 -c "curl -s -o /dev/null --resolve umeng.com:443:223.5.5.5 https://umeng.com/" 2>/dev/null; echo $?)
    case "$RB" in 35|56) ok "被拦域（SNI RST）exit=$RB" ;; *) bad "被拦域 SNI RST" "exit=$RB 期望 35/56" ;; esac
    RO=$(timeout 10 su 10253 -c "curl -s -o /dev/null --resolve www.baidu.com:443:223.5.5.5 https://www.baidu.com/" 2>/dev/null; echo $?)
    case "$RO" in 60|0) ok "正常域对照 exit=$RO" ;; *) bad "正常域对照" "exit=$RO 期望 60/0" ;; esac
else
    skp "SNI 层真实拦截" "无 su 切 uid 能力"
fi
echo "=== T14 按 uid 透明接管（IPv4）==="
echo 10253 > $AGH_DIR/mitm_uids.txt
sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1
sleep 2
eq "清单写入后 8899 规则" "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" "1"
N0=$(wc -l < $AGH_DIR/mitm.log 2>/dev/null | tr -d ' ')
C4=$(su 10253 -c "curl -4 -s -o /dev/null -w '%{http_code}' -m 12 https://www.baidu.com/" 2>/dev/null)
eq "该 uid 走 IPv4 仍可上网" "$C4" "200"
HIT=$(tail -n +$((N0+1)) $AGH_DIR/mitm.log 2>/dev/null | grep -c 'transparent TLS ok')
ge "流量确实进了 8899（日志命中）" "$HIT" 1
PKT=$(iptables -t nat -L OUTPUT -v -n 2>/dev/null | awk '$0 ~ /8899/ {print $1}' | head -1)
ge "nat 规则命中计数" "$PKT" 1
C6=$(su 10253 -c "curl -6 -s -o /dev/null -w '%{http_code}' -m 8 https://www.baidu.com/" 2>/dev/null; echo "|$?")
eq "IPv6 被回落（无 nat 表时 REJECT 逼回 v4）" "$(echo "$C6" | grep -c '^000')" "1"
: > $AGH_DIR/mitm_uids.txt
sh $AGH_DIR/scripts/iptables.sh --once >/dev/null 2>&1
sleep 2
eq "清空名单后 8899 规则" "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" "0"
eq "清空名单后 v6 REJECT" "$(ip6tables -S OUTPUT 2>/dev/null | grep -c 'reject-with tcp-reset')" "0"

echo "=== T15 IPv6 能力探测（记录内核限制）==="
if ip6tables -t nat -L OUTPUT >/dev/null 2>&1; then
    ok "内核支持 ip6tables nat"
else
    skip "内核无 ip6tables nat" "v6 只能靠 filter 层 REJECT 回落"
fi
echo "=== T16 开机路径确定性重建（本次开机是否由 service.sh 强制建成链）==="
BOOT_LINE=$(grep -c 'SNI/QUIC 链已确定性重建完成' "$AGH_DIR"/*.log 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
if [ "$BOOT_LINE" -ge 1 ]; then
    ok "开机确定性重建已执行（日志命中 $BOOT_LINE 次）"
else
    ge "SNI 链在本次会话已建成" "$(iptables -S AGH_SNI 2>/dev/null | grep -c NFQUEUE)" 11
fi

echo "=== T17 套件自清理（不残留测试脚本）==="
eq "脚本目录残留数（允许内置 default.rewrite）" "$(ls "$REWRITE" 2>/dev/null | grep -v "^default\.rewrite$" | grep -c .)" "0"
eq "名单文件残留行数" "$(wc -l < $AGH_DIR/mitm_uids.txt 2>/dev/null | tr -d ' ')" "0"
eq "8899 分流规则残留" "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" "0"
eq "v6 REJECT 残留" "$(ip6tables -S OUTPUT 2>/dev/null | grep -c 'reject-with tcp-reset')" "0"
eq "汇总文件无测试残留域名" "$(grep -cE "\|\|(v-|t-)" "$OUT" 2>/dev/null)" "0"
echo "======== 汇总 ========"
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && echo "RESULT: ALL PASS" || echo "RESULT: $FAIL FAILED"
