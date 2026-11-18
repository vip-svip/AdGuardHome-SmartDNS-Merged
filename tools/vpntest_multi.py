# -*- coding: utf-8 -*-
"""多设备 VPN 共存 + v6 回归：造 tun7 → auto 让路 → proxy 豁免 → off → 回 auto。"""
import io, sys, subprocess, time

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
sys.path.insert(0, r"F:\BUG")
import dev  # noqa: E402

sn = sys.argv[1] if len(sys.argv) > 1 else dev.pick()
ADB = ["adb", "-s", sn]


def sh(c, t=600):
    p = subprocess.run(ADB + ["shell", c], capture_output=True, timeout=t)
    return ((p.stdout or b"") + (p.stderr or b"")).decode("utf-8", "replace")


def su(c, t=600):
    p = subprocess.run(ADB + ["shell", "su", "-c", c], capture_output=True, timeout=t)
    return ((p.stdout or b"") + (p.stderr or b"")).decode("utf-8", "replace")


SCRIPT = r'''#!/system/bin/sh
A=/data/adb/agh
CFG=$A/scripts/config.prop
ACT() { _a=""; for c in ADGUARD ADGUARDB; do iptables -w 2 -t nat -C OUTPUT -j $c 2>/dev/null && _a=$c; done; echo "$_a"; }
snap() {
  _a=$(ACT)
  if [ -n "$_a" ]; then
    echo "    active=$_a rules=$(iptables -w 2 -t nat -S $_a 2>/dev/null | tail -n +2 | wc -l) jump=1 redir=$(iptables -w 2 -t nat -S $_a 2>/dev/null | grep -c 'dpt:53.*REDIRECT') tunn=$(iptables -w 2 -t nat -S $_a 2>/dev/null | grep -cE '\-o (tun|tap|ppp|utun|wg|ipsec)\+') uid=$(iptables -w 2 -t nat -S $_a 2>/dev/null | grep -c 'uid-owner 10')"
  else
    _r=$(iptables -w 2 -t nat -S ADGUARD 2>/dev/null | tail -n +2 | wc -l)
    echo "    active=none (ADGUARD keeps $_r) jump=0"
  fi
  echo "    v6: mode=$(grep -m1 '^v6_dns=' $CFG) jump6=$(ip6tables -t mangle -S OUTPUT 2>/dev/null | grep -c AGH_V6DNS)"
}
setmode() { sed -i "s|^[[:space:]]*vpn_compat=.*|vpn_compat=$1|" $CFG; sh $A/scripts/iptables.sh --once >/dev/null 2>&1; sleep 1; }
echo "== A. 当前（无 VPN）=="; snap
echo "== B. 造 tun7 =="
ip tuntap add dev tun7 mode tun 2>/dev/null; ip link set tun7 up 2>/dev/null
setmode auto; snap
echo "== C. proxy + tun7 =="
setmode proxy; snap
echo "== D. off + tun7 =="
setmode off; snap
echo "== E. 删 tun7 + auto =="
ip link set tun7 down 2>/dev/null; ip tuntap del dev tun7 mode tun 2>/dev/null
setmode auto; snap
echo "== F. 解析 =="
for d in www.baidu.com www.qq.com; do
  printf '    %-16s %s\n' "$d" "$(curl -s -o /dev/null -m 8 -w '%{http_code} %{time_namelookup}s' http://$d/ 2>/dev/null)"
done
echo "== G. 日志 =="
grep -E 'VPN|vpn_compat' $A/agh.log | tail -6
exit 0
'''

io.open(r"F:\BUG\_vpntest.sh", "w", encoding="utf-8", newline="\n").write(SCRIPT)
subprocess.run(ADB + ["push", r"F:\BUG\_vpntest.sh", "/data/local/tmp/_vpntest.sh"], capture_output=True, timeout=300)
print("device:", sn)
print(su("sh /data/local/tmp/_vpntest.sh", 900))