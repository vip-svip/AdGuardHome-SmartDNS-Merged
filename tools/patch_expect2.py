import io

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\cgi-bin\upstream"
s = io.open(P, encoding="utf-8").read()
orig = s

old = '''# 目标模式下 ADGUARD 链应有的 -A 条数（不含 -N）：
#   auto+无VPN / off = 4（uid9999, uid0, udp53, tcp53）
#   auto+有VPN = 1（只留 -j RETURN）
#   proxy = 11 + VPN应用uid数（4 基础 + 7 条出接口豁免 lo/tun/tap/ppp/utun/wg/ipsec）'''
new = '''# 目标模式下 ADGUARD 链应有的 -A 条数（不含 -N）：
#   auto+无VPN / off = 6（uid9999, -o lo, uid0→223.5.5.5 的 udp/tcp bootstrap, udp53, tcp53）
#   auto+有VPN = 1（只留 -j RETURN）
#   proxy = 12 + VPN应用uid数（6 基础 + 6 条出接口豁免 tun/tap/ppp/utun/wg/ipsec）
# 注意：不再豁免 uid 0 —— netd(dnsproxyd) 就是 uid 0，豁免它等于让系统 DNS 绕过 AGH。'''
assert s.count(old) == 1
s = s.replace(old, new)

old2 = '''        auto) if [ -n "$_v" ]; then echo 1; else echo 4; fi ;;
        off) echo 4 ;;
        proxy) echo $((11 + $(printf "%s" "$(vpn_uids)" | wc -w))) ;;'''
new2 = '''        auto) if [ -n "$_v" ]; then echo 1; else echo 6; fi ;;
        off) echo 6 ;;
        proxy) echo $((12 + $(printf "%s" "$(vpn_uids)" | wc -w))) ;;'''
assert s.count(old2) == 1
s = s.replace(old2, new2)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("cgi:", len(orig), "->", len(s))