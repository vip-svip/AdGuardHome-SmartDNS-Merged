# -*- coding: utf-8 -*-
"""在本机安装模块（多设备版）：自动挑装了/未装本模块的设备，支持指定序列号。"""
import io, sys, hashlib, subprocess, time, os

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
sys.path.insert(0, r"F:\BUG")
import dev  # noqa: E402

ZIP = r"F:\BUG\AdGuardHome-SmartDNS-Merged-20261117.zip"
TDST = "/data/local/tmp/AGH-install.zip"
M = "/data/adb/modules/AdGuardHome"

sn = sys.argv[1] if len(sys.argv) > 1 else None
if not sn:
    sn = dev.pick() or (dev.serials() or [None])[0]
if not sn:
    raise SystemExit("没有可用设备")
print("device:", sn)
ADB = ["adb", "-s", sn]


def sh(c, t=900):
    p = subprocess.run(ADB + ["shell", c], capture_output=True, timeout=t)
    return (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")


def su(c, t=900):
    p = subprocess.run(ADB + ["shell", "su", "-c", c], capture_output=True, timeout=t)
    return (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")


want = hashlib.md5(io.open(ZIP, "rb").read()).hexdigest()
print("local md5:", want)

print("\n=== 1. push zip ===")
r = subprocess.run(ADB + ["push", ZIP, TDST], capture_output=True, timeout=1800)
print((r.stdout or b"").decode("utf-8", "replace").strip()[-200:])
got = sh("md5sum %s 2>/dev/null | awk '{print $1}'" % TDST).strip()
print("device md5:", got, "OK" if got == want else "!! 不一致")
if got != want:
    raise SystemExit("push 校验失败")

print("\n=== 2. 停栈 + 解锁 ===")
STOP = r"""
A=/data/adb/agh
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
  case "$c" in
    *bin/AdGuardHome*|*bin/dnsenc*|*smartdns*|*scripts/iptables.sh*|*scripts/webui*|*busybox\ httpd*)
      p=${d#/proc/}; [ "$p" = "$$" ] || kill -9 "$p" 2>/dev/null ;;
  esac
done
sleep 1
for f in /data/adb/modules/AdGuardHome/scripts/*.sh /data/adb/modules/AdGuardHome/action.sh /data/adb/modules/AdGuardHome/uninstall.sh; do
  [ -f "$f" ] && chattr -i "$f" 2>/dev/null
done
exit 0
"""
io.open(r"F:\BUG\_stop.sh", "w", encoding="utf-8", newline="\n").write(STOP)
subprocess.run(ADB + ["push", r"F:\BUG\_stop.sh", "/data/local/tmp/_stop.sh"], capture_output=True, timeout=300)
print(su("sh /data/local/tmp/_stop.sh").strip() or "  (stopped)")

print("\n=== 3. 安装（customize.sh）===")
INST = r"""
M=/data/adb/modules/AdGuardHome
chattr -i $M/scripts/*.sh 2>/dev/null
rm -rf "$M"
mkdir -p "$M"
unzip -oq /data/local/tmp/AGH-install.zip -d "$M"
echo "  unzip rc=$?"
# 装前保留：把已有 AGH 目录里的配置备份留一份，customize 会读 $M/backup
mkdir -p "$M/backup"
[ -f /data/adb/agh/bin/AdGuardHome.yaml ] && cp -f /data/adb/agh/bin/AdGuardHome.yaml "$M/backup/" 2>/dev/null
[ -f /data/adb/agh/scripts/config.prop ] && cp -f /data/adb/agh/scripts/config.prop "$M/backup/" 2>/dev/null
[ -d /data/adb/agh/backup ] && cp -rf /data/adb/agh/backup/. "$M/backup/" 2>/dev/null
rm -f "$M"/rules/subscriptions/*.txt 2>/dev/null
rm -rf "$M"/bin/data/filters 2>/dev/null
ui_print() { echo "$@"; }
MODPATH="$M"; ZIPFILE=/data/local/tmp/AGH-install.zip; export MODPATH ZIPFILE
. "$MODPATH/customize.sh"
echo "INSTALL_EXIT=$?"
exit 0
"""
io.open(r"F:\BUG\_inst.sh", "w", encoding="utf-8", newline="\n").write(INST)
subprocess.run(ADB + ["push", r"F:\BUG\_inst.sh", "/data/local/tmp/_inst.sh"], capture_output=True, timeout=300)
out = su("sh /data/local/tmp/_inst.sh")
print(out.strip()[-2500:])

print("\n=== 4. 启动（service.sh）===")
BOOT = r"""
M=/data/adb/modules/AdGuardHome
nohup sh $M/service.sh </dev/null >/data/local/tmp/_boot.log 2>&1 &
sleep 2
echo started
exit 0
"""
io.open(r"F:\BUG\_boot.sh", "w", encoding="utf-8", newline="\n").write(BOOT)
subprocess.run(ADB + ["push", r"F:\BUG\_boot.sh", "/data/local/tmp/_boot.sh"], capture_output=True, timeout=300)
print(su("sh /data/local/tmp/_boot.sh").strip())
for i in range(12):
    time.sleep(5)
    o = sh("tail -6 /data/adb/agh/agh.log 2>/dev/null || tail -6 /data/local/tmp/_boot.log 2>/dev/null")
    print("--- t+%ds ---" % ((i + 1) * 5))
    print(o.strip())
    if "AdGuardHome 启动成功" in o or "AdGuard Home 启动成功" in o:
        break
print("\n=== done ===")