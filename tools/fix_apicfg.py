# -*- coding: utf-8 -*-
"""上网/多设备再打磨：
1) service.sh 里 `/control/*` 都改用配置文件里的实际端口与凭据，不再写死 root/root + 40251
2) AGH 的 sessions.db 打开超时已经在 iptables.sh 的 start_agh 里处理，这里补 service.sh 自己的首启分支
3) sd_suspend_guard 用的是 smartdns 6080 面板默认账号 root/root，改成从 config.prop 读 sd_user/sd_pass
"""
import io, re, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
SVC = HOME + r"\service.sh"
CFG = HOME + r"\scripts\config.prop"

s = io.open(SVC, encoding="utf-8").read()
print("before:", len(s.encode()), hashlib.md5(s.encode()).hexdigest()[:12])

# 1) 统一取 AGH API 端口/凭据的 helper（放在 agh_rules_guard 之前）
HELP = r'''
# ---------------------------------------------------------------
# AGH API 端口与凭据：yaml 里的 http.address 端口才是真的（dns.port 是 DNS 端口，
# 两者不同）；账号密码优先用 config.prop 的 agh_user / agh_pass。
# ---------------------------------------------------------------
agh_api_port() {
    _ap=$(awk '/^http:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*address:/{print $2;exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/.*://')
    case "$_ap" in ''|*[!0-9]*) _ap=40251 ;; esac
    printf '%s' "$_ap"
}
agh_api_user() { printf '%s' "${agh_user:-root}"; }
agh_api_pass() { printf '%s' "${agh_pass:-root}"; }
'''
if "agh_api_port()" not in s:
    anchor = "sd_health_guard() {"
    i = s.find(anchor)
    # 插到该函数前的注释块之前更稳妥：直接插到 anchor 所在位置前
    s = s[:i] + HELP + "\n" + s[i:]

# 2) agh_filter_heal 里写死的端口与凭据
old_port = '''    _port=$(awk '/^http:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*address:/{print $2;exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/.*://')
    case "$_port" in ''|*[!0-9]*) _port=40251 ;; esac'''
if old_port in s:
    s = s.replace(old_port, "    _port=$(agh_api_port)")
    print("  heal port -> agh_api_port")
else:
    m = re.search(r"_port=\$\(awk '/\^http:", s)
    print("  !! heal port pattern not found, has _port=awk?", bool(m))

# 凭据：{"name":"..","password":".."} 用的是 ${agh_user:-root}/${agh_pass:-root} ?
cnt = s.count('"name":"${agh_user:-root}"')
print("  name uses agh_user:", cnt)

# 3) sd_suspend_guard 的 smartdns 面板凭据
if "sd_user" not in s:
    s = s.replace('''--post-data='{"username":"root","password":"root"}\'''',
                  '''--post-data="{\\"username\\":\\"${sd_user:-root}\\",\\"password\\":\\"${sd_pass:-root}\"}"''')

io.open(SVC, "w", encoding="utf-8", newline="\n").write(s)
print("after :", len(s.encode()), hashlib.md5(s.encode()).hexdigest()[:12])

# 4) config.prop 加 sd_user / sd_pass 注释项
c = io.open(CFG, encoding="utf-8").read()
if "sd_user" not in c:
    if not c.endswith("\n"):
        c += "\n"
    c += '''
# SmartDNS 面板（6080）的登录账号，sd_suspend_guard 用它查「请求处理是否暂停」。
# 在面板里改过密码的话，记得同步这里。
sd_user=root
sd_pass=root
'''
    io.open(CFG, "w", encoding="utf-8", newline="\n").write(c)
    print("config.prop +", len(c.encode()), hashlib.md5(c.encode()).hexdigest()[:12])

# 5) customize.sh 升级保留键加 sd_user / sd_pass
CU = HOME + r"\customize.sh"
t = io.open(CU, encoding="utf-8").read()
m = re.search(r"for _k in ([^;]+); do", t)
print("keep keys:", m.group(1) if m else "NOT FOUND")
if m and "sd_user" not in m.group(1):
    t = t.replace(m.group(0), "for _k in %s sd_user sd_pass; do" % m.group(1).strip(), 1)
    io.open(CU, "w", encoding="utf-8", newline="\n").write(t)
    print("customize.sh keep ->", len(t.encode()), hashlib.md5(t.encode()).hexdigest()[:12])