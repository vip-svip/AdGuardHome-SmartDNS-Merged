# -*- coding: utf-8 -*-
"""给 CGI 补 dirname/basename 兜底。"""
import io, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\cgi-bin\upstream"
s = io.open(P, encoding="utf-8").read()

ADD = (
    "if ! command -v dirname >/dev/null 2>&1; then\n"
    "    dirname() { printf '%s\\n' \"${1%/*}\"; }\n"
    "fi\n"
    "if ! command -v basename >/dev/null 2>&1; then\n"
    "    basename() { _s=\"${1%/}\"; printf '%s\\n' \"${_s##*/}\"; }\n"
    "fi\n"
)
ANCHOR = "if ! command -v pgrep >/dev/null 2>&1; then"
if "command -v dirname" in s:
    print("already")
else:
    assert s.count(ANCHOR) == 1
    s = s.replace(ANCHOR, ADD + ANCHOR, 1)
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("CGI ->", len(s.encode()), hashlib.md5(s.encode()).hexdigest())