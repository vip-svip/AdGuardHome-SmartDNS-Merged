# 从全部 wwwroot html 里移除旧的全局注入（bottom bar / panel / fab），
# 只在 upstream-servers.html 注入「工具栏按钮」脚本。
import io, os, sys, re
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

ROOT = r"F:\BUG\AdguardHome-Magisk\Adguardhome\smartdns\usr\share\smartdns\wwwroot"
SNIP = io.open(r"F:\BUG\_toolbar_snippet.html", "r", encoding="utf-8").read().strip()

MARKERS = [
    '<script id="agh-up-inline-script">',
    '<script id="agh-upstream-btn-script">',
    '<script id="agh-upstream-button">',
    '<script id="agh-up-toolbar-script">',
]

def strip_injections(text):
    """删掉所有已知注入 script 块（含到 </script>），返回干净 HTML"""
    changed = False
    for mk in MARKERS:
        while True:
            i = text.find(mk)
            if i < 0:
                break
            j = text.find("</script>", i)
            if j < 0:
                break
            text = text[:i] + text[j + len("</script>"):]
            changed = True
    return text, changed

targets = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    for fn in filenames:
        if fn.endswith(".html"):
            targets.append(os.path.join(dirpath, fn))
targets.sort()

for p in targets:
    rel = os.path.relpath(p, ROOT)
    s = io.open(p, "r", encoding="utf-8", errors="replace").read()
    s2, changed = strip_injections(s)
    if rel.replace("\\", "/") == "dashboard/upstream-servers.html":
        # 只在这个页面注入工具栏按钮
        if "</body>" in s2:
            s2 = s2.replace("</body>", SNIP + "\n</body>", 1)
        elif "</html>" in s2:
            s2 = s2.replace("</html>", SNIP + "\n</html>", 1)
        else:
            s2 += SNIP
        print("%-34s inject toolbar  %d -> %d" % (rel, len(s), len(s2)))
    else:
        print("%-34s clean          %d -> %d  (changed=%s)" % (rel, len(s), len(s2), changed))
    io.open(p, "w", encoding="utf-8", newline="\n").write(s2)

# 校验
ups = os.path.join(ROOT, "dashboard", "upstream-servers.html")
c = io.open(ups, "r", encoding="utf-8").read()
print("\nupstream-servers: toolbar=%d inline=%d fab=%d" % (
    c.count("agh-up-toolbar-script"), c.count("agh-up-inline-script"), c.count("agh-upstream-fab")))
d = io.open(os.path.join(ROOT, "dashboard.html"), "r", encoding="utf-8").read()
print("dashboard.html:  toolbar=%d inline=%d fab=%d" % (
    d.count("agh-up-toolbar-script"), d.count("agh-up-inline-script"), d.count("agh-upstream-fab")))