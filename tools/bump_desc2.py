import io

DESC_OLD_TAIL = '③ 版本号改成纯日期，不再带 v31 这种序号。'
DESC_NEW = (
    '③ 版本号改成纯日期，不再带 v31 这种序号。'
    '④ 修掉一个更严重的旧 bug：iptables 里原本有一条「uid 0 全豁免」，而 Android 的系统解析器 '
    'dnsproxyd 就跑在 netd（uid 0）里——等于所有 App 的 DNS 查询全部绕过 AGH，装了模块也只是看着像在拦。'
    '现在改成：SmartDNS（uid 9999）豁免、回环（-o lo）豁免、dnsenc 的 bootstrap（root 只对 223.5.5.5:53）精确豁免，'
    '其余一律劫持。实测改完后 AGH 立刻能看到真实客户端（192.168.0.9）与真实域名查询，'
    '广告域名在系统解析器层面被拦（unknown host）。'
)
P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\module.prop"
s = io.open(P, encoding="utf-8").read()
assert s.count(DESC_OLD_TAIL) == 1
s = s.replace(DESC_OLD_TAIL, DESC_NEW)
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("module.prop:", len(s))

M = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\ModuleMOD.sh"
m = io.open(M, encoding="utf-8").read()
print("--- ModuleMOD desc 段 ---")
for i, line in enumerate(m.splitlines(), 1):
    if "DESC_ZH" in line or "DESC_EN" in line:
        print(i, line[:200])