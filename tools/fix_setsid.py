# -*- coding: utf-8 -*-
"""两种兜底修正：
1) setsid 的兜底不能依赖 nohup（有的 ROM 两个都没有）→ 改成纯后台
2) service.sh 的启动依赖 nohup？不，init 负责；但 start_helper 用 setsid，兜底同样要能干活
"""
import io, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"

OLD = '''if ! command -v setsid >/dev/null 2>&1; then
    setsid() {
        # 没有 setsid：用 nohup + 后台，已经是后台就不用再套
        nohup "$@" </dev/null >/dev/null 2>&1 &
    }
fi'''
NEW = '''if ! command -v setsid >/dev/null 2>&1; then
    setsid() {
        # 没有 setsid：直接后台（不依赖 nohup —— 少数 ROM 两个都没有）
        "$@" </dev/null >/dev/null 2>&1 &
    }
fi'''

for f in (HOME + r"\scripts\iptables.sh", HOME + r"\service.sh", HOME + r"\scripts\sd-restart.sh"):
    s = io.open(f, encoding="utf-8").read()
    if OLD in s:
        s = s.replace(OLD, NEW, 1)
        io.open(f, "w", encoding="utf-8", newline="\n").write(s)
        print("%-22s %dB md5=%s" % (f.split("Adguardhome")[-1], len(s.encode()),
                                    hashlib.md5(s.encode()).hexdigest()[:12]))
    else:
        print("!! pattern miss:", f.split("Adguardhome")[-1])