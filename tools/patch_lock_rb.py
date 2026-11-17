import io
p = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\iptables.sh"
s = io.open(p, encoding="utf-8").read()

# 1) 原函数改名 raw
old = "rebuild_rules() {\n"
assert s.count(old) == 1, s.count(old)
s = s.replace(old, "rebuild_rules_raw() {\n")

# 2) 找到 raw 函数结束（ensure_jump 行之后紧跟的 "}\n"）插入加锁包装
i = s.find("rebuild_rules_raw() {")
j = s.find("\n}\n", i)
assert j > 0, "raw function end not found"
wrapper = (
    "\n}\n\n"
    "# ---------------------------------------------------------------\n"
    "# rebuild_rules 加锁包装\n"
    "# 守护循环与 `--once`（管理页切模式）可能同时触发重建；先 -F 再逐条 -A，\n"
    "# 两个进程交错执行会出现「REDIRECT 重复 2 条」的中间态。用 mkdir 原子锁串行化。\n"
    "# ---------------------------------------------------------------\n"
    "IPT_LOCK=\"$AGH_DIR/.ipt.lock\"\n"
    "rebuild_rules() {\n"
    "    _n=0\n"
    "    while ! mkdir \"$IPT_LOCK\" 2>/dev/null; do\n"
    "        _n=$((_n + 1))\n"
    "        # 持锁进程已死（或锁目录残留）：40×0.1s≈4s 后强拆\n"
    "        [ $_n -ge 40 ] && rm -rf \"$IPT_LOCK\"\n"
    "        sleep 0.1\n"
    "    done\n"
    "    rebuild_rules_raw\n"
    "    rmdir \"$IPT_LOCK\" 2>/dev/null\n"
    "    rm -rf \"$IPT_LOCK\" 2>/dev/null\n"
    "}\n"
)
s = s[:j] + wrapper + s[j + 2:]

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("OK bytes=%d lines=%d" % (len(s.encode("utf-8")), s.count("\n") + 1))
print("raw defs:", s.count("rebuild_rules_raw() {"), "wrapper:", s.count("rebuild_rules() {"))