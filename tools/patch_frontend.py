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
    j = changed.find(PAR_END, i)
    seg_len = j + len(PAR_END) - i
    filler = b'/*' + b' ' * (seg_len - 4) + b'*/'
    changed = changed[:i] + filler + changed[j + len(PAR_END):]
    print('bytes before/after:', len(data), len(changed))
    assert len(data) == len(changed)

    open(path, 'wb').write(changed)
    print('written')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], len(sys.argv) > 2 and sys.argv[2] == '--write'))
