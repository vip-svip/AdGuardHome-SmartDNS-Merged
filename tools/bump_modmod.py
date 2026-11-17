import io, re

M = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\ModuleMOD.sh"
m = io.open(M, encoding="utf-8").read()
orig = m

ZH_ADD = ('④ 修掉一个更严重的旧 bug：原先 iptables 里有一条「uid 0 全豁免」，'
          '而 Android 的系统解析器 dnsproxyd 就跑在 netd（uid 0）里，等于所有 App 的 DNS 全部绕过 AGH。'
          '现在只豁免 SmartDNS(uid 9999)、回环(-o lo) 和 dnsenc 的 bootstrap(root 仅 223.5.5.5:53)，'
          '其余一律劫持 —— 实测改完后 AGH 立刻能看到真实客户端与真实域名查询，广告域名在系统层面被拦。')

EN_ADD = (' (4) Fixed a serious old bug: the nat chain had a blanket "uid 0" exemption, and Android\'s '
          'resolver (dnsproxyd) runs inside netd, which is uid 0 -- so every app DNS query bypassed AGH. '
          'Now only SmartDNS (uid 9999), loopback (-o lo) and the dnsenc bootstrap (root, 223.5.5.5:53 only) '
          'are exempt; everything else is hijacked. Verified: AGH now sees real clients and real queries, '
          'and ad domains are blocked at the system resolver level.')

lines = m.splitlines(keepends=True)
out = []
for ln in lines:
    if ln.startswith('DESC_ZH="') and ln.rstrip().endswith('"'):
        body = ln.rstrip()
        out.append(body[:-1] + ZH_ADD + '"\n')
    elif ln.startswith('DESC_EN="') and ln.rstrip().endswith('"'):
        body = ln.rstrip()
        out.append(body[:-1] + EN_ADD + '"\n')
    else:
        out.append(ln)
m2 = "".join(out)
assert m2 != m
io.open(M, "w", encoding="utf-8", newline="\n").write(m2)
print("ModuleMOD.sh:", len(orig), "->", len(m2))

# 语法检查交给 emulator
p = r"F:\BUG\_tmp_modmod.sh"
io.open(p, "w", encoding="utf-8", newline="\n").write(m2)