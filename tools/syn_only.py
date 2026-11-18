# -*- coding: utf-8 -*-
"""只做语法检查（多设备），不打印片段。"""
import io, sys, subprocess, hashlib

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)
sys.path.insert(0, r"F:\BUG")
import dev  # noqa: E402

sn = sys.argv[1] if len(sys.argv) > 1 else dev.pick()
ADB = ["adb", "-s", sn]
BASE = r"F:\BUG\AdguardHome-Magisk\Adguardhome"
FILES = [
    BASE + r"\scripts\iptables.sh",
    BASE + r"\service.sh",
    BASE + r"\scripts\sd-restart.sh",
    BASE + r"\scripts\webui\cgi-bin\upstream",
    BASE + r"\scripts\ProxyConfig.sh",
    BASE + r"\customize.sh",
    BASE + r"\uninstall.sh",
    BASE + r"\action.sh",
    BASE + r"\scripts\ModuleMOD.sh",
]
print("device:", sn)
allok = True
for f in FILES:
    b = io.open(f, "rb").read()
    tmp = "/data/local/tmp/_syn.sh"
    subprocess.run(ADB + ["push", f, tmp], capture_output=True, timeout=300)
    p = subprocess.run(ADB + ["shell", "su -c 'sh -n %s; echo EXIT=$?'" % tmp],
                       capture_output=True, timeout=300)
    out = ((p.stdout or b"") + (p.stderr or b"")).decode("utf-8", "replace").strip()
    ok = out.endswith("EXIT=0")
    allok = allok and ok
    name = f.replace(BASE + "\\", "")
    print("  %-30s %7d B  md5=%s  %s" % (name, len(b), hashlib.md5(b).hexdigest()[:12],
                                         "OK" if ok else "!! " + out[-300:]))
print("ALL SYNTAX:", "OK" if allok else "FAIL")