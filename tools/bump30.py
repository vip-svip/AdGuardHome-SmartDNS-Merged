import io, sys, re, hashlib, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

MP = r"F:\BUG\AdguardHome-Magisk\Adguardhome\module.prop"
MM = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\ModuleMOD.sh"
VER, VC = "20261116-v30", "2026111630"

DESC_ZH = ("[v30] AdGuard Home 20261116-v30（上游入口只留在 SmartDNS「上游服务器」页刷新按钮右边，"
           "AGH 侧栏里那个入口已移除；上游管理页新增「返回」按钮；加密上游预设换成实测最快的一批 —— "
           "阿里 DoH(IP) 105ms / DoH(IP2) 107ms / DoT(IP2) 108ms / DoT(IP) 110ms / 阿里 DoQ 115ms / "
           "阿里 DoH(域名) 134ms / DoT(域名) 138ms / 360 DoH 138ms / DNSPod DoH 178ms / DNSPod DoT 183ms / "
           "腾讯 DoT 244ms / 腾讯 DoH 250ms；已剔除 dns.google、Cloudflare、AdGuard、dns.qq.com 等全部超时项）"
           " + SmartDNS 48.5-RC1 + data-dir 持久化修「请求处理已暂停」 + 卸载数据快照可恢复"
           "（AGH 40251 · smartdns 6080 · 上游管理 6081）")

DESC_EN = ("[v30] AdGuard Home 20261116-v30 (the upstream entry now lives only in the SmartDNS "
           "upstream-servers page, right next to Refresh; the AdGuard Home sidebar entry is gone; the "
           "upstream manager got a Back button; encrypted-upstream presets replaced with the fastest "
           "measured set -- AliDNS DoH(IP) 105ms / DoH(IP2) 107ms / DoT(IP2) 108ms / DoT(IP) 110ms / "
           "AliDNS DoQ 115ms / AliDNS DoH 134ms / AliDNS DoT 138ms / 360 DoH 138ms / DNSPod DoH 178ms / "
           "DNSPod DoT 183ms / Tencent DoT 244ms / Tencent DoH 250ms; all timing-out entries such as "
           "dns.google, Cloudflare, AdGuard and dns.qq.com removed) "
           "+ SmartDNS 48.5-RC1 + persistent data-dir fixing the 'processing suspended' state + "
           "restorable uninstall snapshot (AGH 40251 · smartdns 6080 · upstream mgr 6081)")

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
print("ModuleMOD.sh", len(raw), hashlib.md5(raw).hexdigest(), "| v30:", "v30" in raw.decode("utf-8"), "| v29 residue:", "v29" in raw.decode("utf-8"))

# 打包脚本 v30
src = io.open(r"F:\BUG\mkv29.py", encoding="utf-8").read()
out = src.replace("v29.zip", "v30.zip")
assert "v30.zip" in out and "v29.zip" not in out
io.open(r"F:\BUG\mkv30.py", "w", encoding="utf-8", newline="\n").write(out)
print("mkv30.py written")