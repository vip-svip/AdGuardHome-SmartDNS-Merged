# -*- coding: utf-8 -*-
"""把版本号与描述刷成 20261119（纯日期），并换上新构建的 arm64 二进制。"""
import io, os, re, sys, hashlib, shutil

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

VER = "20261119"
MOD = r"F:\BUG\AdguardHome-Magisk\Adguardhome"

DESC_ZH = (
    "[" + VER + "] AdGuard Home " + VER + " + SmartDNS 48.5-RC1。"
    "本轮重点：多手机兼容。"
    "①ROM/内核差异兜底：iptables 的 -w 参数先探测再决定用不用（老 1.4.x 带 -w 会整链建不起来）、"
    "pgrep/netstat/ss/mountpoint/setsid/dirname/basename 缺失时全部有纯 shell 或 /proc 兜底、"
    "busybox 多路径探测、curl 缺失则跳过联网自愈、TZ 未设置时从 persist.sys.timezone 补齐（日志不再是 UTC）、"
    "非 arm64 设备直接给出明确 ABIs 不匹配提示而不是静默失败。"
    "②单实例竞态修复：service.sh 与 iptables.sh 的守护循环都会「检测不到 AGH 就拉起」，"
    "开机瞬间可能起两个实例抢端口；现在两边共用 .agh.start.lock 原子锁，实测并发启动后只有 1 个实例。"
    "③启动可靠性：AGH 若因会话库打开超时退出，自动清 data/sessions.db* 后重启；"
    "SmartDNS 以「6053 真的在监听」为启动判据，进程活着但不监听会自动重启；"
    "过滤器自愈改成先轮询 AGH API 就绪（首次启动曾因路由未注册拿到 404 而空转）、刷新失败自动重试。"
    "④IPv6：v6_dns=auto 时，内核没有 ip6tables nat 表就保持 keep（丢弃 v6 DNS 会让 netd 不回落 v4、整机解析挂），"
    "有 nat 表才 REDIRECT；drop 留给确认有可用 v4 DNS 的用户手动开。"
    "⑤DNS 劫持不再全豁免 uid 0（netd/dnsproxyd 就是 uid 0，全豁免等于系统 DNS 绕过 AGH），"
    "只精确豁免 dnsenc 的 bootstrap 解析（180.184.1.1:53）。"
    "另有：VPN 共存 auto/proxy/off、内置拦截列表（ABP 语法，168574 域名，不联网也能拦）、"
    "加密上游 DoH·DoH3·DoT·DoQ·DNSCrypt、按域名分流、卸载快照可恢复"
    "（AGH 40251 · smartdns 6080 · 上游管理 6081）"
)

DESC_EN = (
    "[" + VER + "] AdGuard Home " + VER + " + SmartDNS 48.5-RC1. Focus of this round: running on more phones. "
    "(1) ROM/kernel differences are probed instead of assumed: iptables gets -w only when the local xtables accepts it "
    "(old 1.4.x rejects -w and the whole chain fails to build); pgrep/netstat/ss/mountpoint/setsid/dirname/basename "
    "each fall back to pure-shell or /proc implementations; busybox is looked up on several paths; missing curl only "
    "disables the online self-heal; TZ is filled from persist.sys.timezone so logs stop being UTC; non-arm64 devices "
    "get an explicit ABIs mismatch message instead of failing silently. "
    "(2) Single-instance race fixed: both service.sh and the iptables.sh daemon start AdGuardHome when they cannot find it, "
    "so a boot could end up with two instances fighting for the port; both now share the .agh.start.lock mkdir lock "
    "(verified: concurrent start still leaves exactly one instance). "
    "(3) Startup reliability: AGH restarts after clearing data/sessions.db* when it died on a session-storage timeout; "
    "SmartDNS counts as started only when 127.0.0.1:6053 is really listening (a live process that is not listening gets "
    "restarted); the filter self-heal now polls the AGH API until it is ready (a first boot used to get 404 while routes "
    "were still being registered) and retries a failed refresh. "
    "(4) IPv6: with v6_dns=auto, keep is used when the kernel has no ip6tables nat table - dropping v6 DNS makes netd "
    "fail to fall back to v4 and breaks resolution machine-wide - and REDIRECT is used when the nat table does exist; "
    "drop stays available for people who verified they have working v4 resolvers. "
    "(5) The DNS hijack no longer exempts uid 0 wholesale (netd/dnsproxyd runs as uid 0, so that exemption meant the "
    "system resolver bypassed AGH); only dnsenc's bootstrap lookups to 180.184.1.1:53 are exempted. "
    "Also included: vpn_compat auto/proxy/off, a bundled ABP blocklist (168,574 domains, works offline), "
    "encrypted upstreams (DoH/DoH3/DoT/DoQ/DNSCrypt), per-domain routing, restorable uninstall snapshot "
    "(AGH 40251 / smartdns 6080 / upstream manager 6081)"
)

P = os.path.join(MOD, "module.prop")
s = io.open(P, encoding="utf-8").read()
out = []
for line in s.splitlines():
    if line.startswith("version="):
        out.append("version=" + VER)
    elif line.startswith("versionCode="):
        out.append("versionCode=" + VER)
    elif line.startswith("description="):
        out.append("description=" + DESC_ZH)
    else:
        out.append(line)
s2 = "\n".join(out).rstrip("\n") + "\n"
io.open(P, "w", encoding="utf-8", newline="\n").write(s2)
print("module.prop:", len(s2.encode()), hashlib.md5(s2.encode()).hexdigest())

M = os.path.join(MOD, "scripts", "ModuleMOD.sh")
m = io.open(M, encoding="utf-8").read()
m2 = re.sub(r'^DESC_ZH=".*?"$', lambda _: 'DESC_ZH="' + DESC_ZH.replace('"', '\\"') + '"', m, count=1, flags=re.M)
m2 = re.sub(r'^DESC_EN=".*?"$', lambda _: 'DESC_EN="' + DESC_EN.replace('"', '\\"') + '"', m2, count=1, flags=re.M)
assert m2 != m, "DESC lines not matched"
io.open(M, "w", encoding="utf-8", newline="\n").write(m2)
print("ModuleMOD.sh:", len(m2.encode()), hashlib.md5(m2.encode()).hexdigest())

src = r"F:\BUG\build-out\AdGuardHome-arm64-20261119"
dst = os.path.join(MOD, "bin", "AdGuardHome")
shutil.copyfile(src, dst)
print("bin/AdGuardHome:", os.path.getsize(dst), hashlib.md5(open(dst, "rb").read()).hexdigest())

for p in (P, M):
    txt = io.open(p, encoding="utf-8").read()
    bad = [l[:60] for l in txt.splitlines() if "20261117" in l or "v31" in l]
    print(os.path.basename(p), "残留旧版本行:", bad[:3] if bad else "无")