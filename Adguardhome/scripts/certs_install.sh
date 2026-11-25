#!/system/bin/sh
# 释放并安装模块内置的系统级 CA（HTTPS / MITM）
#   - 刷入时由 customize.sh 调用
#   - 开机由 service.sh 幂等调用
#
# 两条通道，按可用性自动选择：
#   1) KernelSU/Magisk systemless overlay：模块 system/etc/security/cacerts/*
#      —— 由管理器在开机时挂载；若未生效（本机 KernelSU 未启用 OverlayFS），走第 2 条
#   2) 运行时注入：把系统 cacerts 目录快照到 /data/adb/agh/cacerts_orig，
#      用 tmpfs 覆盖 /system/etc/security/cacerts（原证书 + 我们的两张），
#      这样系统信任库里有 125+N 张系统 CA，App 无法区分，也不会出现用户证书告警。
#
# 安全阀：注入后若清单数量少于快照数量，立刻卸载并放弃，绝不让系统信任库残缺。

MODDIR="${MODDIR:-/data/adb/modules/AdGuardHome}"
SRC="$MODDIR/certs/system/etc/security/cacerts"
DST="$MODDIR/system/etc/security/cacerts"
SYS=/system/etc/security/cacerts
SNAP=/data/adb/agh/cacerts_orig
LOG=/data/adb/agh/certs_install.log

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }

[ -d "$SRC" ] || { log "[certs] 未找到内置仓库: $SRC"; exit 0; }

# ---------- 通道 1：模块 overlay 目录 ----------
mkdir -p "$DST" 2>/dev/null
n=0
for f in "$SRC"/*.0; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cp -f "$f" "$DST/$b" 2>/dev/null || continue
    chmod 644 "$DST/$b" 2>/dev/null
    chcon u:object_r:system_security_cacerts_file:s0 "$DST/$b" 2>/dev/null
    n=$((n + 1))
done
chcon -R u:object_r:system_security_cacerts_file:s0 "$DST" 2>/dev/null
log "[certs] overlay 目录已就绪：$n 张 -> $DST"

# ---------- 通道 2：运行时注入（overlay 未生效时） ----------
need=0
for f in "$SRC"/*.0; do
    b=$(basename "$f")
    [ -f "$SYS/$b" ] || need=1
done

if [ "$need" = "0" ]; then
    log "[certs] 系统信任库已可见，无需注入"
    echo "[certs] 已在系统信任库生效（overlay）"
    exit 0
fi

# 已经有 tmpfs 挂着就不重复
if mount 2>/dev/null | grep -q " $SYS "; then
    log "[certs] tmpfs 已挂载，跳过"
    echo "[certs] 已注入（tmpfs 在位）"
    exit 0
fi

if [ ! -d "$SNAP" ]; then
    mkdir -p "$SNAP" 2>/dev/null
    cp -f "$SYS"/* "$SNAP"/ 2>/dev/null
    chmod 644 "$SNAP"/* 2>/dev/null
fi
orig_n=$(ls -1 "$SNAP" 2>/dev/null | wc -l | tr -d ' ')
if [ "${orig_n:-0}" -lt 50 ]; then
    log "[certs] 快照异常（$orig_n 张），放弃注入"
    echo "[certs] 快照不足，放弃注入"
    exit 1
fi

# SELinux：ksu 域默认没有对 system_file 目录的 mounton，先补上（开机需重放）
KS=/data/adb/ksud
[ -f "$KS" ] && {
    "$KS" sepolicy patch 'allow ksu system_file dir mounton' >/dev/null 2>&1
    "$KS" sepolicy patch 'allow ksu system_file file mounton' >/dev/null 2>&1
}
mount -t tmpfs -o mode=755,context=u:object_r:system_file:s0 tmpfs "$SYS" 2>>"$LOG"
if ! mount 2>/dev/null | grep -q " $SYS "; then
    # 重试一次：开机早期 policy 补丁可能尚未落到内核
    sleep 1
    [ -f "$KS" ] && "$KS" sepolicy patch "allow ksu system_file dir file mounton" >/dev/null 2>&1
    mount -t tmpfs -o mode=755 tmpfs "$SYS" 2>>"$LOG"
fi
if ! mount 2>/dev/null | grep -q " $SYS "; then
    log "[certs] tmpfs 挂载失败（SELinux 或内核限制）"
    echo "[certs] 注入失败（SELinux 限制），仅 overlay 通道可用"
    exit 1
fi

cp -f "$SNAP"/* "$SYS"/ 2>/dev/null
for f in "$SRC"/*.0; do
    [ -f "$f" ] || continue
    cp -f "$f" "$SYS/$(basename "$f")" 2>/dev/null
done
chmod 644 "$SYS"/* 2>/dev/null
chcon u:object_r:system_security_cacerts_file:s0 "$SYS"/* 2>/dev/null

new_n=$(ls -1 "$SYS" 2>/dev/null | wc -l | tr -d ' ')
if [ "${new_n:-0}" -lt "$orig_n" ]; then
    umount "$SYS" 2>/dev/null
    log "[certs] 注入后清单残缺（$new_n < $orig_n），已回滚"
    echo "[certs] 注入失败并已回滚"
    exit 1
fi

log "[certs] 注入完成：$orig_n 张原有 + 2 张模块 CA = $new_n"
echo "[certs] 已注入系统信任库（$new_n 张，含模块 2 张）"
exit 0
