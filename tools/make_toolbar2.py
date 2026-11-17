# v2：把按钮插到「刷新」按钮紧右侧（nextSibling），不是工具栏最右端
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

JS = r"""
<script id="agh-up-toolbar-script">
(function(){
  if (window.__aghUpToolbar) return;
  window.__aghUpToolbar = 1;

  // 只在 SmartDNS「上游服务器」页面生效，绝不进其它页面
  var path = location.pathname || '';
  if (path.indexOf('upstream-servers') < 0) return;

  var BTN_ID = 'agh-upstream-toolbar-btn';
  var URL_MANAGE = 'http://127.0.0.1:6081/upstream-manage.html';

  function makeBtn(){
    var b = document.createElement('button');
    b.type = 'button';
    b.id = BTN_ID;
    b.title = '\u4E0A\u6E38\u670D\u52A1\u5668\u7BA1\u7406';
    b.setAttribute('aria-label', '\u4E0A\u6E38\u670D\u52A1\u5668\u7BA1\u7406');
    b.innerHTML = '<span style="font-size:15px;line-height:1">\uFF0B</span>'
                + '<span>\u4E0A\u6E38</span>';
    b.style.cssText = [
      'display:inline-flex','align-items:center','justify-content:center','gap:4px',
      'margin:0 auto 0 0','padding:0 12px','height:34px','box-sizing:border-box',
      'border:1px solid #2563eb','border-radius:17px',
      'background:#2563eb','color:#fff',
      'font:600 13px/1 "Inter",-apple-system,BlinkMacSystemFont,"Noto Sans SC",sans-serif',
      'cursor:pointer','white-space:nowrap','vertical-align:middle','flex:0 0 auto'
    ].join(';');
    b.onclick = function(){
      var w = window.open(URL_MANAGE, '_blank', 'noopener');
      if (!w) location.href = URL_MANAGE;
    };
    return b;
  }

  function findRefresh(){
    var sels = [
      'button[aria-label*="\u5237\u65B0"]',
      'button[title*="\u5237\u65B0"]',
      'button[aria-label*="Refresh"]',
      'button[title*="Refresh"]'
    ];
    for (var s = 0; s < sels.length; s++) {
      var list = document.querySelectorAll(sels[s]);
      for (var i = 0; i < list.length; i++) {
        if (list[i].closest('.MuiTablePagination-root')) continue;
        return list[i];
      }
    }
    return null;
  }

  function place(){
    var cur = document.getElementById(BTN_ID);
    var rf = findRefresh();
    if (!rf) return false;
    if (cur && cur.previousSibling === rf) return true;   // 已在刷新按钮右边
    if (cur && cur.parentNode) cur.parentNode.removeChild(cur);
    var btn = makeBtn();
    if (rf.nextSibling) rf.parentNode.insertBefore(btn, rf.nextSibling);
    else rf.parentNode.appendChild(btn);
    return true;
  }

  function fallback(){
    if (document.getElementById(BTN_ID)) return;
    var b = makeBtn();
    b.style.position = 'fixed';
    b.style.top = '12px';
    b.style.right = '12px';
    b.style.zIndex = '2147483000';
    b.style.boxShadow = '0 4px 12px rgba(0,0,0,.25)';
    document.body.appendChild(b);
  }

  var tries = 0;
  function tick(){
    if (place()) return;
    tries++;
    if (tries > 45) { fallback(); return; }
    setTimeout(tick, 400);
  }

  function boot(){
    tick();
    var mo = new MutationObserver(function(){
      var cur = document.getElementById(BTN_ID);
      var rf = findRefresh();
      if (!rf) return;
      if (!cur || cur.previousSibling !== rf) place();
    });
    if (document.body) mo.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
</script>
"""

io.open(r"F:\BUG\_toolbar_snippet.html", "w", encoding="utf-8", newline="\n").write(JS)
print("snippet bytes:", len(JS.encode("utf-8")))