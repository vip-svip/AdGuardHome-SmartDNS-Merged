# -*- coding: utf-8 -*-
"""修正 port_listening 的 /proc 兜底：
- 原来只认 127.0.0.1（0100007F），漏掉绑 0.0.0.0 / [::] 的服务
  （实测 httpd 6080 绑 00000000:17C0、AGH 40251 绑 tcp6 全零 → 都判成"没听"）。
- tcp 还要判 state=0A(LISTEN)，udp 判 07，避免把已建立连接算进来。
"""
import io, re, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

NEW_FN = r'''# PORT [udp|tcp] → 0 表示本机有人在听这个端口（含绑 0.0.0.0 / [::] 的服务）
port_listening() {
    _port="$1"; _proto="${2:-udp}"
    if command -v netstat >/dev/null 2>&1; then
        case "$_proto" in
            udp) netstat -lun 2>/dev/null | grep -qE "(^|[^0-9.])($_port) " && return 0 ;;
            *)   netstat -ltn 2>/dev/null | grep -qE "(^|[^0-9.])($_port) " && return 0 ;;
        esac
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        case "$_proto" in
            udp) ss -lun 2>/dev/null | grep -q "[:.]$_port " && return 0 ;;
            *)   ss -ltn 2>/dev/null | grep -q "[:.]$_port " && return 0 ;;
        esac
        return 1
    fi
    # 最后兜底：直接读 /proc/net（端口是十六进制；绑 0.0.0.0 或 [::] 也算在听）
    _hex=$(printf '%04X' "$_port")
    case "$_proto" in
        udp) _fl="/proc/net/udp /proc/net/udp6" ;;
        *)   _fl="/proc/net/tcp /proc/net/tcp6" ;;
    esac
    for _f1 in $_fl; do
        [ -r "$_f1" ] || continue
        awk -v h=":$_hex" -v want="$_proto" '
            NR > 1 {
                split($2, a, ":")
                if (":" a[2] != h) next
                # 本地地址：127.0.0.1 / 0.0.0.0 / :: 都算可达
                ip = toupper(a[1])
                if (ip != "0100007F" && ip !~ /^0+$/ && ip !~ /0{16}FFFF0100007F$/) next
                if (want == "udp") { if ($4 == "07") found = 1 }
                else               { if ($4 == "0A") found = 1 }
            }
            END { exit(found ? 0 : 1) }' "$_f1" && return 0
    done
    return 1
}'''

for f in (r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\iptables.sh",
          r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh",
          r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\sd-restart.sh"):
    s = io.open(f, encoding="utf-8").read()
    i = s.find("port_listening() {")
    if i < 0:
        print("!! no fn:", f)
        continue
    # 找到函数结束：从 i 开始，找第一个 "\n}\n"
    j = s.find("\n}\n", i)
    assert j > i
    end = j + len("\n}\n")
    # 保留前置注释（可选），直接替换函数体
    old = s[i:end]
    s = s[:i] + NEW_FN + "\n" + s[end:]
    io.open(f, "w", encoding="utf-8", newline="\n").write(s)
    print("%-22s old=%dB new=%dB md5=%s" % (
        f.split("Adguardhome")[-1], len(old.encode()), len(NEW_FN.encode()),
        hashlib.md5(s.encode()).hexdigest()[:12]))
    print("   leftovers netstat-l:", len(re.findall(r"netstat -l", s)))