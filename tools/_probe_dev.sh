#!/system/bin/sh
echo "== 基本 =="
echo "model=$(getprop ro.product.model) product=$(getprop ro.product.device) brand=$(getprop ro.product.brand)"
echo "android=$(getprop ro.build.version.release) sdk=$(getprop ro.build.version.sdk)"
echo "abi=$(getprop ro.product.cpu.abi) abilist=$(getprop ro.product.cpu.abilist)"
echo "kernel=$(uname -r) arch=$(uname -m)"
echo "selinux=$(getenforce)"
echo "== root 管理器 =="
for p in /data/adb/ksu /data/adb/magisk /data/adb/ap /data/adb/ksud /data/adb/modules /sbin/su /system/xbin/su /debug_ramdisk/su; do
  [ -e "$p" ] && echo "  found $p"
done
command -v su && echo "  su=$(command -v su)"
su -c 'id' 2>&1 | head -1
echo "== busybox =="
for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/modules/busybox-ndk/system/xbin/busybox /system/xbin/busybox /system/bin/busybox; do
  [ -x "$b" ] && echo "  $b -> $($b 2>&1 | head -1)"
done
command -v busybox >/dev/null 2>&1 && echo "  PATH busybox: $(command -v busybox)"
echo "== 命令可用性 =="
for c in iptables ip6tables ip iptables-save curl pgrep setsid netstat ss chattr lsattr stat awk sed grep; do
  w=$(command -v $c 2>/dev/null); echo "  $c=${w:-MISSING}"
done
echo "== ip6tables nat 表 =="
ip6tables -t nat -L -n >/dev/null 2>&1 && echo "  nat: YES" || echo "  nat: NO ($(ip6tables -t nat -L -n 2>&1 | head -1))"
ip6tables -t mangle -L -n >/dev/null 2>&1 && echo "  mangle: YES" || echo "  mangle: NO"
echo "== iptables 版本/后端 =="
iptables --version 2>&1 | head -1
iptables -t nat -L -n >/dev/null 2>&1 && echo "  nat(v4): YES" || echo "  nat(v4): NO"
echo "== 接口 =="
ip -o link show up 2>/dev/null | awk '{print $2}' | tr '\n' ' '; echo
echo "== 系统 DNS =="
dumpsys connectivity 2>/dev/null | grep -m4 -E 'DnsAddresses|ServerAddress' | sed 's/^ *//'
echo "== tuntap 造隧道（放行测试）=="
ip tuntap add dev tun7 mode tun 2>&1 && { ip link set tun7 up 2>&1; echo "  tun7 created"; ip tuntap del dev tun7 mode tun 2>&1; echo "  tun7 removed"; } || echo "  tuntap: FAIL"
exit 0