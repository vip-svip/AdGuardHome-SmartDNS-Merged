import io
p = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\iptables.sh"
s = io.open(p, encoding="utf-8").read()

old = 'last_agh=""\nlast_vpnstate="__init__"\nwhile true; do\n'
new = ('last_agh=""\nlast_vpnstate="__init__"\n\n'
       '# --once：由 6081 管理页切换 vpn_compat 后同步重建一次就退出，不等守护循环的 5 秒\n'
       'if [ $ONCE -eq 1 ]; then\n    rebuild_rules\n    exit 0\nfi\n\n'
       'while true; do\n')
assert s.count(old) == 1, "matched %d" % s.count(old)
s = s.replace(old, new)

# ONCE 判定要在 sync_redir_port 之前至少不依赖它；确认插入位置在 pgrep guard 之前
assert "ONCE=0" in s, "ONCE flag missing"
assert s.index("ONCE=0") < s.index('pgrep -f "$0"'), "ONCE must precede the duplicate guard"

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("OK bytes=%d  lines=%d" % (len(s.encode("utf-8")), s.count("\n") + 1))