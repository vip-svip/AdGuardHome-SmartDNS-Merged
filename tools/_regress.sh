#!/system/bin/sh
# 多设备通用回归：自动识别活动链（ADGUARD / ADGUARDB 轮换）、自动发现 busybox。
A=/data/adb/agh
M=/data/adb/modules/AdGuardHome
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
  [ -x "$b" ] && { BB=$b; break; }
done
IPW="-w 2"
iptables $IPW -t nat -S OUTPUT >/dev/null 2>&1 || IPW=""
echo "== version =="
$A/bin/AdGuardHome --version 2>&1 | head -2
grep -E '^(version|versionCode)=' $M/module.prop
echo "== procs =="
for p in bin/AdGuardHome bin/dnsenc /usr/local/lib/smartdns/smartdns scripts/iptables.sh httpd; do
  n=0
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
    case "$c" in *"$p"*) n=$((n+1)) ;; esac
  done
  echo "  $p x$n"
done
echo "== chains (active=$([ -n "$(iptables $IPW -t nat -C OUTPUT -j ADGUARDB 2>/dev/null && echo B)" ] && echo ADGUARDB || echo ADGUARD)) =="
ACT=""
for ch in ADGUARD ADGUARDB; do
  if iptables $IPW -t nat -C OUTPUT -j $ch 2>/dev/null; then ACT=$ch; fi
done
[ -n "$ACT" ] || ACT=ADGUARD
echo "  ACTIVE=$ACT rules=$(iptables $IPW -t nat -S $ACT 2>/dev/null | tail -n +2 | wc -l)"
echo "  redir=$(grep -m1 '^redir_port=' $A/scripts/config.prop)"
echo "  yamlport=$(awk '/^dns:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$2);print $2;exit}' $A/bin/AdGuardHome.yaml)"
echo "  REDIRECT: $(iptables $IPW -t nat -S $ACT 2>/dev/null | grep -o 'to-ports [0-9]*' | head -1)"
echo "  uid0full=$(iptables $IPW -t nat -S $ACT 2>/dev/null | grep -c 'uid-owner 0 -j RETURN')"
echo "  bootstrap=$(iptables $IPW -t nat -S $ACT 2>/dev/null | grep -c '180.184.1.1')"
echo "  tunn=$(iptables $IPW -t nat -S $ACT 2>/dev/null | grep -cE '\-o (tun|tap|ppp|utun|wg|ipsec)\+')"
echo "  v6mode=$(grep -m1 '^v6_dns=' $A/scripts/config.prop) v6nat=$(ip6tables -t nat -S OUTPUT >/dev/null 2>&1 && echo yes || echo no) v6jump=$(ip6tables -t mangle -S OUTPUT 2>/dev/null | grep -c 'j AGH_V6DNS')"
echo "  vpnmode=$(grep -m1 '^vpn_compat=' $A/scripts/config.prop)"
echo "== dns =="
for d in www.baidu.com www.taobao.com www.jd.com www.zhihu.com www.bilibili.com www.qq.com; do
  printf '  %-18s %s\n' "$d" "$(curl -s -o /dev/null -m 8 -w '%{http_code} %{time_namelookup}s' "http://$d/" 2>/dev/null)"
done
echo "== block =="
for d in doubleclick.net google-analytics.com adservice.google.com pagead2.googlesyndication.com v1.cnzz.com; do
  printf '  %-30s %s\n' "$d" "$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$d/" 2>/dev/null)"
done
echo "== arch =="
echo "  kernel=$(uname -m) abi=$(getprop ro.product.cpu.abi) sdk=$(getprop ro.build.version.sdk) model=$(getprop ro.product.model)"
echo "== log tail =="
tail -6 $A/agh.log 2>/dev/null
grep -c ERROR $A/agh.log 2>/dev/null | sed 's/^/  errors=/'
echo "== lock =="
ls -d $A/.ipt.lock 2>/dev/null || echo "  no lock"
exit 0