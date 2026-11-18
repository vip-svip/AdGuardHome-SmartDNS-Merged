# -*- coding: utf-8 -*-
"""arch 守卫 + curl 守卫落地，并把改动推设备。"""
import io, re, sys, os

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
SVC = HOME + r"\service.sh"
IPT = HOME + r"\scripts\iptables.sh"

# ---------- arch 守卫：service.sh 顶部 ----------
s = io.open(SVC, encoding="utf-8").read()
ARCH = r'''
# ---------------------------------------------------------------
# CPU 架构守卫：模块自带的是 arm64 静态二进制。32 位设备上一跑就是
# "Exec format error"，日志里很难看出原因，所以启动前先判一次并写清楚。
# ---------------------------------------------------------------
ARCH_OK=1
case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
    arm64*|aarch64*) ARCH_OK=1 ;;
    x86*|i386*|i686*) ARCH_OK=0 ;;
    armeabi*|arm*) ARCH_OK=0 ;;
    *) case "$(uname -m 2>/dev/null)" in aarch64|arm64) ARCH_OK=1 ;; *) ARCH_OK=0 ;; esac ;;
esac
'''
if "ARCH_OK=1" not in s:
    m = re.search(r'^ADGPATH="/data/adb/modules/AdGuardHome"\n', s, re.M)
    s = s[:m.end()] + ARCH + s[m.end():]

# 在启动 AGH 之前判架构
guardarch = '''    if [ "${ARCH_OK:-1}" != "1" ]; then
        echo "$(date '+%F %T') [ERROR] 本机 ABIs $(getprop ro.product.cpu.abilist) 与模块内置的 arm64 二进制不匹配，无法启动 AdGuardHome。" >> "$MAIN_LOG"
        return 1
    fi
'''
old = '''    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    # 部分设备'''
if guardarch not in s:
    s = s.replace(old, guardarch + '''    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    # 部分设备''', 1)

# ---------- curl 守卫：把两段自愈用 HAVE_CURL 包起来 ----------
for fn in ("agh_filter_heal() {", "sd_suspend_guard() {"):
    i = s.find(fn)
    if i < 0:
        print("!! 找不到", fn)
        continue
    # 在函数体开头插入 HAVE_CURL 判定
    j = s.find("\n}", i)
    body = s[i:j]
    if "HAVE_CURL" in body:
        print("  already guarded:", fn)
        continue
    ins = '\n    if [ "${HAVE_CURL:-1}" != "1" ]; then\n        log "[WARN] 本机没有 curl，跳过过滤器自愈（请手动在 6081/80 管理页刷新）。"\n        return 0\n    fi'
    # 插到函数第一行之后
    k = body.find("\n") + 1
    body2 = body[:k] + ins + body[k:]
    s = s[:i] + body2 + s[j:]
    print("  guarded:", fn)

io.open(SVC, "w", encoding="utf-8", newline="\n").write(s)
print("service.sh", len(s.encode()))

# ---------- iptables.sh：启动 smartdns 前也判架构 ----------
t = io.open(IPT, encoding="utf-8").read()
if "ARCH_OK=1" not in t:
    m = re.search(r'^BIN_DIR="\$AGH_DIR/bin"\n', t, re.M)
    t = t[:m.end()] + ARCH + t[m.end():]
io.open(IPT, "w", encoding="utf-8", newline="\n").write(t)
print("iptables.sh", len(t.encode()))
print("ARCH_OK in svc/ipt:",
      "ARCH_OK=1" in io.open(SVC, encoding="utf-8").read(),
      "ARCH_OK=1" in t)