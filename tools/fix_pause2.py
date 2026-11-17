import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
p = r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh"
s = io.open(p, encoding="utf-8").read()
old = '''sd_suspend_guard() {
    [ "$lang" = "zh" ] >/dev/null 2>&1
    _bb=""'''
new = '''sd_suspend_guard() {
    _bb=""'''
assert s.count(old) == 1
s = s.replace(old, new, 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(p, "rb").read()
print("service.sh", len(raw), hashlib.md5(raw).hexdigest())