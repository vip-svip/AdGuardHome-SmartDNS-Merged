import io, sys, re, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

MP = r"F:\BUG\AdguardHome-Magisk\Adguardhome\module.prop"
MM = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\ModuleMOD.sh"
VER, VC = "20261116-v31", "2026111631"

DESC_ZH = ("[v31] AdGuard Home 20261116-v31，重点：不再和 VPN 冲突。新增 vpn_compat 三种模式（6081 "
           "管理页「VPN 共存」卡片可一键切换，也可写 scripts/config.prop）：auto 默认，检测到 tun/tap/"
           "ppp/utun/wg/ipsec 隧道接口就把 DNS 劫持让路（ADGUARD 链清空成只 RETURN、从 OUTPUT 摘掉跳转），"
           "解析完全交给 VPN，断开 5 秒内自动恢复；proxy 串联共存，始终劫持但豁免隧道出流量（lo/tun+/tap+/"
           "ppp+/utun+/wg+/ipsec+）、以及 Clash/mihomo/v2ray 等 VPN 应用自身 uid 的查询，避免解析环；"
           "off 退回全量劫持。跳转从 -I 改 -A 追加到 OUTPUT 末尾，不抢代理自己的 dport 53 规则；只动自己的 "
           "ADGUARD/ADGUARD6 链。另修：config.prop 的 redir_port 与 AGH yaml dns.port 脱钩会导致 DNS 全挂，"
           "现在每次以 yaml 为准自动校正；管理页切换模式立刻重建规则（--once），重建加 mkdir 原子锁避免重复条；"
           "升级保留 vpn_compat/vpn_apps/PROXY_URL；修 PROXY_URL 追加缺换行把下一行拼坏的 bug。"
           "+ SmartDNS 48.5-RC1 + 加密上游（DoH/DoH3/DoT/DoQ/DNSCrypt）+ 按域名分流 + 卸载快照可恢复"
           "（AGH 40251 · smartdns 6080 · 上游管理 6081）")

DESC_EN = ("[v31] AdGuard Home 20261116-v31 -- no longer conflicts with VPNs. New vpn_compat with three "
           "modes (switch it from the 'VPN coexistence' card on the 6081 manager, or set it in "
           "scripts/config.prop): auto (default) detects a live tun/tap/ppp/utun/wg/ipsec tunnel and steps "
           "the DNS hijack aside -- the ADGUARD chain is emptied to a single RETURN and the OUTPUT jump is "
           "removed, so resolution goes entirely to the VPN, and the hijack comes back within 5 seconds "
           "after the tunnel drops; proxy keeps the hijack but exempts traffic leaving through a tunnel "
           "(lo/tun+/tap+/ppp+/utun+/wg+/ipsec+) and queries from the VPN apps' own uids (Clash/mihomo/"
           "v2ray), which avoids the resolution loop; off returns to unconditional hijacking. The OUTPUT "
           "jump now appends with -A instead of inserting with -I so proxy dport-53 rules win, and only "
           "our own ADGUARD/ADGUARD6 chains are touched. Also fixed: redir_port drifting away from the AGH "
           "yaml dns.port silently killed all DNS -- it is now re-synced from the yaml on every pass; mode "
           "switches rebuild rules immediately via --once under an atomic mkdir lock (no duplicate rules); "
           "upgrades preserve vpn_compat/vpn_apps/PROXY_URL; and PROXY_URL is no longer appended without a "
           "trailing newline (which glued the next line onto it). + SmartDNS 48.5-RC1 + encrypted upstreams "
           "(DoH/DoH3/DoT/DoQ/DNSCrypt) + per-domain routing + restorable uninstall snapshot "
           "(AGH 40251 / smartdns 6080 / upstream mgr 6081)")

s = io.open(MP, encoding="utf-8").read()
s = re.sub(r'^version=.*$', 'version=' + VER, s, flags=re.M)
s = re.sub(r'^versionCode=.*$', 'versionCode=' + VC, s, flags=re.M)
s = re.sub(r'^description=.*$', 'description=' + DESC_ZH, s, flags=re.M)
io.open(MP, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(MP, "rb").read()
print("module.prop", len(raw), hashlib.md5(raw).hexdigest())

s = io.open(MM, encoding="utf-8").read()
s = re.sub(r"DESC_ZH=('|\").*?\1\n", lambda m: "DESC_ZH=" + m.group(1) + DESC_ZH + m.group(1) + "\n", s, flags=re.S)
s = re.sub(r"DESC_EN=('|\").*?\1\n", lambda m: "DESC_EN=" + m.group(1) + DESC_EN + m.group(1) + "\n", s, flags=re.S)
io.open(MM, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(MM, "rb").read()
txt = raw.decode("utf-8")
print("ModuleMOD.sh", len(raw), hashlib.md5(raw).hexdigest(),
      "| v31:", "v31" in txt, "| v30 residue:", "v30" in txt)