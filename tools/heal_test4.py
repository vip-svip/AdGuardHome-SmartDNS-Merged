# -*- coding: utf-8 -*-
"""两路验证 agh_filter_heal：
A) 正常跑一遍（当前 filters 非 0 → 走 else 分支，只验证登录轮询不报错）
B) 把 refresh URL 换成 404 路径，验证「重试 3 次 + 记录返回体」逻辑生效
"""
import io, re, subprocess, sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
sys.path.insert(0, r"F:\BUG")
import dev

BASE = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
src = io.open(BASE + r"\service.sh", "r", encoding="utf-8").read()
m = re.search(r"^agh_filter_heal\(\) \{.*?^\}\n", src, re.S | re.M)
assert m
body = m.group(0)

HEAD = r'''#!/system/bin/sh
AGH_DIR=/data/adb/agh
BIN_DIR=$AGH_DIR/bin
SCRIPT_DIR=$AGH_DIR/scripts
ADGPATH=/data/adb/modules/AdGuardHome
MODULES_DIR=/data/adb/modules
lang=zh
HAVE_CURL=1
LOG=/data/local/tmp/_heal.log
: > "$LOG"
log() { echo "$*" >> "$LOG"; }
'''

TAIL = '''
agh_filter_heal
echo "--- log ---"
cat "$LOG"
'''

SN = dev.pick()
print("device:", SN)


def run(tag, script_text):
    io.open(r"F:\BUG\_healtest.sh", "w", encoding="utf-8", newline="\n").write(script_text)
    subprocess.run(["adb", "-s", SN, "push", r"F:\BUG\_healtest.sh", "/data/local/tmp/_healtest.sh"],
                   capture_output=True, check=True)
    r = subprocess.run(["adb", "-s", SN, "shell", "su -c 'sh /data/local/tmp/_healtest.sh'"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=500)
    print("=== %s ===" % tag)
    print(r.stdout.strip())
    if r.stderr.strip():
        print("STDERR:", r.stderr[-400:])
    print()


run("A 正常", HEAD + body + TAIL)

# B：把 refresh 的 URL 换成必然 404 的路径，同时强制 _total=0（让代码进 if 分支）
body_b = body.replace("/control/filtering/refresh", "/control/no_such_route")
body_b = body_b.replace(
    '_total=$(printf \'%s\' "$_st" | tr \',\' \'\\n\' | awk -F: \'/rules_count/{gsub(/[^0-9]/,"",$2); s+=$2} END{print s+0}\')',
    '_total=0')
assert "_total=0" in body_b, "force-total patch failed"
run("B 404 重试", HEAD + body_b + TAIL)