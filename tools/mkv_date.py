import io, os, sys, zipfile, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

SRC = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
OUT = r"F:\BUG\AdGuardHome-SmartDNS-Merged-20261122.zip"

SKIP_DIRS = ("rules/subscriptions/", "bin/data/")
SKIP_FILES = ("iptables-DROP规则.txt",)

if os.path.exists(OUT):
    os.remove(OUT)

count = 0
skipped = 0
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, SRC).replace("\\", "/")
            if any(rel.startswith(p) for p in SKIP_DIRS) or rel in SKIP_FILES:
                skipped += 1
                continue
            z.write(full, rel)
            count += 1

size = os.path.getsize(OUT)
md5 = hashlib.md5(open(OUT, "rb").read()).hexdigest()
print("zip:", OUT)
print("entries:", count, "skipped:", skipped, "size:", size, "md5:", md5)

with zipfile.ZipFile(OUT) as z:
    names = z.namelist()
    must = ["module.prop", "service.sh", "customize.sh", "action.sh", "uninstall.sh",
            "bin/AdGuardHome", "bin/AdGuardHome.yaml", "bin/dnsenc",
            "scripts/webui/cgi-bin/upstream", "scripts/webui/upstream-manage.html",
            "scripts/sd-restart.sh", "scripts/iptables.sh", "scripts/ProxyConfig.sh",
            "scripts/config.prop",
            "smartdns/etc/smartdns/servers.conf", "smartdns/etc/smartdns/smartdns.conf",
            "smartdns/etc/smartdns/adblock.conf", "smartdns/etc/smartdns/encrypted.conf",
            "smartdns/etc/smartdns/enc-servers.conf", "smartdns/etc/smartdns/domain-rules.conf",
            "smartdns/usr/local/lib/smartdns/smartdns", "smartdns/lib/smartdns_ui.so",
            "smartdns/usr/share/smartdns/wwwroot/dashboard/upstream-servers.html",
            "hosts/hosts", "rules/myallow.txt"]
    miss = [m for m in must if m not in names]
    print("缺失:", miss if miss else "0")
    print("缓存残留: subscriptions=%d  bin/data=%d" % (
        len([n for n in names if n.startswith("rules/subscriptions/")]),
        len([n for n in names if n.startswith("bin/data/")])))
    for f in ["module.prop", "service.sh", "customize.sh", "scripts/config.prop",
              "scripts/webui/cgi-bin/upstream", "scripts/webui/upstream-manage.html",
              "scripts/iptables.sh", "scripts/ProxyConfig.sh", "bin/AdGuardHome"]:
        if f in names:
            d = z.read(f)
            print("  %-45s %6d  md5=%s" % (f, len(d), hashlib.md5(d).hexdigest()))