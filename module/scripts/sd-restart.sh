#!/system/bin/sh
# ============================================================
# 重启 SmartDNS（供上游服务器管理页调用）
# 先杀掉进程，等守护进程（iptables.sh 的 smartdns 守护）拉起；
# 若守护没在跑，则自己拉起，保证一定恢复。
# ============================================================
AGH_DIR=/data/adb/agh
SD="$AGH_DIR/smartdns"
BIN="$SD/usr/local/lib/smartdns/smartdns"

[ -x "$BIN" ] || exit 1

# 等端口真正释放（pkill 之后内核回收 UDP 端口有延迟，直接启动会 bind 失败）
wait_port_free() {
    _p="$1"; _i=0
    while [ "$_i" -lt 12 ]; do
        if ! netstat -lun 2>/dev/null | grep -q "127.0.0.1:$_p " \
           && ! netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$_p "; then
            return 0
        fi
        sleep 0.5
        _i=$((_i+1))
    done
    return 0
}

# 杀掉 dnsenc 并等端口释放
stop_dnsenc() {
    pkill -9 -f "$AGH_DIR/bin/dnsenc" 2>/dev/null
    _i=0
    while [ "$_i" -lt 20 ]; do
        pgrep -f "$AGH_DIR/bin/dnsenc" >/dev/null 2>&1 || break
        sleep 0.25; _i=$((_i+1))
    done
    wait_port_free 6054
}

ENC="$SD/etc/smartdns/encrypted.conf"
ENC_SRV="$SD/etc/smartdns/enc-servers.conf"
CONF="$SD/etc/smartdns/smartdns.conf"
RULES="$SD/etc/smartdns/domain-rules.conf"

# 同步加密上游配置 → enc-servers.conf
# 加密上游单独成组 enc 并从默认组排除：只有 domain-rules 里点名 enc 的域名才走加密，
# 其余域名不受影响（否则每次查询都要多等一次 DoH 握手）。
encn=$(grep -vE '^[[:space:]]*(#|$)' "$ENC" 2>/dev/null | grep -c . 2>/dev/null)
[ -n "$encn" ] || encn=0
{
    echo "# 由 sd-restart.sh 自动生成，请勿手改。"
    if [ "$encn" -gt 0 ]; then
        echo "server 127.0.0.1:6054 -group enc -exclude-default-group"
    fi
} > "$ENC_SRV" 2>/dev/null
grep -q 'enc-servers\.conf' "$CONF" 2>/dev/null || echo "conf-file /etc/smartdns/enc-servers.conf" >> "$CONF"
grep -q 'domain-rules\.conf' "$CONF" 2>/dev/null || echo "conf-file /etc/smartdns/domain-rules.conf" >> "$CONF"
if [ -f "$RULES" ]; then
    if [ "$encn" -gt 0 ]; then
        sed -i "/^[[:space:]]*domain-rules .*→/s/^/#/" "$RULES" 2>/dev/null
sed -i "s/^#[[:space:]]*\(domain-rules \/[^/]*\/ -nameserver enc\)$/\1/" "$RULES" 2>/dev/null
    else
        sed -i "s/^\(domain-rules \/[^/]*\/ -nameserver enc\)$/#\1/" "$RULES" 2>/dev/null
    fi
fi

# 重启加密转发（配置可能变了）：先停干净并等端口释放，避免 bind: address already in use
stop_dnsenc
if [ "$encn" -gt 0 ] && [ -x "$AGH_DIR/bin/dnsenc" ]; then
    SSL_CERT_DIR=/system/etc/security/cacerts/ setsid "$AGH_DIR/bin/dnsenc" \
        -listen 127.0.0.1:6054 -conf "$ENC" \
        -bootstrap "${DNSENC_BOOTSTRAP:-180.184.1.1:53}" >> "$AGH_DIR/dnsenc.log" 2>&1 &
    _i=0
    while [ "$_i" -lt 12 ]; do
        netstat -lun 2>/dev/null | grep -q '127.0.0.1:6054 ' && break
        sleep 0.5; _i=$((_i+1))
    done
fi

# ---------------------------------------------------------------
# 停 SmartDNS：必须等「进程退出 + 6053 真正释放」。
# 之前只看进程在不在，进程被杀后守护立刻用旧端口启动会 bind 失败，但进程还活着，
# 于是变成「进程在、6053 没人听」的假运行状态 —— 全机 DNS 直接挂掉。
# ---------------------------------------------------------------
stop_smartdns() {
    pkill -9 -f '/usr/local/lib/smartdns/smartdns' 2>/dev/null
    _i=0
    while [ "$_i" -lt 24 ]; do
        pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1 || break
        sleep 0.25; _i=$((_i+1))
    done
    wait_port_free 6053
    # 残留 pid 文件会让新实例以为「已在运行」而直接退出
    rm -f "$SD"/run/*.pid "$SD"/var/run/*.pid 2>/dev/null
}

sd_listening() {
    netstat -lun 2>/dev/null | grep -q '127.0.0.1:6053 '
}

start_sd() {
    setsid chroot "$SD" /usr/local/lib/smartdns/smartdns >/dev/null 2>&1 &
    _i=0
    while [ "$_i" -lt 20 ]; do
        sleep 0.5
        sd_listening && return 0
        _i=$((_i+1))
    done
    return 1
}

LOG="$AGH_DIR/agh.log"
sd_log() { echo "$(date '+%F %T') $1" >> "$LOG"; }

stop_smartdns
# 等守护拉起（守护循环 5s 一次）；判据是「端口在听」，不是「进程在」
i=0
while [ $i -lt 8 ]; do
    sleep 1
    if sd_listening; then
        exit 0
    fi
    i=$((i+1))
done

# 守护没拉起 → 自己启动
mkdir -p "$SD/dev" "$SD/proc" "$SD/sys" "$SD/tmp" "$SD/run"
# SmartDNS UI 数据库目录（必须持久且可写，否则 UI 判定磁盘空间为 0 会暂停请求处理）
mkdir -p "$SD/var/lib/smartdns" "$SD/var/cache/smartdns" "$SD/var/log/smartdns" 2>/dev/null
chown 9999:9999 "$SD/var/lib/smartdns" "$SD/var/cache/smartdns" 2>/dev/null
# 老配置 data-dir 还在 tmpfs 上就迁走
if [ -f "$CONF" ] && grep -qE '^[[:space:]]*data-dir[[:space:]]+/tmp/' "$CONF" 2>/dev/null; then
    sed -i "s|^[[:space:]]*data-dir[[:space:]].*|data-dir /var/lib/smartdns|" "$CONF"
fi
mountpoint -q "$SD/dev"  || mount --bind /dev  "$SD/dev"  2>/dev/null
mountpoint -q "$SD/proc" || mount --bind /proc "$SD/proc" 2>/dev/null
mountpoint -q "$SD/sys"  || mount --bind /sys  "$SD/sys"  2>/dev/null
mountpoint -q "$SD/tmp"  || mount -t tmpfs -o mode=0777,nosuid,nodev tmpfs "$SD/tmp" 2>/dev/null
mountpoint -q "$SD/run"  || mount -t tmpfs -o mode=0777,nosuid,nodev tmpfs "$SD/run" 2>/dev/null
pkill -9 -f '/usr/local/lib/smartdns/smartdns' 2>/dev/null
rm -f "$SD"/run/*.pid "$SD"/var/run/*.pid 2>/dev/null
if start_sd; then
    exit 0
fi
sd_log "[WARN] SmartDNS 启动后 6053 仍未监听（bind 失败？），请检查 $CONF。"
exit 1
