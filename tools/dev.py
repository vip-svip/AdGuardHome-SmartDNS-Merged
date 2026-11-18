# -*- coding: utf-8 -*-
"""设备选择：优先挑装了本模块（/data/adb/agh 存在）的设备，避免序列号变化或插错机器。"""
import subprocess


def _adb(*args, timeout=30):
    p = subprocess.run(["adb"] + list(args), capture_output=True, timeout=timeout)
    return (p.stdout or b"").decode("utf-8", "replace")


def serials():
    out = _adb("devices")
    res = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line or "\t" not in line:
            continue
        name, state = line.split("\t", 1)
        if state.strip() == "device":
            res.append(name.strip())
    return res


def has_module(sn):
    out = _adb("-s", sn, "shell", "su", "-c", "test -d /data/adb/agh && echo YES", timeout=60)
    return "YES" in out


def pick():
    cands = serials()
    for sn in cands:
        if has_module(sn):
            return sn
    return None


if __name__ == "__main__":
    print("serials:", serials())
    print("device with module:", pick())
