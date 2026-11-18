# -*- coding: utf-8 -*-
"""再一轮设备兼容：
1) mountpoint 缺失时用 /proc/mounts 兜底（老 toybox 没有 mountpoint）
2) setsid 缺失时退回 nohup/直接后台（部分 ROM 无 setsid）
3) chroot 缺失时明确报错（不做静默失败）
"""
import io, re, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"

SHIM = r'''
# ---------------------------------------------------------------
# 设备兼容层（第二批）：
#   mountpoint  部分老 toybox 没有 → 用 /proc/mounts 兜底
#   setsid      极少数 ROM 裁掉 → 退回 nohup + &
#   chroot      缺失时给出明确报错，而不是静默不启动 SmartDNS
# ---------------------------------------------------------------
if ! command -v mountpoint >/dev/null 2>&1; then
    mountpoint() {
        _q=""
        [ "$1" = "-q" ] && { _q=1; shift; }
        grep -qs " $1 " /proc/mounts
    }
fi

if ! command -v setsid >/dev/null 2>&1; then
    setsid() {
        # 没有 setsid：用 nohup + 后台，已经是后台就不用再套
        nohup "$@" </dev/null >/dev/null 2>&1 &
    }
fi

sd_chroot_ok() {
    command -v chroot >/dev/null 2>&1 && return 0
    log "[ERROR] 本机没有 chroot 命令，SmartDNS 无法在容器内运行；请改用其他机型或内置的替代上游。"
    return 1
}
'''

for f in (HOME + r"\scripts\iptables.sh", HOME + r"\service.sh", HOME + r"\scripts\sd-restart.sh"):
    s = io.open(f, encoding="utf-8").read()
    if "mountpoint()" in s:
        print("skip (already):", f.split("Adguardhome")[-1])
        continue
    # 插到 port_listening 函数之后（三份文件都有）
    i = s.find("port_listening() {")
    assert i > 0, f
    j = s.find("\n}\n", i) + len("\n}\n")
    s = s[:j] + SHIM + s[j:]
    io.open(f, "w", encoding="utf-8", newline="\n").write(s)
    print("%-22s %dB md5=%s" % (f.split("Adguardhome")[-1], len(s.encode()),
                                hashlib.md5(s.encode()).hexdigest()[:12]))

# smartdns 启动前判 chroot
for f in (HOME + r"\service.sh", HOME + r"\scripts\iptables.sh", HOME + r"\scripts\sd-restart.sh"):
    s = io.open(f, encoding="utf-8").read()
    if "sd_chroot_ok" not in s:
        continue
    n = s.count("setsid chroot")
    if n and 'sd_chroot_ok || return 1' not in s:
        # 在每个 setsid chroot 之前插入守卫（保持缩进）
        s = re.sub(r"(\n)(\s*)setsid chroot ", r"\1\2sd_chroot_ok || return 1\1\2setsid chroot ", s)
        io.open(f, "w", encoding="utf-8", newline="\n").write(s)
        print("  guarded setsid chroot x%d in %s" % (n, f.split("Adguardhome")[-1]))