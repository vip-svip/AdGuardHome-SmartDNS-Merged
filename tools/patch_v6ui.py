import io, sys, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

# ================= 1) CGI: 新增 v6mode action =================
CGI = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\cgi-bin\upstream"
s = io.open(CGI, encoding="utf-8").read()

CASE = '''
v6mode)
    hdr
    m=$(trim "$(printf '%s' "${mode:-}" )")
    case "$m" in
        auto|redirect|drop|keep) ;;
        *) fail "mode 只能是 auto / redirect / drop / keep" ;;
    esac
    [ -f "$CFG" ] || fail "找不到配置文件：$CFG"
    if grep -qE '^[[:space:]]*v6_dns=' "$CFG"; then
        sed -i "s|^[[:space:]]*v6_dns=.*|v6_dns=$m|" "$CFG"
    else
        [ -n "$(tail -c 1 "$CFG" 2>/dev/null)" ] && printf '\\n' >> "$CFG"
        printf 'v6_dns=%s\\n' "$m" >> "$CFG"
    fi
    if [ -f "$IPT" ]; then sh "$IPT" --once >/dev/null 2>&1; fi
    _eff=$(v6_effective_mode)
    _on=0
    v6_hijack_on && _on=1
    printf '{"ok":true,"mode":"%s","effective":"%s","v6_hijack":%s,"v6_nat":%s,"msg":"已写入 v6_dns=%s，实际生效 %s"}' \\
        "$(_json "$m")" "$(_json "$_eff")" \\
        "$([ "$_on" -eq 1 ] && echo true || echo false)" \\
        "$(if v6_nat_ok; then echo true; else echo false; fi)" \\
        "$(_json "$m")" "$(_json "$_eff")"
    ;;

'''

anchor = '''*)
    fail "未知 action：$action"
    ;;'''
assert anchor in s
s = s.replace(anchor, CASE.lstrip("\n") + anchor, 1)
io.open(CGI, "w", encoding="utf-8", newline="\n").write(s)
print("CGI:", len(s.encode()), hashlib.md5(s.encode()).hexdigest())

# ================= 2) 管理页: VPN 卡片加 v6 控制与状态 =================
PAGE = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\webui\upstream-manage.html"
h = io.open(PAGE, encoding="utf-8").read()

OLD_ROW = '''    <div class="msg" id="vpnMsg"></div>
    <div class="sub" id="vpnState" style="margin-top:6px;color:var(--dim)">读取中…</div>
  </div>'''
NEW_ROW = '''    <div class="msg" id="vpnMsg"></div>
    <div class="sub" id="vpnState" style="margin-top:6px;color:var(--dim)">读取中…</div>

    <h2 style="margin-top:16px">IPv6 的 DNS <span class="badge" id="v6Badge">读取中…</span></h2>
    <div class="sub" style="margin-bottom:8px">
      本机内核多数没有 <code>ip6table_nat</code>（<code>Table does not exist</code>），
      <code>TPROXY</code> 在 OUTPUT 也不可用，所以运营商的 v6 DNS（例如 <code>2408:8888::8</code>）
      原本能绕过过滤。现在两种做法：<br>
      <b>auto</b>（默认）有 nat 表就用 REDIRECT 劫持，没有就自动退到 drop。<br>
      <b>redirect</b> 只用 ip6tables nat 的 REDIRECT。<br>
      <b>drop</b> 在自己的 <code>AGH_V6DNS</code>（mangle）链里丢弃 v6 的 53 端口查询，
      系统会回落到已被劫持的 v4 解析（实测多花不到 1ms）；纯 v6 网络里会导致解析失败。<br>
      <b>keep</b> 完全不碰 v6。
    </div>
    <div class="row">
      <select id="v6Mode" style="flex:1;min-width:120px;height:40px;border-radius:10px;
              border:1px solid var(--line);background:var(--bg2);color:var(--fg);padding:0 8px">
        <option value="auto">auto · 有 nat 用 redirect，否则 drop</option>
        <option value="redirect">redirect · 仅 ip6tables nat</option>
        <option value="drop">drop · mangle 丢弃 v6:53</option>
        <option value="keep">keep · 不处理 v6</option>
      </select>
      <button class="primary" id="btnV6Apply">应用</button>
    </div>
    <div class="msg" id="v6Msg"></div>
  </div>'''
assert OLD_ROW in h, "管理页 VPN 卡片结构没匹配到"
h = h.replace(OLD_ROW, NEW_ROW, 1)

# --- JS: v6 渲染 / 切换 ---
OLD_JS_RENDER = '''  function vpnRender(r) {'''
NEW_JS_RENDER = '''  function v6Say(s, bad) {
    var el = $('v6Msg');
    if (!el) return;
    el.textContent = s || '';
    el.style.color = bad ? 'var(--warn)' : 'var(--dim)';
  }

  function v6Render(r, mode) {
    var b = $('v6Badge');
    var eff = (r && r.v6_mode) ? r.v6_mode : (mode || 'auto');
    var on = !!(r && r.v6_hijack);
    var nat = !!(r && r.v6_nat);
    if (b) {
      b.className = 'badge ' + (on ? 'ok' : 'warn');
      b.textContent = on ? ('已劫持 · ' + eff + (nat ? ' · nat' : ' · mangle')) : ('未劫持 · ' + eff);
    }
    var sel = $('v6Mode');
    if (sel && mode) sel.value = mode;
  }

  function vpnRender(r) {'''
assert OLD_JS_RENDER in h
h = h.replace(OLD_JS_RENDER, NEW_JS_RENDER, 1)

# vpnRender 末尾补 v6Render(r) 调用：找 vpnRender 里的 vpnState 赋值行
OLD_STATE_SET = "    if ($('vpnState')) $('vpnState').textContent = parts.join(' ｜ ');"
assert OLD_STATE_SET in h, "vpnRender 里的 vpnState 赋值没匹配到"
NEW_STATE_SET = OLD_STATE_SET + "\n    v6Render(r);\n    if ($('v6Mode') && r && r.v6_mode) { /* 非用户操作时不同步 select，避免所答非所问 */ }"
h = h.replace(OLD_STATE_SET, NEW_STATE_SET, 1)

# 绑定按钮：跟在 btnVpnRefresh 绑定之后
OLD_BIND = "  if ($('btnVpnRefresh')) $('btnVpnRefresh').onclick = vpnLoad;"
assert OLD_BIND in h, "btnVpnRefresh 绑定没匹配到"
NEW_BIND = OLD_BIND + '''

  if ($('btnV6Apply')) $('btnV6Apply').onclick = function () {
    var sel = $('v6Mode');
    var m = sel ? sel.value : 'auto';
    v6Say('正在应用 ' + m + ' …');
    call('action=v6mode&mode=' + encodeURIComponent(m)).then(function (r) {
      if (r && r.ok) {
        v6Say('已设为 ' + m + '，实际生效 ' + (r.effective || m));
        v6Render(r, m);
      } else {
        v6Say('设置失败：' + ((r && (r.error || r.warn)) || '未知错误'), true);
      }
    }).catch(function (e) { v6Say('设置失败：' + e, true); });
  };'''
h = h.replace(OLD_BIND, NEW_BIND, 1)

io.open(PAGE, "w", encoding="utf-8", newline="\n").write(h)
print("管理页:", len(h.encode()), hashlib.md5(h.encode()).hexdigest())