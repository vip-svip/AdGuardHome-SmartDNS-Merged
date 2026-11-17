import io, sys, hashlib, shutil, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

VER = "20261117"
CODE = "20261117"
MOD = r"F:\BUG\AdguardHome-Magisk\Adguardhome"

DESC_ZH = (
    "[" + VER + "] AdGuard Home " + VER + " + SmartDNS 48.5-RC1。"
    "本次三件事：① 去掉导入规则的大小限制——AGH 原来把请求体卡在 64KiB（导入用户规则是 4MiB），"
    "现在完全不限，几十万条的规则表、大 client 列表都能直接导入/粘贴；查看规则文件的上限也从 4MiB 提到 64MiB。"
    "② 补上 IPv6 的 DNS 劫持：原来 ip6tables 没有 nat 表（Table does not exist）、TPROXY 在 OUTPUT 也不可用，"
    "运营商的 v6 DNS（2408:8888::8 之类）直接绕过过滤。现在 config.prop 新增 v6_dns=auto/redirect/drop/keep："
    "auto 默认先尝试 modprobe ip6table_nat 用 nat REDIRECT，内核没有 nat 表就自动退到 mangle 丢弃 v6:53，"
    "系统解析器会回落到已被劫持的 v4 DNS（实测多花不到 1ms），规则放在自己的 AGH_V6DNS 链里、proxy 模式下同样豁免隧道出流量与 VPN 应用 uid，"
    "vpn_compat=auto 让路时 v6 一并撤掉。③ 版本号改成纯日期，不再带 v31 这种序号。"
    "另有：VPN 共存三模式（auto 让路 / proxy 串联 / off）、加密上游 DoH·DoH3·DoT·DoQ·DNSCrypt、"
    "按域名分流、过滤器自愈、卸载快照可恢复（AGH 40251 · smartdns 6080 · 上游管理 6081）"
)

DESC_EN = (
    "[" + VER + "] AdGuard Home " + VER + " + SmartDNS 48.5-RC1. Three things this round: "
    "(1) rule import is no longer size-limited -- AGH used to cap request bodies at 64 KiB (4 MiB for user-rule imports), "
    "which is now removed entirely, so multi-hundred-thousand-line lists and large client lists import/paste fine; "
    "the rule-file viewer cap also went from 4 MiB to 64 MiB. "
    "(2) IPv6 DNS hijacking is now covered: this kernel has no ip6tables nat table (Table does not exist) and TPROXY is unusable in OUTPUT, "
    "so carrier IPv6 resolvers (2408:8888::8 and friends) bypassed filtering. config.prop gained v6_dns=auto/redirect/drop/keep: "
    "auto tries modprobe ip6table_nat and uses a nat REDIRECT, and falls back to dropping v6:53 from our own AGH_V6DNS chain in mangle "
    "when the kernel has no nat table -- the system resolver then falls back to the already-hijacked v4 path (measured under 1 ms extra). "
    "The drop rules exempt tunnel egress and VPN app uids in proxy mode, and are removed entirely when vpn_compat=auto yields. "
    "(3) The version string is now a plain date instead of a v31-style counter. "
    "Also included: vpn_compat auto/proxy/off, encrypted upstreams (DoH/DoH3/DoT/DoQ/DNSCrypt), per-domain routing, "
    "filter self-heal, restorable uninstall snapshot (AGH 40251 / smartdns 6080 / upstream mgr 6081)"
)

# ---------- module.prop ----------
P = os.path.join(MOD, "module.prop")
s = io.open(P, encoding="utf-8").read()
out = []
for line in s.splitlines():
    if line.startswith("version="):
        out.append("version=" + VER)
    elif line.startswith("versionCode="):
        out.append("versionCode=" + CODE)
    elif line.startswith("description="):
        out.append("description=" + DESC_ZH)
    else:
        out.append(line)
s2 = "\n".join(out).rstrip("\n") + "\n"
io.open(P, "w", encoding="utf-8", newline="\n").write(s2)
print("module.prop:", len(s2.encode()), hashlib.md5(s2.encode()).hexdigest())

# ---------- ModuleMOD.sh ----------
M = os.path.join(MOD, "scripts", "ModuleMOD.sh")
m = io.open(M, encoding="utf-8").read()
import re
m2 = re.sub(r'^DESC_ZH=".*?"$', 'DESC_ZH="' + DESC_ZH.replace('"', '\\"') + '"', m, count=1, flags=re.M)
m2 = re.sub(r'^DESC_EN=".*?"$', 'DESC_EN="' + DESC_EN.replace('"', '\\"') + '"', m2, count=1, flags=re.M)
if m2 == m:
    print("!! ModuleMOD.sh 没匹配到 DESC 行，检查：")
    for line in m.splitlines():
        if line.startswith("DESC_"):
            print("   ", line[:80])
else:
    io.open(M, "w", encoding="utf-8", newline="\n").write(m2)
    print("ModuleMOD.sh:", len(m2.encode()), hashlib.md5(m2.encode()).hexdigest())

# ---------- bin/AdGuardHome ----------
src = r"F:\BUG\build-out\AdGuardHome-arm64-20261117"
dst = os.path.join(MOD, "bin", "AdGuardHome")
shutil.copyfile(src, dst)
print("bin/AdGuardHome:", os.path.getsize(dst), hashlib.md5(open(dst, "rb").read()).hexdigest())

# ---------- 校验：还有没有 v31 残留 ----------
for p in (P, M):
    txt = io.open(p, encoding="utf-8").read()
    bad = [l for l in txt.splitlines() if "v31" in l or "20261116-v" in l]
    print(p.split("\\")[-1], "残留行:", bad[:3] if bad else "无")