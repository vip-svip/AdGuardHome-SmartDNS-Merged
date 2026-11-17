import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

P = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\upstream-manage.html"
s = io.open(P, encoding="utf-8").read()
orig = len(s.encode("utf-8"))

# ---------------------------------------------------------------
# 1. 在「按域名分流」卡片之前插入「VPN 共存」卡片
# ---------------------------------------------------------------
anchor = """  <div class="card">
    <h2>按域名分流（哪些域名走加密上游）</h2>"""

card = """  <div class="card">
    <h2>VPN 共存 <span class="badge" id="vpnBadge">检测中…</span></h2>
    <div class="sub" style="margin-bottom:8px">
      <b>auto</b>（默认）检测到 VPN / 代理的隧道接口就把 DNS 劫持让路，解析完全交给 VPN，断开后 5 秒内自动恢复劫持。<br>
      <b>proxy</b> 仍做 DNS 劫持，但「出接口是隧道」的查询和 VPN 应用自身的查询不劫持 —— 想让 AGH 继续过滤 VPN 流量选这个。<br>
      <b>off</b> 不做任何 VPN 判断，全量劫持（老行为）。<br>
      <span style="color:var(--dim)">改这一项不用重启；脚本 5 秒内自己重建规则。</span>
    </div>
    <div class="row">
      <select id="vpnMode" style="flex:1;min-width:120px;height:40px;border-radius:10px;
              border:1px solid var(--line);background:var(--bg2);color:var(--fg);padding:0 8px">
        <option value="auto">auto · 让路（推荐）</option>
        <option value="proxy">proxy · 串联</option>
        <option value="off">off · 全量劫持</option>
      </select>
      <button class="primary" id="btnVpnApply">应用</button>
      <button id="btnVpnRefresh">刷新状态</button>
    </div>
    <div class="msg" id="vpnMsg"></div>
    <div class="sub" id="vpnState" style="margin-top:6px;color:var(--dim)">读取中…</div>
  </div>

"""

assert anchor in s, "分流卡片锚点没找到"
s = s.replace(anchor, card + anchor, 1)

# ---------------------------------------------------------------
# 2. 加 JS
# ---------------------------------------------------------------
js_anchor = """  function encLoad() {"""

js = """  // ---------------- VPN 共存 ----------------
  function vpnSay(t, kind) {
    var el = $('vpnMsg');
    if (!el) return;
    el.textContent = t || '';
    el.className = 'msg' + (kind ? ' ' + kind : '');
    if (t) { setTimeout(function () { el.textContent = ''; }, 6000); }
  }

  function vpnRender(r) {
    var badge = $('vpnBadge'), st = $('vpnState');
    if (!r || !r.ok) {
      if (badge) { badge.textContent = '未知'; }
      if (st) { st.textContent = (r && r.error) ? r.error : '读取 VPN 状态失败'; }
      return;
    }
    var mode = r.mode || 'auto';
    var sel = $('vpnMode');
    if (sel) { sel.value = mode; }
    var ifs = (r.ifaces || '').trim();
    var active = !!r.vpn_active;
    var hij = r.hijack;
    if (badge) {
      badge.textContent = hij ? '劫持生效' : '已让路';
      badge.className = 'badge' + (hij ? '' : ' warn');
    }
    if (st) {
      var lines = [];
      lines.push('模式 ' + mode + (active ? ' ｜ 检测到隧道接口 ' + ifs : ' ｜ 未检测到隧道接口'));
      lines.push('OUTPUT 跳转 ' + (r.jump ? '在' : '不在') +
                 ' ｜ ADGUARD 链 ' + (r.rules || 0) + ' 条' +
                 ' ｜ REDIRECT ' + (r.redirect ? (r.redirect + ' 条') : '无'));
      if (r.uids) { lines.push('已豁免 VPN 应用 uid：' + r.uids); }
      if (r.note) { lines.push(r.note); }
      st.innerHTML = lines.join('<br>');
    }
  }

  function vpnLoad() {
    return call('action=vpnstatus')
      .then(function (r) { vpnRender(r); return r; })
      .catch(function () { vpnRender(null); });
  }

  function vpnApply() {
    var sel = $('vpnMode');
    if (!sel) return;
    var m = sel.value;
    var btn = $('btnVpnApply');
    btn.disabled = true;
    call('action=vpnmode&mode=' + encodeURIComponent(m))
      .then(function (r) {
        btn.disabled = false;
        if (r && r.ok) {
          vpnSay(r.msg || '已切换', 'ok');
          vpnRender(r);
          setTimeout(vpnLoad, 2500);
        } else {
          vpnSay((r && r.error) || '切换失败', 'err');
        }
      })
      .catch(function (e) { btn.disabled = false; vpnSay('请求失败：' + e.message, 'err'); });
  }

  function encLoad() {"""

assert js_anchor in s, "encLoad 锚点没找到"
s = s.replace(js_anchor, js, 1)

# ---------------------------------------------------------------
# 3. 初始化里加载 VPN 状态 + 绑按钮
# ---------------------------------------------------------------
init_anchor = "  load();\n  encLoad();"
if init_anchor not in s:
    # 找真实的 init 尾部
    idx = s.rfind("})();")
    print("init 锚点没找到，倒数 300 字符:", repr(s[idx-300:idx]))
    raise SystemExit(1)

s = s.replace(init_anchor, "  load();\n  encLoad();\n  vpnLoad();", 1)

# 按钮绑定：放在 encLoad 初始化附近；用独立语句块，避免依赖别处的绑定写法
bind_anchor = "  if ($('btnBack')) { $('btnBack').onclick = goBack; }"
if bind_anchor in s:
    s = s.replace(bind_anchor,
        bind_anchor + "\n  if ($('btnVpnApply')) { $('btnVpnApply').onclick = vpnApply; }\n"
                      "  if ($('btnVpnRefresh')) { $('btnVpnRefresh').onclick = function () { vpnLoad(); }; }", 1)
else:
    print("btnBack 绑定写法不同，改用追加方式")
    s = s.replace("  vpnLoad();", "  vpnLoad();\n  if ($('btnVpnApply')) { $('btnVpnApply').onclick = vpnApply; }\n"
                                  "  if ($('btnVpnRefresh')) { $('btnVpnRefresh').onclick = function () { vpnLoad(); }; }", 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("upstream-manage.html:", orig, "->", len(s.encode("utf-8")), "B")
for k in ("VPN 共存", "vpnMode", "action=vpnstatus", "action=vpnmode", "vpnLoad();"):
    print("  ", k, "x", s.count(k))