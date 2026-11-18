# -*- coding: utf-8 -*-
"""彻底重写 sd_suspend_guard 的取 token 段（上一版折行被吃掉）。"""
import io, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
SVC = r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh"
s = io.open(SVC, encoding="utf-8").read()

lines = s.split("\n")
# 找到那一行残缺的 _tok= 行
idx = [i for i, l in enumerate(lines) if l.lstrip().startswith('_tok=$(') and 'wget' in l and 'username' in l]
print("residual lines:", idx)
assert len(idx) == 1
i = idx[0]
lines[i] = (
    '''    _json=$(printf '{"username":"%s","password":"%s"}' "$_su" "$_sp")
    _tok=$("$_bb" wget -qO- --post-data="$_json" --header='Content-Type: application/json' http://127.0.0.1:6080/api/auth/login 2>/dev/null | sed -n 's/.*"token":"\\([^"]*\\)".*/\\1/p')'''
)
s = "\n".join(lines)

# 校验：_tok 之后必须紧跟 [ -n "$_tok" ]
k = s.find("    _tok=$(")
print("--- context ---")
print("\n".join(s[k:k + 460].split("\n")))

io.open(SVC, "w", encoding="utf-8", newline="\n").write(s)
print("\nservice.sh", len(s.encode()), hashlib.md5(s.encode()).hexdigest()[:12])