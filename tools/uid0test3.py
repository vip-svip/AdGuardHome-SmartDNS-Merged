import io, sys, subprocess, random, string
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
ADB = ["adb", "-s", "18e1870"]

def shell(cmd, t=600):
    r = subprocess.run(ADB + ["shell", cmd], capture_output=True, timeout=t)
    return ((r.stdout or b"") + (r.stderr or b"")).decode("utf-8", "replace").strip()

def shfile(dev, t=900):
    p = r"F:\BUG\_tmp_dev.sh"
    io.open(p, "w", encoding="utf-8", newline="\n").write(dev)
    subprocess.run(ADB + ["push", p, "/data/local/tmp/_t.sh"], capture_output=True, timeout=120)
    r = subprocess.run(ADB + ["shell", "su", "-c", "sh /data/local/tmp/_t.sh 2>/dev/null"], capture_output=True, timeout=t)
    return (r.stdout or b"").decode("utf-8", "replace").strip()

def counters(tag):
    v4 = shfile(r'''#!/system/bin/sh
iptables -w 2 -t nat -L ADGUARD -v -n 2>/dev/null | awk '/REDIRECT/ {printf "%s ", $1}'
''' + "echo\n")
    v6 = shfile(r'''#!/system/bin/sh
ip6tables -w 2 -t mangle -L AGH_V6DNS -v -n 2>/dev/null | awk '$3=="DROP" && $4=="udp" {printf "%s ", $1}'
''' + "echo\n")
    print("  [%s] v4 REDIRECT pkts = %s | v6 udp DROP pkts = %s" % (tag, v4.strip(), v6.strip()))

print("=== 0) 清掉重复规则，只留 1 条 uid9999 + 1 条 uid0（v4/v6）===")
print(shfile(r'''#!/system/bin/sh
n=0
while [ $n -lt 8 ]; do
  iptables -w 2 -t nat -D ADGUARD -m owner --uid-owner 9999 -j RETURN 2>/dev/null || break
  n=$((n+1))
done
n=0
while [ $n -lt 8 ]; do
  iptables -w 2 -t nat -D ADGUARD -m owner --uid-owner 0 -j RETURN 2>/dev/null || break
  n=$((n+1))
done
iptables -w 2 -t nat -I ADGUARD 1 -m owner --uid-owner 9999 -j RETURN
iptables -w 2 -t nat -I ADGUARD 2 -m owner --uid-owner 0 -j RETURN
echo "  v4:"; iptables -w 2 -t nat -S ADGUARD | sed -n '2,5p' | sed 's/^/    /'
n=0
while [ $n -lt 8 ]; do
  ip6tables -w 2 -t mangle -D AGH_V6DNS -m owner --uid-owner 9999 -j RETURN 2>/dev/null || break
  n=$((n+1))
done
n=0
while [ $n -lt 8 ]; do
  ip6tables -w 2 -t mangle -D AGH_V6DNS -m owner --uid-owner 0 -j RETURN 2>/dev/null || break
  n=$((n+1))
done
ip6tables -w 2 -t mangle -I AGH_V6DNS 1 -m owner --uid-owner 9999 -j RETURN
ip6tables -w 2 -t mangle -I AGH_V6DNS 2 -m owner --uid-owner 0 -j RETURN
echo "  v6:"; ip6tables -w 2 -t mangle -S AGH_V6DNS | sed -n '2,5p' | sed 's/^/    /'
'''))

print("\n=== 1) 网络 id 与 netd DNS 缓存刷新 ===")
print(shell("ndc resolver flushdefaultif 2>&1; echo rc=$?") or "  (flushdefaultif 无输出)")
print(shell("for id in 135 107 108; do echo -n \"  net $id: \"; ndc resolver clearnetdns $id 2>&1; echo; done"))

print("\n=== 2) 基线计数（清缓存后）===")
counters("before")

print("\n=== 3) 用全新随机域名查询（避免 netd 缓存），现状 uid0 豁免仍在 ===")
for i in range(3):
    d = "q%s%d.test-dns-probe.net" % ("".join(random.choices(string.ascii_lowercase, k=6)), i)
    out = shell("ping -c 1 -W 3 %s" % d).splitlines()
    print("  %-38s -> %s" % (d, out[0][:52] if out else "(无输出)"))
counters("after-baseline")

print("\n=== 4) 去掉 v4+v6 的 uid0 豁免，再查新域名 ===")
print(shfile(r'''#!/system/bin/sh
iptables -w 2 -t nat -D ADGUARD -m owner --uid-owner 0 -j RETURN 2>/dev/null
ip6tables -w 2 -t mangle -D AGH_V6DNS -m owner --uid-owner 0 -j RETURN 2>/dev/null
echo "  v4:"; iptables -w 2 -t nat -S ADGUARD | sed -n '2,4p' | sed 's/^/    /'
echo "  v6:"; ip6tables -w 2 -t mangle -S AGH_V6DNS | sed -n '2,4p' | sed 's/^/    /'
echo -n "  flush: "; ndc resolver clearnetdns 135 2>&1; echo
'''))
for i in range(3):
    d = "r%s%d.test-dns-probe.net" % ("".join(random.choices(string.ascii_lowercase, k=6)), i)
    out = shell("ping -c 1 -W 3 %s" % d).splitlines()
    print("  %-38s -> %s" % (d, out[0][:52] if out else "(无输出)"))
counters("after-nouid0")