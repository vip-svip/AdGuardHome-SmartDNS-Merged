import io, re

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\iptables.sh"
s = io.open(P, encoding="utf-8").read()
orig = s

# ---------- 1) v4 ADGUARD：去掉 uid 0 全豁免，改为 lo + bootstrap 精确豁免 ----------
old = '''    # uid 0 (root) / uid 9999 (SmartDNS) 豁免: AGH/SmartDNS 自身出站查询不回环
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 9999 -j RETURN
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -j RETURN

    if [ "$vpn_compat" = proxy ]; then
        # 出接口是隧道的查询属于 VPN 自己，抢了会成环 / 打乱 fake-ip
        iptables -w 2 -t nat -A ADGUARD -o lo -j RETURN
        for _o in tun tap ppp utun wg ipsec; do'''
new = '''    # uid 9999 (SmartDNS) 豁免：它的明文上游查询要直出，不能被自己劫持
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 9999 -j RETURN
    # 回环豁免：本机解析器（127.0.0.1:53 之类）不出网，劫持它没有意义还会自环
    iptables -w 2 -t nat -A ADGUARD -o lo -j RETURN
    # 精确豁免 dnsenc 的 bootstrap 查询（root 身份问 223.5.5.5:53 解析 DoH 主机名）
    # 只放 root + 该目的地址 + 53 端口，普通 App 查 223.5.5.5 依旧被劫持
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -d 223.5.5.5 -p udp --dport 53 -j RETURN
    iptables -w 2 -t nat -A ADGUARD -m owner --uid-owner 0 -d 223.5.5.5 -p tcp --dport 53 -j RETURN
    # 注意：不再有「uid 0 全豁免」。root 里除了 AGH/dnsenc，还有 netd ——
    # 系统解析器 dnsproxyd 就是 uid 0，全豁免等于让所有 App 的 DNS 绕过 AGH。
    if [ "$vpn_compat" = proxy ]; then
        # 出接口是隧道的查询属于 VPN 自己，抢了会成环 / 打乱 fake-ip
        for _o in tun tap ppp utun wg ipsec; do'''
assert s.count(old) == 1
s = s.replace(old, new)

# ---------- 2) v6_exempt：去掉 uid 0，lo 无条件 ----------
old2 = '''v6_exempt() {
    ip6tables -w 2 "$@" -m owner --uid-owner 9999 -j RETURN 2>/dev/null
    ip6tables -w 2 "$@" -m owner --uid-owner 0 -j RETURN 2>/dev/null
    [ "$vpn_compat" = proxy ] || return 0
    ip6tables -w 2 "$@" -o lo -j RETURN 2>/dev/null
    for _o in tun tap ppp utun wg ipsec; do'''
new2 = '''v6_exempt() {
    ip6tables -w 2 "$@" -m owner --uid-owner 9999 -j RETURN 2>/dev/null
    ip6tables -w 2 "$@" -o lo -j RETURN 2>/dev/null
    [ "$vpn_compat" = proxy ] || return 0
    for _o in tun tap ppp utun wg ipsec; do'''
assert s.count(old2) == 1
s = s.replace(old2, new2)

# ---------- 3) 注释同步 ----------
s = s.replace(
    '# 和 v4 一致的豁免：AGH/SmartDNS 自身（uid 9999 / 0），proxy 模式下再加\n'
    '# 隧道出接口与 VPN 应用 uid，避免把 VPN 自己的 DNS 也吞掉。',
    '# 和 v4 一致的豁免：SmartDNS（uid 9999）+ 回环，proxy 模式下再加隧道出接口\n'
    '# 与 VPN 应用 uid，避免把 VPN 自己的 DNS 也吞掉。\n'
    '# 不再豁免 uid 0：netd 就是 uid 0，豁免它等于让系统解析器绕过 AGH。')

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("iptables.sh:", len(orig), "->", len(s), "bytes")