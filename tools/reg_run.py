# -*- coding: utf-8 -*-
"""跑设备侧综合回归。"""
import subprocess, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
import dev

SN = dev.pick()
print("device:", SN)
subprocess.run(["adb", "-s", SN, "push", r"F:\BUG\_regress.sh", "/data/local/tmp/_regress.sh"],
               capture_output=True, check=True)
r = subprocess.run(["adb", "-s", SN, "shell", "su -c 'sh /data/local/tmp/_regress.sh'"],
                   capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=420)
print(r.stdout)
if r.stderr.strip():
    print("STDERR:", r.stderr[-500:])