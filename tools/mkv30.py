import io, os, sys, zipfile, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

SRC = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
OUT = r"F:\BUG\AdGuardHome-SmartDNS-Merged-20261116-v30.zip"

if os.path.exists(OUT):
    os.remove(OUT)

count = 0
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, SRC).replace("\\", "/")
            z.write(full, rel)
            count += 1

size = os.path.getsize(OUT)
md5 = hashlib.md5(open(OUT, "rb").read()).hexdigest()
print("zip:", OUT)
print("entries:", count, "size:", size, "md5:", md5)

with zipfile.ZipFile(OUT) as z:
    names = set(z.namelist())
    for k in ["module.prop", "service.sh", "customize.sh", "action.sh", "uninstall.sh",
              "bin/AdGuardHome", "bin/AdGuardHome.yaml",
              "scripts/webui/cgi-bin/upstream", "scripts/webui/upstream-manage.html",
              "scripts/sd-restart.sh", "scripts/iptables.sh",
              "smartdns/etc/smartdns/servers.conf", "smartdns/etc/smartdns/smartdns.conf",
              "smartdns/etc/smartdns/adblock.conf",
              "smartdns/usr/share/smartdns/wwwroot/upstream-manage.html",
              "smartdns/usr/share/smartdns/wwwroot/dashboard/upstream-servers.html",
              "hosts/hosts"]:
        print("%-64s %s" % (k, "OK" if k in names else "MISSING"))
    print("total entries:", len(names))
    for k in ["module.prop", "customize.sh", "scripts/webui/cgi-bin/upstream",
              "scripts/webui/upstream-manage.html",
              "smartdns/usr/share/smartdns/wwwroot/dashboard/upstream-servers.html"]:
        if k in names:
            d = z.read(k)
            print("  %-62s %7d  md5=%s" % (k, len(d), hashlib.md5(d).hexdigest()))


