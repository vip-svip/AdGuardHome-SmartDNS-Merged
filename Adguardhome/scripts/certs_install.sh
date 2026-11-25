#!/system/bin/sh
# 释放并安装模块内置的系统级 CA（HTTPS / MITM）
#   - 刷入时由 customize.sh 调用
#   - 开机由 service.sh 幂等调用（防止 overlay 未挂载或系统 cacerts 被替换）
# 目标：Android 系统信任库（Magisk/KernelSU systemless overlay）
#      /system/etc/security/cacerts/<subject_hash_old>.0
# 特点：以系统 CA 身份出现，普通 App 无法区分、不会触发用户证书告警，
#      不需要安装描述文件，也不影响任何站点/应用的正常 TLS 校验。

MODDIR="${MODDIR:-/data/adb/modules/AdGuardHome}"
SRC="$MODDIR/certs/system/etc/security/cacerts"
DST="$MODDIR/system/etc/security/cacerts"

[ -d "$SRC" ] || { echo "[certs] 未找到内置证-bundle: $SRC"; exit 0; }

mkdir -p "$DST" 2>/dev/null

n=0
for f in "$SRC"/*.0; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cp -f "$f" "$DST/$b" 2>/dev/null || continue
    chmod 644 "$DST/$b" 2>/dev/null
    # 系统 CA 的 SELinux 标签，缺了会被系统忽略
    chcon u:object_r:system_security_cacerts_file:s0 "$DST/$b" 2>/dev/null
    n=$((n + 1))
done

# 让 overlay 目录本身也带上正确标签
chcon -R u:object_r:system_security_cacerts_file:s0 "$DST" 2>/dev/null

echo "[certs] 已释放 $n 张系统级 CA 到 $DST"
ls -1 "$DST" 2>/dev/null | sed 's/^/[certs]   /'
exit 0
