import io, sys, subprocess, json, time
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
ADB = ["adb", "-s", "18e1870"]

def shell(cmd, t=900):
    r = subprocess.run(ADB + ["shell", cmd], capture_output=True, timeout=t)
    return ((r.stdout or b"") + (r.stderr or b"")).decode("utf-8", "replace").strip()

def shfile(dev, t=900):
    p = r"F:\BUG\_tmp_dev.sh"
    io.open(p, "w", encoding="utf-8", newline="\n").write(dev)
    subprocess.run(ADB + ["push", p, "/data/local/tmp/_t.sh"], capture_output=True, timeout=120)
    r = subprocess.run(ADB + ["shell", "su", "-c", "sh /data/local/tmp/_t.sh 2>/dev/null"], capture_output=True, timeout=t)
    return (r.stdout or b"").decode("utf-8", "replace").strip()

shell(r'''curl -s -m 8 -c /data/local/tmp/_ck -H 'Content-Type: application/json' -d '{"name":"root","password":"root"}' http://127.0.0.1:40251/control/login -o /dev/null''')

print("=== 1) 备份现有 user_rules ===")
out = shell(r'''curl -s -m 20 -b /data/local/tmp/_ck 'http://127.0.0.1:40251/control/filtering/status' ''')
j = json.loads(out)
rules = j.get("user_rules") or []
io.open(r"F:\BUG\_user_rules_backup.json", "w", encoding="utf-8", newline="\n").write(json.dumps(rules, ensure_ascii=False))
print("   已备份 %d 条 -> F:\\BUG\\_user_rules_backup.json" % len(rules))

print("\n=== 2) 生成大 body（约 6MiB，全部是注释行，不改变实际过滤行为）===")
pad = []
for i in range(300000):
    pad.append("# pad %06d aaaaaaaaaaaaaaaaaaaaaaaa" % i)
body = json.dumps({"rules": rules + pad}, ensure_ascii=False)
p = r"F:\BUG\_bigbody.json"
io.open(p, "w", encoding="utf-8", newline="\n").write(body)
size = len(body.encode("utf-8"))
print("   本地 body: %.2f MiB" % (size / 1048576.0))
subprocess.run(ADB + ["push", p, "/data/local/tmp/_big.json"], capture_output=True, timeout=300)
print("   设备端:", shell("ls -l /data/local/tmp/_big.json | awk '{print $5\" bytes\"}'"))

print("\n=== 3) POST /control/filtering/set_rules （>4MiB）===")
t0 = time.time()
out = shell(r'''curl -s -m 180 -o /data/local/tmp/_resp.txt -w '%{http_code}' -b /data/local/tmp/_ck -H 'Content-Type: application/json' --data-binary @/data/local/tmp/_big.json 'http://127.0.0.1:40251/control/filtering/set_rules' ''')
dt = time.time() - t0
print("   HTTP %s   耗时 %.1fs" % (out, dt))
print("   resp:", shell("head -c 300 /data/local/tmp/_resp.txt"))

print("\n=== 4) 服务端实际吃进多少条 ===")
out = shell(r'''curl -s -m 60 -b /data/local/tmp/_ck 'http://127.0.0.1:40251/control/filtering/status' ''')
j = json.loads(out)
print("   user_rules 条数:", len(j.get("user_rules") or []), "(= 原 1280 + 300000 注释 = 301280 才算完整接收)")

print("\n=== 5) 还原原始 user_rules ===")
p2 = r"F:\BUG\_user_rules_restore.json"
io.open(p2, "w", encoding="utf-8", newline="\n").write(json.dumps({"rules": rules}, ensure_ascii=False))
subprocess.run(ADB + ["push", p2, "/data/local/tmp/_restore.json"], capture_output=True, timeout=120)
print("  ", shell(r'''curl -s -m 120 -o /dev/null -w '%{http_code}' -b /data/local/tmp/_ck -H 'Content-Type: application/json' --data-binary @/data/local/tmp/_restore.json 'http://127.0.0.1:40251/control/filtering/set_rules' '''))
out = shell(r'''curl -s -m 60 -b /data/local/tmp/_ck 'http://127.0.0.1:40251/control/filtering/status' ''')
j = json.loads(out)
print("   还原后 user_rules:", len(j.get("user_rules") or []))
print(shfile('''#!/system/bin/sh
rm -f /data/local/tmp/_big.json /data/local/tmp/_restore.json /data/local/tmp/_resp.txt
echo "   临时大文件已清理"
'''))