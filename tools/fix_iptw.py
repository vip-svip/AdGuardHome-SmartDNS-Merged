# -*- coding: utf-8 -*-
"""把 iptables.sh 与 CGI 里的硬编码 -w 2 换成 $IPT_W（探测过是否支持），
并在 CGI 里也插入同样的探测。"""
import io, re, hashlib, sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

FILES = [
    r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\iptables.sh",
    r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\cgi-bin\upstream",
    r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh",
    r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\sd-restart.sh",
    r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\ProxyConfig.sh",
]

DETECT = """# ---------------------------------------------------------------
# 设备兼容：iptables 的 -w（xtables 锁）参数
# legacy 1.8.x 支持 -w，老的 1.4.x 不支持，nft 后端行为也不一样。带不被支持的
# 参数会直接报错、整条链建不起来，所以探测一次，不支持就去掉。
# ---------------------------------------------------------------
IPT_W="-w 2"
iptables $IPT_W -t nat -S OUTPUT >/dev/null 2>&1 || IPT_W=""
ip6tables $IPT_W -t mangle -S OUTPUT >/dev/null 2>&1 || IPT_W=""
"""

total = 0
for f in FILES:
    s = io.open(f, encoding="utf-8").read()
    before = s
    if re.search(r"ip6?tables -w 2", s):
        # 是否有探测块
        has_detect = "IPT_W=" in s
        out = []
        for line in s.split("\n"):
            st = line.strip()
            if st.startswith("IPT_W=") or st.startswith("iptables $IPT_W") or st.startswith("ip6tables $IPT_W"):
                out.append(line)
                continue
            n = line.replace("iptables -w 2 ", "iptables $IPT_W ").replace("ip6tables -w 2 ", "ip6tables $IPT_W ")
            n = n.replace("iptables -w 2\"", "iptables $IPT_W\"").replace("ip6tables -w 2\"", "ip6tables $IPT_W\"")
            out.append(n)
        s = "\n".join(out)
        if not has_detect:
            # 插到「第一个使用 iptables 的文件顶部变量区」之后：用 AGH_DIR/ BIN_DIR/ 定位
            m = re.search(r"^(BIN_DIR=.*\n)", s, re.M)
            if m:
                s = s[:m.end()] + "\n" + DETECT + s[m.end():]
            else:
                m2 = re.search(r"^(#!.*\n)", s)
                s = (s[:m2.end()] if m2 else "") + DETECT + (s[m2.end():] if m2 else s)
    if s != before:
        io.open(f, "w", encoding="utf-8", newline="\n").write(s)
        cnt = len(re.findall(r"ip6?tables \$IPT_W", s))
        print("%-40s changed, uses=%d, size=%d, md5=%s" % (
            f.split("Adguardhome")[-1] or f, cnt, len(s.encode()),
            hashlib.md5(s.encode()).hexdigest()))
        total += 1
    else:
        print("%-40s unchanged" % (f.split("Adguardhome")[-1] or f))

print("files changed:", total)

# 校验：剩余硬编码
for f in FILES:
    s = io.open(f, encoding="utf-8").read()
    left = len(re.findall(r"ip6?tables -w 2", s))
    if left:
        print("!! 仍有硬编码 %d 处: %s" % (left, f))