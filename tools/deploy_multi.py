# -*- coding: utf-8 -*-
"""把改动过的文件按 md5 校验推到设备（$A 运行目录与 $M 模块目录两份），
然后重启整套服务并跑回归。"""
import io, sys, hashlib, subprocess, time, os

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
sys.path.insert(0, r"F:\BUG")
import dev  # noqa: E402

HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
sn = sys.argv[1] if len(sys.argv) > 1 else dev.pick()
ADB = ["adb", "-s", sn]
A = "/data/adb/agh"
M = "/data/adb/modules/AdGuardHome"

JOBS = [
    (HOME + r"\scripts\iptables.sh", "scripts/iptables.sh", True),
    (HOME + r"\scripts\sd-restart.sh", "scripts/sd-restart.sh", True),
    (HOME + r"\scripts\config.prop", "scripts/config.prop", False),
    (HOME + r"\service.sh", "service.sh", True),
    (HOME + r"\customize.sh", "customize.sh", True),
    (HOME + r"\scripts\webui\cgi-bin\upstream", "scripts/webui/cgi-bin/upstream", True),
]


def sh(c, t=600):
    p = subprocess.run(ADB + ["shell", c], capture_output=True, timeout=t)
    return ((p.stdout or b"") + (p.stderr or b"")).decode("utf-8", "replace")


def su(c, t=600):
    p = subprocess.run(ADB + ["shell", "su", "-c", c], capture_output=True, timeout=t)
    return ((p.stdout or b"") + (p.stderr or b"")).decode("utf-8", "replace")


print("device:", sn)
for local, rel, keepmode in JOBS:
    raw = io.open(local, "rb").read()
    want = hashlib.md5(raw).hexdigest()
    tmp = "/data/local/tmp/_p.bin"
    subprocess.run(ADB + ["push", local, tmp], capture_output=True, timeout=600)
    for base in (A, M):
        d = base + "/" + rel
        ok = False
        for i in range(3):
            su("chattr -i %s 2>/dev/null; rm -f %s.tmp 2>/dev/null" % (d, d))
            su("cp -f %s %s.tmp && mv -f %s.tmp %s" % (tmp, d, d, d))
            got = sh("su -c 'md5sum %s 2>/dev/null' | awk '{print $1}'" % d).strip()
            if got == want:
                ok = True
                break
        print("  %-34s %-34s %s" % (rel, d.replace("/data/adb/", ""), "OK" if ok else "!! FAIL"))
    if keepmode:
        su("chmod 755 %s/%s %s/%s 2>/dev/null" % (A, rel, M, rel))

print("\n== restart stack ==")
STOP = r"""
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
  case "$c" in
    *bin/AdGuardHome*|*bin/dnsenc*|*smartdns*|*scripts/iptables.sh*|*scripts/webui*|*httpd\ -p*)
      p=${d#/proc/}; [ "$p" = "$$" ] || kill -9 "$p" 2>/dev/null ;;
  esac
done
sleep 2
rm -rf /data/adb/agh/.ipt.lock /data/adb/agh/.service.lock 2>/dev/null
exit 0
"""
io.open(r"F:\BUG\_stop2.sh", "w", encoding="utf-8", newline="\n").write(STOP)
subprocess.run(ADB + ["push", r"F:\BUG\_stop2.sh", "/data/local/tmp/_stop2.sh"], capture_output=True, timeout=300)
print(su("sh /data/local/tmp/_stop2.sh").strip() or "  stopped")
print(su("nohup sh %s/service.sh </dev/null >/data/local/tmp/_boot2.log 2>&1 & echo boot-started" % M).strip())

for i in range(14):
    time.sleep(5)
    o = sh("tail -8 /data/adb/agh/agh.log 2>/dev/null")
    print("--- t+%ds ---" % ((i + 1) * 5))
    print(o.strip())
    if "AdGuardHome 启动成功" in o or "AdGuard Home 启动成功" in o:
        break

print("\n== regression ==")
subprocess.run(ADB + ["push", r"F:\BUG\_regress.sh", "/data/local/tmp/_regress.sh"], capture_output=True, timeout=300)
print(sh("su -c 'sh /data/local/tmp/_regress.sh'", 900))