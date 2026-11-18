# -*- coding: utf-8 -*-
"""修 sd_suspend_guard 的 JSON（上一版替换多了一个引号）并从 config.prop 读凭据。"""
import io, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
SVC = r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh"
s = io.open(SVC, encoding="utf-8").read()

bad = '''    _tok=$("$_bb" wget -qO- --post-data="{\\"username\\":\\"${sd_user:-root}\\",\\"password\\":\\"${sd_pass:-root}\\"}"}         --header='Content-Type: application/json' http://127.0.0.1:6080/api/auth/login 2>/dev/null         | sed -n 's/.*"token":"\\([^"]*\\)".*/\\1/p')'''
good = '''    _su=$(sed -n 's/^[[:space:]]*sd_user=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null | head -1)
    _sp=$(sed -n 's/^[[:space:]]*sd_pass=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null | head -1)
    [ -n "$_su" ] || _su=root
    [ -n "$_sp" ] || _sp=root
    _tok=$("$_bb" wget -qO- --post-data="{\\"username\\":\\"$_su\\",\\"password\\":\\"$_sp\\"}" \\
          --header='Content-Type: application/json' http://127.0.0.1:6080/api/auth/login 2>/dev/null \\
          | sed -n 's/.*"token":"\\([^"]*\\)".*/\\1/p')'''

if bad in s:
    s = s.replace(bad, good, 1)
    print("sd creds fixed")
else:
    # 模糊定位：找到含 password 的 _tok 行并整段替换
    lines = s.split("\n")
    idx = [i for i, l in enumerate(lines) if '_tok=$(' in l and 'password' in l]
    print("fallback idx:", idx)
    for i in idx:
        lines[i] = good.split("\n")[4]
        # 前面插凭据读取
        lines[i:i] = [good.split("\n")[0], good.split("\n")[1], good.split("\n")[2], good.split("\n")[3]]
    s = "\n".join(lines)

io.open(SVC, "w", encoding="utf-8", newline="\n").write(s)
print("service.sh", len(s.encode()), hashlib.md5(s.encode()).hexdigest()[:12])

import re
blk = s[s.find("sd_suspend_guard()"):s.find("sd_suspend_guard()") + 900]
for l in blk.split("\n")[:20]:
    print("   ", l)