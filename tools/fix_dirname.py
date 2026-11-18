# -*- coding: utf-8 -*-
"""补 dirname / basename 的纯 shell 兜底（toybox 里通常有，但精简 ROM 可能缺；
缺了会导致 mkdir -p "$(dirname ...)" 变成 mkdir -p "" 从而静默失败）。"""
import io, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"

EXTRA = r'''
if ! command -v dirname >/dev/null 2>&1; then
    dirname() { printf '%s\n' "${1%/*}"; }
fi
if ! command -v basename >/dev/null 2>&1; then
    basename() {
        _s="${1%/}"
        printf '%s\n' "${_s##*/}"
    }
fi
'''

TAG = '''if ! command -v setsid >/dev/null 2>&1; then'''
for f in (HOME + r"\scripts\iptables.sh", HOME + r"\service.sh", HOME + r"\scripts\sd-restart.sh",
          HOME + r"\scripts\webui\cgi-bin\upstream"):
    s = io.open(f, encoding="utf-8").read()
    if "command -v dirname" in s:
        print("skip:", f.split("Adguardhome")[-1])
        continue
    if TAG not in s:
        print("!! no anchor:", f.split("Adguardhome")[-1])
        continue
    s = s.replace(TAG, EXTRA.strip("\n") + "\n\n" + TAG, 1)
    io.open(f, "w", encoding="utf-8", newline="\n").write(s)
    print("%-34s %dB md5=%s" % (f.split("Adguardhome")[-1], len(s.encode()),
                                hashlib.md5(s.encode()).hexdigest()[:12]))