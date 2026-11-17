import io, sys, subprocess, json
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

print("=== 1) 当前链状态（uid0 已移除）===")
print(shfile(r'''#!/system/bin/sh
echo "  --- ADGUARD ---"; iptables -w 2 -t nat -S ADGUARD | sed 's/^/    /'
echo "  --- AGH_V6DNS ---"; ip6tables -w 2 -t mangle -S AGH_V6DNS | sed 's/^/    /'
'''))

print("\n=== 2) 真实域名解析（uid0 豁免已去掉，应走 AGH）===")
for d in ("www.baidu.com", "www.qq.com", "www.zhihu.com", "www.bilibili.com", "example.com"):
    out = shell("ping -c 1 -W 4 %s" % d).splitlines()
    print("  %-20s -> %s" % (d, out[0][:58] if out else "(无输出)"))

print("\n=== 3) 计数器（应增长）===")
print(shfile(r'''#!/system/bin/sh
echo "  v4:"; iptables -w 2 -t nat -L ADGUARD -v -n 2>/dev/null | awk '/REDIRECT|uid owner/ {printf "    %5s pkts  %s\n", $1, $NF}' | head -8
'''))

print("\n=== 4) AGH querylog 是否出现真实客户端 ===")
out = shell(r'''curl -s -m 8 -c /data/local/tmp/_ck -H 'Content-Type: application/json' -d '{"name":"root","password":"root"}' http://127.0.0.1:40251/control/login -o /dev/null -w '%{http_code}\n' ''')
print("  login:", out)
out = shell(r'''curl -s -m 8 -b /data/local/tmp/_ck 'http://127.0.0.1:40251/control/querylog?limit=25' ''')
try:
    j = json.loads(out)
    data = j.get("data") or []
    print("  条目数:", len(data))
    for e in data[:12]:
        print("   %-34s %-16s %s" % (e.get("question",{}).get("name"), e.get("client"), e.get("reason")))
except Exception as ex:
    print("  解析失败:", ex, out[:300])

print("\n=== 5) AGH 自身/上游是否受影响（smartdns 6053 直查）===")
print(shfile(r'''#!/system/bin/sh
/data/local/tmp/nslookup www.jd.com 127.0.0.1:6053 2>&1 | head -8 | sed 's/^/    /'
'''))