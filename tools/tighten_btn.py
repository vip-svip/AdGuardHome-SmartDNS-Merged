import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

# 1) 修 wwwroot 里的注入脚本：把 margin 收紧，按钮紧贴「刷新」
P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\smartdns\usr\share\smartdns\wwwroot\dashboard\upstream-servers.html"
s = io.open(P, encoding="utf-8").read()
before = len(s.encode("utf-8"))
old = "'margin:0 auto 0 8px'"
if s.count(old) == 1:
    s = s.replace(old, "'margin:0 auto 0 0'", 1)
    print("margin 收紧: 0 auto 0 8px -> 0 auto 0 0（父容器 flex gap 8px 已足够）")
else:
    print("margin 未命中, count=", s.count(old))

# 文案简化：＋ 上游 → ＋ 上游服务器（用户能一眼看懂）
old_html = """    b.innerHTML = '<span style="font-size:15px;line-height:1">\\uFF0B</span>'
                + '<span>\\u4E0A\\u6E38</span>';"""
new_html = """    b.innerHTML = '<span style="font-size:15px;line-height:1">\\uFF0B</span>'
                + '<span>\\u4E0A\\u6E38\\u670D\\u52A1\\u5668</span>';"""
if s.count(old_html) == 1:
    s = s.replace(old_html, new_html, 1)
    print("按钮文案: ＋ 上游 -> ＋ 上游服务器")
else:
    print("文案未命中, count=", s.count(old_html))

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(P, "rb").read()
print("upstream-servers.html", before, "->", len(raw), "md5", hashlib.md5(raw).hexdigest())

# 2) 同步生成脚本（make_toolbar2.py）里的模板，保证下次注入一致
T = r"F:\BUG\make_toolbar2.py"
if io.open(T, encoding="utf-8").exists():
    t = io.open(T, encoding="utf-8").read()
    t2 = t.replace("'margin:0 auto 0 8px'", "'margin:0 auto 0 0'")
    t2 = t2.replace("+ '<span>\\\\u4E0A\\\\u6E38</span>'", "+ '<span>\\\\u4E0A\\\\u6E38\\\\u670D\\\\u52A1\\\\u5668</span>'")
    if t2 != t:
        io.open(T, "w", encoding="utf-8", newline="\n").write(t2)
        print("make_toolbar2.py 已同步")
    else:
        print("make_toolbar2.py 无需改动")