import io
p = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\upstream-manage.html"
s = io.open(p, encoding="utf-8").read()

# 1) 给 h2 里的 badge 单独一套样式（原来只有 li .badge，vpnBadge 在 h2 里没被命中）
old = '  li .badge{font-size:11px;color:var(--dim);font-family:inherit;margin-left:6px}\n'
new = (old +
       '  h2 .badge{font-size:11px;font-weight:600;font-family:inherit;margin-left:8px;\n'
       '    padding:1px 8px;border-radius:999px;vertical-align:middle;\n'
       '    color:var(--dim);background:rgba(127,127,127,.14)}\n'
       '  h2 .badge.ok{color:var(--ok);background:rgba(34,197,94,.16)}\n'
       '  h2 .badge.warn{color:#eab308;background:rgba(234,179,8,.16)}\n')
assert s.count(old) == 1, "badge css anchor %d" % s.count(old)
s = s.replace(old, new)

# 2) 劫持生效时用 ok 绿色；让路用 warn 黄色
old2 = "      badge.className = 'badge' + (hij ? '' : ' warn');\n"
new2 = "      badge.className = 'badge ' + (hij ? 'ok' : 'warn');\n"
assert s.count(old2) == 1, "badge class anchor %d" % s.count(old2)
s = s.replace(old2, new2)

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("OK bytes=%d" % len(s.encode("utf-8")))
print("h2 .badge rules:", s.count("h2 .badge"))