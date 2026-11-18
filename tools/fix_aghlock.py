# -*- coding: utf-8 -*-
"""修「两处同时拉起 AGH → 双实例」的竞态：
service.sh 与 iptables.sh 守护都会在检测不到 AGH 时启动它，起始阶段 pgrep 可能都判「没在跑」。
用 mkdir 锁 + 二次确认，保证全局只有一个启动者。
"""
import io, re, sys, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
HOME = r"F:\BUG\AdguardHome-Magisk\Adguardhome"

LOCK = '''    # -----------------------------------------------------------
    # 启动锁：service.sh 与 iptables.sh 守护都会「检测不到就拉起」，
    # 开机瞬间两边可能同时判「没在跑」→ 起两个实例、抢同一个端口。
    # 用 mkdir 原子锁串行化，并二次确认。
    # -----------------------------------------------------------
    _lk="$AGH_DIR/.agh.start.lock"
    if ! mkdir "$_lk" 2>/dev/null; then
        _i=0
        while [ "$_i" -lt 24 ]; do
            agh_running && { rm -rf "$_lk" 2>/dev/null; return 0; }
            sleep 0.5
            _i=$((_i + 1))
        done
        rm -rf "$_lk" 2>/dev/null
    fi
    if agh_running; then
        rm -rf "$_lk" 2>/dev/null
        return 0
    fi
'''

for f in (HOME + r"\scripts\iptables.sh", HOME + r"\service.sh"):
    s = io.open(f, encoding="utf-8").read()
    if ".agh.start.lock" in s:
        print("skip:", f.split("Adguardhome")[-1])
        continue
    m = re.search(r"\nstart_agh\(\) \{\n", s)
    assert m, f
    s = s[:m.end()] + LOCK + s[m.end():]
    # 启动完成后释放锁
    s = s.replace('''    "$BIN_DIR/AdGuardHome" --no-check-update >/dev/null 2>&1 &''',
                  '''    "$BIN_DIR/AdGuardHome" --no-check-update >/dev/null 2>&1 &
    sleep 0.3
    rm -rf "$_lk" 2>/dev/null''', 1)
    io.open(f, "w", encoding="utf-8", newline="\n").write(s)
    print("%-22s %dB md5=%s" % (f.split("Adguardhome")[-1], len(s.encode()),
                                hashlib.md5(s.encode()).hexdigest()[:12]))

for f in (HOME + r"\scripts\iptables.sh", HOME + r"\service.sh"):
    s = io.open(f, encoding="utf-8").read()
    print(f.split("Adguardhome")[-1], "lock=", ".agh.start.lock" in s, "release=", s.count('rm -rf "$_lk"'))
    i = s.find("start_agh() {")
    print("\n".join(s[i:i + 1200].split("\n")[:26]))
    print("----")