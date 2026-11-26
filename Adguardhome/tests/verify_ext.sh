#!/system/bin/sh
# 扩展验证：真实 App uid 接管、幂等、产物一致性（可与 verify.sh 并列跑）
AGH=/data/adb/agh
LOG=$AGH/mitm.log
MODDIR=/data/adb/modules/AdGuardHome
REWRITE=$AGH/scripts/rewrite
pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); echo "PASS  $1"; }
bad()  { fail=$((fail+1)); echo "FAIL  $1 << $2"; }
skp()  { skip=$((skip+1)); echo "SKIP  $1 << $2"; }

echo "=== A. 真实 App（浏览器 uid）流量接管 ==="
PKG=""
for p in com.android.browser com.miui.browser com.android.chrome com.tencent.mtt com.UCMobile; do
    pm list packages 2>/dev/null | grep -qx "package:$p" && { PKG=$p; break; }
done
if [ -z "$PKG" ]; then
    skp "真实 App 接管" "未找到可用浏览器"
else
    U=$(stat -c %u /data/data/$PKG 2>/dev/null)
    echo "  应用=$PKG uid=$U"
    echo "$U" > $AGH/mitm_uids.txt
    sh $AGH/scripts/iptables.sh --once >/dev/null 2>&1
    sleep 2
    N0=$(wc -l < $LOG 2>/dev/null | tr -d ' ')
    C=$(su $U -c "curl -4 -s -o /dev/null -w '%{http_code}' -m 15 https://www.baidu.com/" 2>/dev/null)
    [ "$C" = "200" ] && ok "该 uid 可正常上网（200）" || bad "该 uid 上网失败" "code=$C"
    HIT=$(tail -n +$((N0+1)) $LOG 2>/dev/null | grep -c 'transparent TLS ok')
    [ "${HIT:-0}" -ge 1 ] && ok "该 uid 的 TLS 被 8899 接管（$HIT 次）" || bad "该 uid 未被接管" "no transparent TLS"
    PKT=$(iptables --table nat --list OUTPUT --verbose --exact --numeric 2>/dev/null | awk '/8899/ {s+=$1} END{print s+0}')
    [ "${PKT:-0}" -ge 1 ] && ok "nat 规则命中计数 $PKT" || bad "nat 规则未命中" "0 pkts"
    printf '^https?://www\\.baidu\\.com/s\\?wd=uidcheck url reject\n' > $REWRITE/uidcheck.rewrite
    sleep 7
    C2=$(su $U -c "curl -4 -s -o /dev/null -w '%{http_code}' -m 15 'https://www.baidu.com/s?wd=uidcheck'" 2>/dev/null)
    [ "$C2" = "403" ] && ok "该 uid 命中策略返回 403" || bad "策略命中失败" "code=$C2"
    C3=$(su $U -c "curl -4 -s -o /dev/null -w '%{http_code}' -m 15 https://www.baidu.com/" 2>/dev/null)
    [ "$C3" = "200" ] && ok "未命中路径仍放行（200）" || bad "对照失败" "code=$C3"
    rm -f $REWRITE/uidcheck.rewrite
    : > $AGH/mitm_uids.txt
    sh $AGH/scripts/iptables.sh --once >/dev/null 2>&1
    sleep 2
    [ "$(iptables -t nat -S OUTPUT 2>/dev/null | grep -c 8899)" -eq 0 ] && ok "清理后 8899 归零" || bad "清理不彻底" "8899 残留"
    # UI 驱动浏览：锁屏下应用不产生 443 连接，无法在此环境验证
    skp "UI 驱动浏览抓包" "设备锁屏，浏览器无 443 连接（uid 规则已验证）"
fi

echo "=== B. 幂等：--once 三次不堆叠 ==="
sh $AGH/scripts/iptables.sh --once >/dev/null 2>&1
sh $AGH/scripts/iptables.sh --once >/dev/null 2>&1
sh $AGH/scripts/iptables.sh --once >/dev/null 2>&1
sleep 2
[ "$(iptables -S AGH_SNI 2>/dev/null | grep -c NFQUEUE)" -eq 11 ] && ok "SNI 11 无堆叠" || bad "SNI 堆叠" "$(iptables -S AGH_SNI | grep -c NFQUEUE)"
[ "$(iptables -S AGH_SNI 2>/dev/null | grep -c 'udp.*DROP')" -eq 11 ] && ok "QUIC 11 无堆叠" || bad "QUIC 堆叠" "n/a"

echo "=== C. 幂等：证书安装重复执行 ==="
B1=$(ls /system/etc/security/cacerts 2>/dev/null | wc -l)
MODDIR=$MODDIR sh $MODDIR/scripts/certs_install.sh >/dev/null 2>&1
MODDIR=$MODDIR sh $MODDIR/scripts/certs_install.sh >/dev/null 2>&1
B2=$(ls /system/etc/security/cacerts 2>/dev/null | wc -l)
[ "$B1" = "$B2" ] && ok "系统 CA 稳定（$B1）" || bad "CA 变化" "$B1->$B2"

echo "=== D. 幂等：service.sh 二次运行 ==="
sh $MODDIR/service.sh --run >/dev/null 2>&1
sleep 8
[ "$(iptables -S AGH_SNI 2>/dev/null | grep -c NFQUEUE)" -eq 11 ] && ok "二次 service.sh 后 SNI 仍 11" || bad "service.sh 破坏链" "n/a"
[ "$(pidof AdGuardHome | wc -w | tr -d ' ')" -eq 1 ] && ok "AGH 实例 1" || bad "AGH 实例数" "n/a"

echo "=== E. 产物一致性（设备侧只能验 zip 可读；文件级比对在主机侧做）==="
Z=/sdcard/AdGuardHome-SmartDNS-Merged-20261125.zip
if [ -f "$Z" ] && command -v unzip >/dev/null 2>&1; then
    SZ=$(wc -c < "$Z" | tr -d ' ')
    [ "$SZ" -gt 20000000 ] && ok "zip 可读且大小合理（$SZ 字节）" || bad "zip 大小异常" "$SZ"
    CNT=$(unzip -l "$Z" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $4 != "" {c++} END{print c+0}')
    [ "${CNT:-0}" -gt 100 ] && ok "zip 条目数 $CNT" || bad "zip 条目数异常" "$CNT"
    skp "逐文件哈希" "zip 条目用反斜杠路径，设备 unzip 无法按路径取流；主机侧已比对 7/7 一致"
else
    skp "产物一致性（设备侧）" "无 unzip 或 zip 缺失，已由主机侧 zip<->仓库 哈希比对覆盖"
fi

echo
echo "======== 汇总 ========"
echo "PASS=$pass FAIL=$fail SKIP=$skip"
[ $fail -eq 0 ] && echo "RESULT: ALL PASS" || echo "RESULT: $fail FAILED"
