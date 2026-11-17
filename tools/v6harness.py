import io, os, sys, subprocess
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

ADB = ["adb", "-s", "emulator-5554"]
BASE = r"F:\BUG\_v6harness"
os.makedirs(BASE, exist_ok=True)

# ---- 被测脚本副本：把 AGH_DIR 指到沙盒 ----
src = io.open(r"F:\BUG\_ipt_new.sh", encoding="utf-8").read()
src = src.replace('AGH_DIR="/data/adb/agh"', 'AGH_DIR="/data/local/tmp/v6box/agh"')
io.open(os.path.join(BASE, "ipt.sh"), "w", encoding="utf-8", newline="\n").write(src)

# ---- 桩：ip6tables（模拟 nat 缺失 / mangle 可用，带状态）----
stub6 = r'''#!/system/bin/sh
# 记录调用
echo "ip6tables $*" >> /data/local/tmp/v6box/calls.log
S=/data/local/tmp/v6box/state
NAT=${FAKE_NAT:-0}          # 1 = nat 表可用
tbl=; chain=; jump=0; op=
while [ $# -gt 0 ]; do
    case "$1" in
        -t) tbl="$2"; shift 2 ;;
        -w) shift; [ "$1" = "2" ] && shift ;;
        -N) op=new; chain="$2"; shift 2 ;;
        -X) op=del; chain="$2"; shift 2 ;;
        -F) op=flush; chain="$2"; shift 2 ;;
        -C) op=check; shift ;;
        -A) op=append; shift ;;
        -D) op=drop; shift ;;
        -L) op=list; shift; [ -n "$1" ] && [ "${1#-}" = "$1" ] && { chain="$1"; shift; } ;;
        *) shift ;;
    esac
done
# 从剩余参数里找链名（-C/-A/-D 后面跟链名）
for a in "$@"; do :; done
case "$op" in
    list) : ;;
esac
# 简易状态：文件 state/<table>.<chain>
d=/data/local/tmp/v6box/$tbl
mkdir -p "$d" 2>/dev/null
case "$op" in
    list)
        [ "$tbl" = nat ] && [ "$NAT" != 1 ] && { echo "ip6tables: Table does not exist" >&2; exit 2; }
        exit 0 ;;
    new) touch "$d/$chain"; exit 0 ;;
    del) rm -f "$d/$chain"; exit 0 ;;
    flush) : > "$d/$chain"; exit 0 ;;
esac
[ "$tbl" = nat ] && [ "$NAT" != 1 ] && { echo "ip6tables: Table does not exist" >&2; exit 2; }
exit 0
'''

# ---- 桩：iptables（v4，一律成功）----
stub4 = r'''#!/system/bin/sh
echo "iptables $*" >> /data/local/tmp/v6box/calls.log
d=/data/local/tmp/v6box/v4nat
mkdir -p "$d" 2>/dev/null
case " $* " in
    *" -N "*) c=$(echo "$*" | sed 's/.* -N //;s/ .*//'); touch "$d/$c" ;;
    *" -X "*) c=$(echo "$*" | sed 's/.* -X //;s/ .*//'); rm -f "$d/$c" ;;
esac
exit 0
'''

# ---- 桩：modprobe ----
stubmod = '#!/system/bin/sh\necho "modprobe $*" >> /data/local/tmp/v6box/calls.log\nexit 0\n'

for name, body in (("ip6tables", stub6), ("iptables", stub4), ("modprobe", stubmod)):
    io.open(os.path.join(BASE, name), "w", encoding="utf-8", newline="\n").write(body)

CFG = """redir_port=40531
PROXY_URL=" "
vpn_compat=auto
vpn_apps=""
v6_dns=__MODE__
agh_user=root
agh_pass=root
"""

def push(local, remote):
    r = subprocess.run(ADB + ["push", local, remote], capture_output=True, timeout=180)
    return (r.stdout or b"").decode("utf-8", "replace").strip()

print(push(os.path.join(BASE, "ipt.sh"), "/data/local/tmp/v6box_ipt.sh"))
print(push(os.path.join(BASE, "ip6tables"), "/data/local/tmp/v6box_ip6tables"))
print(push(os.path.join(BASE, "iptables"), "/data/local/tmp/v6box_iptables"))
print(push(os.path.join(BASE, "modprobe"), "/data/local/tmp/v6box_modprobe"))

def run_case(mode, nat, label):
    cfg = CFG.replace("__MODE__", mode)
    script = r'''#!/system/bin/sh
set -u
B=/data/local/tmp/v6box
rm -rf $B; mkdir -p $B/agh/scripts $B/agh/bin $B/agh/smartdns/etc/smartdns $B/stub
cp /data/local/tmp/v6box_ip6tables $B/stub/ip6tables
cp /data/local/tmp/v6box_iptables  $B/stub/iptables
cp /data/local/tmp/v6box_modprobe  $B/stub/modprobe
chmod 755 $B/stub/*
cp /data/local/tmp/v6box_ipt.sh $B/agh/scripts/iptables.sh
cat > $B/agh/scripts/config.prop <<'EOF'
__CFG__
EOF
printf 'dns:\n  port: 40531\n' > $B/agh/bin/AdGuardHome.yaml
: > $B/agh/agh.log
PATH=$B/stub:/system/bin:/system/xbin
export PATH FAKE_NAT=__NAT__
sh $B/agh/scripts/iptables.sh --once
echo "--- calls ---"
cat $B/calls.log 2>/dev/null | sed 's/^/  /'
echo "--- log ---"
cat $B/agh/agh.log 2>/dev/null | sed 's/^/  /'
'''.replace("__CFG__", cfg).replace("__NAT__", nat)
    p = os.path.join(BASE, "case.sh")
    io.open(p, "w", encoding="utf-8", newline="\n").write(script)
    subprocess.run(ADB + ["push", p, "/data/local/tmp/v6case.sh"], capture_output=True, timeout=180)
    r = subprocess.run(ADB + ["shell", "sh", "/data/local/tmp/v6case.sh"], capture_output=True, timeout=300)
    out = (r.stdout or b"").decode("utf-8", "replace")
    print("\n" + "=" * 70)
    print("CASE:", label, "| v6_dns =", mode, "| FAKE_NAT =", nat)
    print("=" * 70)
    # 只挑 ip6tables 与日志行
    for line in out.splitlines():
        if "ip6tables" in line or "[INFO]" in line or "[WARN]" in line or "---" in line:
            print(line)

run_case("auto", "0", "auto + 内核无 nat 表 → 应走 drop")
run_case("auto", "1", "auto + 有 nat 表 → 应走 redirect")
run_case("keep", "0", "keep → 不装任何 v6 规则")
run_case("redirect", "0", "redirect + 无 nat → 应降级 drop 并记 WARN")