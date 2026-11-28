# -*- coding: utf-8 -*-
"""Patch the fork AGH binary's embedded frontend JS (accessibility/privacy page).

Two edits, both length-preserving so the ELF layout stays valid:

1) First-frame defaults of the privacy page component:
   dns:!0,vpn:!0,ip:!0,sb:!1,par:!1,ntp:!1,dhcp:!1,smb:!1,tcp:!1,snmp:!1
   ->  dns:!0,vpn:!0,ip:!0,sb:!1,par:!1,ntp:!0,dhcp:!0,smb:!0,tcp:!0,snmp:!0
   (matches what privacy.conf actually holds: all 8 network switches on)
   This alone removes the "grey then green" flip for those switches, because
   the first painted frame already equals the value the GET returns.

2) Comment out the sb / par entries of the switch array so the page no longer
   renders "恶意网站拦截" / "成人内容过滤" at all:
   [{key:"sb",...},{key:"par",...}] -> /* ... */  (same byte count)
"""
import sys

OLD_DEFAULTS = (
    b'dns:!0,vpn:!0,ip:!0,sb:!1,par:!1,ntp:!1,dhcp:!1,smb:!1,tcp:!1,snmp:!1'
)
NEW_DEFAULTS = (
    b'dns:!0,vpn:!0,ip:!0,sb:!1,par:!1,ntp:!0,dhcp:!0,smb:!0,tcp:!0,snmp:!0'
)

SB_START = '{key:"sb",title:"恶意网站拦截"'.encode()
PAR_END = '系统级生效。"}'.encode()


def main(path: str, write: bool) -> int:
    data = open(path, 'rb').read()

    n1 = data.count(OLD_DEFAULTS)
    print('defaults occurrences:', n1)

    i = data.find(SB_START)
    print('sb array item offset:', i)
    if i >= 0:
        j = data.find(PAR_END, i)
        print('par end offset:', j)
        if j >= 0:
            seg_len = j + len(PAR_END) - i
            print('segment length:', seg_len)
            print('segment head:', data[i:i + 60].decode('utf-8', 'replace'))
            print('segment tail:', data[j - 40:j + len(PAR_END)].decode('utf-8', 'replace'))
    print('sb title occurrences:', data.count('恶意网站拦截'.encode()))
    print('par title occurrences:', data.count('成人内容过滤'.encode()))

    if not write:
        return 0

    changed = data.replace(OLD_DEFAULTS, NEW_DEFAULTS)
    n2 = changed.count(OLD_DEFAULTS)
    print('defaults left after patch:', n2)

    i = changed.find(SB_START)
    j = changed.find(PAR_END, i) if i >= 0 else -1
    if i >= 0 and j > i:
        seg_len = j + len(PAR_END) - i
        filler = b'/*' + b' ' * (seg_len - 4) + b'*/'
        changed = changed[:i] + filler + changed[j + len(PAR_END):]
        print('bytes before/after:', len(data), len(changed))
        assert len(data) == len(changed)

    # 3) 侧栏「高级设置」里的「证书」项：用数组 spread 空占位删掉（等长）。
    #    注意不能用 /*...*/ 注释——实测会把整个分组变成不可展开（items 失效）。
    menu_old = '{label:"证书",path:$t.Certificates,routePath:"Certificates"},'.encode()
    mi = changed.find(menu_old)
    print('menu cert item offset:', mi)
    if mi >= 0:
        menu_new = b'...[],' + b' ' * (len(menu_old) - 6)
        assert len(menu_new) == len(menu_old)
        changed = changed[:mi] + menu_new + changed[mi + len(menu_old):]

    # 4) 开关圆点 transition 置 none：首帧不再从「关的位置」滑到「开的位置」
    css_old = (b'background-color: var(--fills-switch-knob);\n'
               b'        transition:\n'
               b'            transform var(--t2),\n'
               b'            background-color var(--t2);')
    css_head = b'background-color: var(--fills-switch-knob);\n        transition:none;'
    css_new = css_head + b' ' * (len(css_old) - len(css_head))
    n_css = changed.count(css_old)
    print('switch-knob transition occurrences:', n_css)
    changed = changed.replace(css_old, css_new)

    # 5) 侧栏「高级设置」里的「脚本」项同样删掉（数组最后一项，无尾逗号）
    scr_old = '{label:"脚本",path:$t.Scripts,routePath:"Scripts"}'.encode()
    si = changed.find(scr_old)
    print('menu scripts item offset:', si)
    if si >= 0:
        scr_new = b'...[]' + b' ' * (len(scr_old) - 5)
        assert len(scr_new) == len(scr_old)
        changed = changed[:si] + scr_new + changed[si + len(scr_old):]

    # 6) 关掉 Android/WebView 的字体自动放大（font boosting）：
    #    html 规则里的 tap-highlight 换成 -webkit-text-size-adjust:100%（等长）。
    #    不加这条时，长页面下方文本块会在布局宽度确定后被 boost 一次，表现为「标题字体跳一下」。
    html_old = b'html {\n    -webkit-tap-highlight-color: transparent;\n}'
    html_head = b'html {\n    -webkit-text-size-adjust: 100%;'
    html_new = html_head + b' ' * (len(html_old) - len(html_head) - 2) + b'\n}'
    n_html = changed.count(html_old)
    print('html tap-highlight rules:', n_html)
    changed = changed.replace(html_old, html_new)

    # 7) 隐私页首帧：异步 fetch → 同步 XHR。
    #    fetch 的回调必然排在首帧绘制之后，于是「默认值先画一遍 → 真值回来再改」，
    #    用户看到的就是「开关自己翻一次」（关过的开关先绿后灰）。
    #    实测对照（conf 里 smb=0，竖屏 30fps 逐帧统计开关区绿色像素）：
    #      v7(异步)：第 110 帧页面出现时 smb 区绿=1004，第 127 帧降到 0 —— 翻了一次；
    #      v8(同步)：全程 230 帧 smb 区绿=0，页面首帧就是最终值。
    s0 = changed.find(b'A(()=>{fetch(`')
    if s0 >= 0:
        tail = b'))}),n=Vy()'
        rel = changed[s0:s0 + 240].find(tail)
        old_seg = changed[s0:s0 + rel + 4]
        q = b'"'
        nb = (b'A(()=>{try{var X=new XMLHttpRequest;X.open(' + q + b'GET' + q
              + b',Hy,0);X.send();r(JSON.parse(X.responseText)),a(' + q + q
              + b')}catch(_){a(' + q + '读取状态失败'.encode() + q + b')}})')
        assert len(nb) <= len(old_seg)
        changed = changed[:s0] + nb + b' ' * (len(old_seg) - len(nb)) + changed[s0 + len(old_seg):]
        print('privacy fetch -> sync XHR at', s0, 'seg', len(old_seg), '->', len(nb))

    assert len(data) == len(changed)
    print('bytes before/after:', len(data), len(changed))
    open(path, 'wb').write(changed)
    print('written')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], len(sys.argv) > 2 and sys.argv[2] == '--write'))
