#!/system/bin/sh
# AdGuardHome-SmartDNS 模块卸载脚本
# 注意：本脚本由 ksud 在「模块被删除（remove 标记）后的下一次开机」自动执行。
# 卸载日志写在 /data/adb/agh-uninstall.log（不在被删目录内，方便事后取证）。

AGH_DIR="/data/adb/agh"
ADGPATH="/data/adb/modules/AdGuardHome"
PROXY_SCRIPT="$AGH_DIR/scripts/ProxyConfig.sh"
LOG="/data/adb/agh-uninstall.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null; }

log "===== 开始卸载 AdGuardHome 模块（pid $$）====="

# ---------- 1. 停止本模块拉起的所有进程 ----------
# 用 pgrep -f 精确匹配，避免遍历 /proc 时对已退出 pid 报
# "can't open /proc/<pid>/cmdline: No such file or directory"
kill_pat() {
    _found=0
    for _p in $(pgrep -f "$1" 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        [ "$_p" = "$PPID" ] && continue
        kill -9 "$_p" 2>/dev/null && { _found=1; log "  已停止 pid $_p ($1)"; }
    done
    [ "$_found" = "1" ] && FOUND=1
    return 0
}

for _round in 1 2 3; do
    FOUND=0
    kill_pat "$AGH_DIR/bin/AdGuardHome"
    kill_pat "$AGH_DIR/bin/dnsenc"
    kill_pat "$AGH_DIR/scripts/iptables.sh"
    kill_pat "$AGH_DIR/scripts/ModuleMOD.sh"
    kill_pat "$AGH_DIR/scripts/NoAdsService.sh"
    kill_pat "$AGH_DIR/scripts/ProxyConfig.sh"
    kill_pat "$AGH_DIR/scripts/sd-restart.sh"
    kill_pat "httpd -p 127.0.0.1:6081"
    kill_pat "/usr/local/lib/smartdns/smartdns"
    [ "$FOUND" = "0" ] && break
    sleep 1
done

# ---------- 2. 卸载 SmartDNS chroot 挂载点 ----------
for _m in dev proc sys tmp run; do
    umount "$AGH_DIR/smartdns/$_m" 2>/dev/null
done
log "  已卸载 chroot 挂载点"

# ---------- 3. 还原被本模块修改过的代理模块 ----------
[ -f "$PROXY_SCRIPT" ] && "$PROXY_SCRIPT" --clean 2>/dev/null
log "  已还原代理模块配置"

# ---------- 4. 清理 iptables 规则残留 ----------
iptables -w 2 -t nat -D OUTPUT -j ADGUARD 2>/dev/null
iptables -w 2 -t nat -D PREROUTING -j ADGUARD 2>/dev/null
iptables -w 2 -t nat -F ADGUARD 2>/dev/null
iptables -w 2 -t nat -X ADGUARD 2>/dev/null
iptables -w 2 -t filter -D OUTPUT -j AGH_HARDEN 2>/dev/null
iptables -w 2 -t filter -F AGH_HARDEN 2>/dev/null
iptables -w 2 -t filter -X AGH_HARDEN 2>/dev/null
ip6tables -w 2 -t nat -D OUTPUT -j ADGUARD 2>/dev/null
ip6tables -w 2 -t nat -F ADGUARD 2>/dev/null
ip6tables -w 2 -t nat -X ADGUARD 2>/dev/null
ip6tables -w 2 -t filter -D OUTPUT -j AGH_HARDEN6 2>/dev/null
ip6tables -w 2 -t filter -F AGH_HARDEN6 2>/dev/null
ip6tables -w 2 -t filter -X AGH_HARDEN6 2>/dev/null
log "  已清理 iptables 规则链"

# ---------- 5. 恢复被 NoAdsService 改过的系统文件 ----------
if [ -f "$AGH_DIR/scripts/NoAdsService.sh" ]; then
    grep 'block_ad' "$AGH_DIR/scripts/NoAdsService.sh" 2>/dev/null \
        | grep -o '".*"' | tr -d '"' | while IFS= read -r p; do
        [ -n "$p" ] && [ -e "$p" ] || continue
        find "$p" \( -type f -o -type d \) 2>/dev/null | while IFS= read -r f; do
            if [ -d "$f" ]; then
                lsattr -d "$f" 2>/dev/null | grep -q "i-" && { chattr -i "$f"; rmdir "$f"; }
            else
                lsattr "$f" 2>/dev/null | grep -q "i-" && { chattr -i "$f"; rm -f "$f"; }
            fi
        done
    done
fi

# ---------- 6. 解除脚本防篡改保护 ----------
find "$AGH_DIR/scripts" "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \; 2>/dev/null

# ---------- 7. 保留用户数据（重装后可恢复）----------
# 卸载不再无脑全删：yaml（过滤器/自定义规则/端口）、内置规则、本地 hosts、
# SmartDNS 配置（上游/分流/加密上游）都会被搬到 /data/adb/agh-uninstalled-<时间>/
KEEP="/data/adb/agh-uninstalled-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$KEEP" 2>/dev/null
KEPT=0

if [ -d "$AGH_DIR/backup" ]; then
    cp -rf "$AGH_DIR/backup" "$KEEP/" 2>/dev/null && KEPT=1
fi
if [ -f "$AGH_DIR/bin/AdGuardHome.yaml" ]; then
    cp -f "$AGH_DIR/bin/AdGuardHome.yaml" "$KEEP/AdGuardHome.yaml" 2>/dev/null && KEPT=1
fi
if [ -d "$AGH_DIR/smartdns/etc/smartdns" ]; then
    cp -rf "$AGH_DIR/smartdns/etc/smartdns" "$KEEP/smartdns-etc" 2>/dev/null && KEPT=1
fi
if [ -d "$ADGPATH/rules" ]; then
    mkdir -p "$KEEP/rules" 2>/dev/null
    for _f in "$ADGPATH"/rules/*; do
        [ -f "$_f" ] || continue
        cp -f "$_f" "$KEEP/rules/" 2>/dev/null && KEPT=1
    done
fi
if [ -d "$ADGPATH/hosts" ]; then
    cp -rf "$ADGPATH/hosts" "$KEEP/" 2>/dev/null && KEPT=1
fi
if [ -f "$ADGPATH/module.prop" ]; then
    cp -f "$ADGPATH/module.prop" "$KEEP/module.prop.bak" 2>/dev/null
fi

if [ "$KEPT" = "1" ]; then
    log "  已保留用户数据到 $KEEP（重装后可从该目录恢复）"
else
    rmdir "$KEEP" 2>/dev/null
fi

# ---------- 8. 删除运行目录与模块目录 ----------
[ -d "$AGH_DIR" ] && rm -rf "$AGH_DIR" && log "  已删除 $AGH_DIR"
[ -d "$ADGPATH" ] && rm -rf "$ADGPATH" && log "  已删除 $ADGPATH"

log "===== 卸载完成 ====="
exit 0
