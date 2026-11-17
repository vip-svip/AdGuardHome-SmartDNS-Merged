import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\upstream-manage.html"
s = io.open(P, encoding="utf-8").read()
before = len(s.encode("utf-8"))

# ---------- 1. 顶部加「返回」按钮 ----------
old_head = '''  <h1>上游服务器管理</h1>
  <div class="sub" id="path">文件：/data/adb/agh/smartdns/etc/smartdns/servers.conf</div>
'''
new_head = '''  <div class="topbar">
    <button id="btnBack" class="back" title="返回 SmartDNS 上游服务器页面">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
           stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M15 18l-6-6 6-6"/>
      </svg>
      <span>返回</span>
    </button>
    <h1>上游服务器管理</h1>
  </div>
  <div class="sub" id="path">文件：/data/adb/agh/smartdns/etc/smartdns/servers.conf</div>
'''
assert s.count(old_head) == 1
s = s.replace(old_head, new_head, 1)

# ---------- 2. 样式 ----------
old_css = '''  .wrap{max-width:780px;margin:0 auto}
  h1{font-size:18px;margin:0 0 2px}'''
new_css = '''  .wrap{max-width:780px;margin:0 auto}
  .topbar{display:flex;align-items:center;gap:10px;margin:0 0 2px}
  h1{font-size:18px;margin:0}
  button.back{display:inline-flex;align-items:center;gap:4px;padding:6px 12px 6px 8px;
       border-radius:20px;font-size:13.5px;font-weight:600;flex:0 0 auto;
       background:var(--chip);border:1px solid var(--line);color:var(--fg);
       -webkit-tap-highlight-color:transparent}
  button.back:active{transform:scale(.96)}
  button.back svg{display:block}'''
assert s.count(old_css) == 1
s = s.replace(old_css, new_css, 1)

# ---------- 3. 返回逻辑（多级回退，保证一定可用） ----------
old_js = '''(function () {
  var API = 'http://127.0.0.1:6081/cgi-bin/upstream';
  var $ = function (id) { return document.getElementById(id); };'''
new_js = '''(function () {
  var API = 'http://127.0.0.1:6081/cgi-bin/upstream';
  var $ = function (id) { return document.getElementById(id); };

  // 返回：优先 history.back（从 SmartDNS 上游服务器页点进来时最自然），
  // 没有历史（直接打开本页 / 新标签页）就跳回 SmartDNS 上游服务器页面。
  var SD_UPSTREAM = 'http://127.0.0.1:6080/dashboard/upstream-servers.html';
  function goBack() {
    var canBack = false;
    try {
      canBack = (window.history.length > 1) && document.referrer !== '';
    } catch (e) { canBack = false; }
    if (canBack) {
      window.history.back();
      // history.back 在少数浏览器/WebView 里不会真的走，兜底延时跳转
      setTimeout(function () {
        if (document.visibilityState === 'visible' && !window.__aghBacked) {
          location.href = SD_UPSTREAM;
        }
      }, 350);
      window.__aghBacked = 1;
      return;
    }
    location.href = SD_UPSTREAM;
  }'''
assert s.count(old_js) == 1
s = s.replace(old_js, new_js, 1)

# ---------- 4. 绑定返回按钮（挂在 init 里，找 load(); encLoad();） ----------
old_init = '''  load();
  encLoad();
})();'''
new_init = '''  if ($('btnBack')) $('btnBack').onclick = goBack;
  load();
  encLoad();
})();'''
if s.count(old_init) != 1:
    # 兜底：找任意 load(); 后面
    import re
    m = re.search(r'\n(\s*)load\(\);\s*\n(\s*)encLoad\(\);', s)
    print("init 命中 fallback:", bool(m))
    s = re.sub(r'\n(\s*)load\(\);\s*\n(\s*)encLoad\(\);',
               lambda mm: "\n%sif ($('btnBack')) $('btnBack').onclick = goBack;\n%sload();\n%sencLoad();" % (mm.group(1), mm.group(1), mm.group(2)),
               s, count=1)
else:
    s = s.replace(old_init, new_init, 1)

# ---------- 5. 加密上游预设换成实测最快的那批 ----------
old_presets = '''  var ENC_PRESETS = [
    ['doh https://dns.alidns.com/dns-query', '\\u963F\\u91CC DoH'],
    ['dot dns.alidns.com', '\\u963F\\u91CC DoT'],
    ['doh https://doh.pub/dns-query', '\\u817E\\u8BAF DoH'],
    ['dot dot.pub', '\\u817E\\u8BAF DoT'],
    ['doh https://dns.google/dns-query', 'Google DoH'],
    ['doh https://cloudflare-dns.com/dns-query', 'Cloudflare DoH'],
    ['doq dns.adguard-dns.com', 'AdGuard DoQ'],
    ['h3 dns.google/dns-query', 'Google DoH3']
  ];'''
new_presets = '''  // 实测（本机 18e1870，每项 3 轮取平均；毫秒越小越好）：
  //   DoH 223.5.5.5    105ms   DoT 223.6.6.6    108ms   DoT 223.5.5.5    110ms
  //   DoQ dns.alidns    115ms   DoH 223.6.6.6    107ms   DoH alidns/query 134ms
  //   DoH doh.360.cn    138ms   DoH 1.12.12.12   178ms   DoT 120.53.53.53 183ms
  //   DoT dot.pub       244ms   DoH doh.pub       250ms
  // 不可用（超时/被 reset，不要加）：dns.google 6s、cloudflare 2.5-8s、
  //   dns.adguard-dns.com 5-18s、dot dns.qq.com 6s、dot dns.360.cn 8s、
  //   doq dot.pub / doq dns.360.cn / dot 1.1.1.1 全部超时。
  var ENC_PRESETS = [
    ['doh https://223.5.5.5/dns-query', '\\u963F\\u91CC DoH(IP) 105ms'],
    ['doh https://223.6.6.6/dns-query', '\\u963F\\u91CC DoH(IP2) 107ms'],
    ['dot 223.5.5.5', '\\u963F\\u91CC DoT(IP) 110ms'],
    ['dot 223.6.6.6', '\\u963F\\u91CC DoT(IP2) 108ms'],
    ['doq dns.alidns.com', '\\u963F\\u91CC DoQ 115ms'],
    ['doh https://dns.alidns.com/dns-query', '\\u963F\\u91CC DoH(域名) 134ms'],
    ['dot dns.alidns.com', '\\u963F\\u91CC DoT(域名) 138ms'],
    ['doh https://doh.360.cn/dns-query', '360 DoH 138ms'],
    ['doh https://1.12.12.12/dns-query', 'DNSPod DoH(IP) 178ms'],
    ['dot 120.53.53.53', 'DNSPod DoT(IP) 183ms'],
    ['doh https://doh.pub/dns-query', '\\u817E\\u8BAF DoH 250ms'],
    ['dot dot.pub', '\\u817E\\u8BAF DoT 244ms']
  ];'''
assert s.count(old_presets) == 1, ("presets count", s.count(old_presets))
s = s.replace(old_presets, new_presets, 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(P, "rb").read()
print("upstream-manage.html", before, "->", len(raw), "md5", hashlib.md5(raw).hexdigest())
print("btnBack:", s.count("btnBack"), "| goBack:", s.count("goBack"), "| presets:", s.count("ENC_PRESETS"))