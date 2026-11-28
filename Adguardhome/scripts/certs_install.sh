#!/system/bin/sh
# 释放并安装模块内置的系统级 CA（HTTPS / MITM）
#   - 刷入时由 customize.sh 调用
#   - 开机由 service.sh 幂等调用
#
# 两条通道，按可用性自动选择：
#   1) KernelSU/Magisk systemless overlay：模块 system/etc/security/cacerts/*
#      —— 由管理器在开机时挂载；若未生效（本机 KernelSU 未启用 OverlayFS），走第 2 条
#   2) 运行时注入：把系统 cacerts 目录快照到 /data/adb/agh/cacerts_orig，
#      再用 tmpfs 覆盖 /system/etc/security/cacerts（原证书 + 我们的两张），
#      这样系统信任库里有 125+N 张系统 CA，App 无法区分，也不会出现用户证书警告。
#
# 安全阀：注入后若清单数量少于快照数量，立刻卸载并放弃，绝不让系统信任库残缺。
MODDIR="${MODDIR:-/data/adb/modules/AdGuardHome}"
SRC="$MODDIR/certs/system/etc/security/cacerts"
DST="$MODDIR/system/etc/security/cacerts"
SYS=/system/etc/security/cacerts
SNAP=/data/adb/agh/cacerts_orig
LOG=/data/adb/agh/certs_install.log

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }

# ---- 标签/权限收口（本脚本所有路径共用）----
# 真机实测（Android 17 / 一加 12）：开机早期 chcon 会被策略挡下来，
# 注入完成后文件标签停在默认的 u:object_r:tmpfs:s0 —— SELinux 下 untrusted_app
# 读不到这些文件，系统信任库对 App 等于空，于是每个 HTTPS 站点都弹证书不受信任。
# restorecon 走 policy 的 file_contexts，比 chcon 稳；两者都跑，再校验一次。
_cacerts_label_fix() {
    chmod 755 "$SYS" 2>/dev/null
    chmod 644 "$SYS"/* 2>/dev/null
    chcon -R u:object_r:system_security_cacerts_file:s0 "$SYS" 2>/dev/null
    restorecon -RF "$SYS" 2>/dev/null
}
_cacerts_bad() {
    ls -Z "$SYS" 2>/dev/null \
        | awk '$1 ~ /^u:object_r:/ && $1 !~ /system_security_cacerts_file/ {c++} END{print c+0}'
}
_cacerts_verify() {
    _cacerts_label_fix
    _bad=$(_cacerts_bad)
    _i=0
    while [ "${_bad:-0}" -gt 0 ] && [ "$_i" -lt 3 ]; do
        sleep 2
        _cacerts_label_fix
        _bad=$(_cacerts_bad)
        _i=$((_i + 1))
    done
    log "[certs] 标签/权限收口：异常文件=${_bad:-?}（0 为正常）"
    # 开机十几秒内策略可能还没完全就绪，再挂一个延迟复核兜底
    (
        sleep 25
        _cacerts_label_fix
        _b=$(_cacerts_bad)
        if [ "${_b:-0}" -gt 0 ]; then
            log "[certs] 延迟复核仍异常：$_b 个文件标签不对"
        else
            log "[certs] 延迟复核通过：目录 755 / 文件 644 / 标签正确"
        fi
    ) >/dev/null 2>&1 &
}

[ -d "$SRC" ] || { log "[certs] 未找到内置仓库: $SRC"; exit 0; }

# ---------- 通道 1：模块 overlay 目录 ----------
mkdir -p "$DST" 2>/dev/null
n=0
for f in "$SRC"/*.0; do
    [ -f "$f" ] || continue
    b=${f##*/}
    cp -f "$f" "$DST/$b" 2>/dev/null || continue
    chmod 644 "$DST/$b" 2>/dev/null
    chcon u:object_r:system_security_cacerts_file:s0 "$DST/$b" 2>/dev/null
    n=$((n + 1))
done
chcon -R u:object_r:system_security_cacerts_file:s0 "$DST" 2>/dev/null
chmod 755 "$DST" 2>/dev/null
log "[certs] overlay 目录已就绪：$n 张 -> $DST"

# ---------- 通道 2：运行时注入（overlay 未生效时） ----------
# 【每次开机都必须先做这一步】tmpfs 挂载点每次重建，目录权限必定退回 0700。
# 0700 下 uid!=0 的进程（所有 App / WebView / Chrome / SDK）打不开这个目录，
# 系统信任库对它们等于空 —— 表现就是「所有 HTTPS 站点都弹证书不受信任」。
# 注意：必须放在任何 exit 之前，否则「信任库已含全部 CA」那条提前 return 会跳过它。
if grep -q " $SYS " /proc/mounts 2>/dev/null; then
    _cacerts_verify
fi

need=0
for f in "$SRC"/*.0; do
    b=${f##*/}
    [ -f "$SYS/$b" ] || need=1
done

if [ "$need" = "0" ]; then
    log "[certs] 系统信任库已含全部内置 CA，无需注入"
    exit 0
fi

# 已有 tmpfs 挂载 → 直接核对清单
if mountpoint -q "$SYS" 2>/dev/null || grep -q " $SYS " /proc/mounts 2>/dev/null; then
    # tmpfs 每次开机都是新目录：权限退回 0700、文件标签退回 u:object_r:tmpfs:s0，
    # 两者都会让普通 App 读不到 CA（表现就是所有 HTTPS 站弹证书错误），每次都收口一次。
    _cacerts_verify
    cur=$(ls "$SYS" 2>/dev/null | wc -l | tr -d ' ')
    if [ -f "$SNAP/.count" ]; then
        base=$(cat "$SNAP/.count" 2>/dev/null | tr -d ' ')
        if [ -n "$base" ] && [ "$cur" -lt "$base" ]; then
            log "[certs] 已挂载但清单残缺（$cur < $base），卸载回滚"
            umount "$SYS" 2>/dev/null
            exit 0
        fi
    fi
    log "[certs] 已注入且清单完整（$cur 张），保持"
    exit 0
fi

# 首次注入：快照系统原有证书
if [ ! -d "$SNAP" ] || [ -z "$(ls "$SNAP" 2>/dev/null)" ]; then
    mkdir -p "$SNAP" 2>/dev/null
    cp -a "$SYS"/. "$SNAP"/ 2>/dev/null
    base=$(ls "$SNAP" 2>/dev/null | wc -l | tr -d ' ')
    printf '%s' "$base" > "$SNAP/.count" 2>/dev/null
    log "[certs] 系统 CA 快照 $base 张 -> $SNAP"
else
    base=$(cat "$SNAP/.count" 2>/dev/null | tr -d ' ')
    [ -n "$base" ] || base=$(ls "$SNAP" 2>/dev/null | wc -l | tr -d ' ')
fi

case "$base" in
    ''|*[!0-9]*) base=0 ;;
esac
if [ "$base" -lt 50 ]; then
    log "[certs] 快照数量异常（$base），放弃注入以免损坏信任库"
    exit 0
fi

# 造 tmpfs 副本：快照 + 我们的证书
TMPD="/data/adb/agh/cacerts_new"
rm -rf "$TMPD" 2>/dev/null
mkdir -p "$TMPD" 2>/dev/null
cp -a "$SNAP"/. "$TMPD"/ 2>/dev/null
rm -f "$TMPD/.count" 2>/dev/null
added=0
for f in "$SRC"/*.0; do
    [ -f "$f" ] || continue
    b=${f##*/}
    cp -f "$f" "$TMPD/$b" 2>/dev/null && added=$((added + 1))
done
chmod 644 "$TMPD"/* 2>/dev/null
chmod 755 "$TMPD" 2>/dev/null
chcon -R u:object_r:system_security_cacerts_file:s0 "$TMPD" 2>/dev/null

expect=$((base + added))
got=$(ls "$TMPD" 2>/dev/null | wc -l | tr -d ' ')
if [ "$got" -lt "$expect" ]; then
    log "[certs] 副本不完整（$got < $expect），放弃注入"
    rm -rf "$TMPD" 2>/dev/null
    exit 0
fi

# 挂载
mount -t tmpfs tmpfs "$SYS" 2>/dev/null || {
    log "[certs] tmpfs 挂载 $SYS 失败（可能需要在 KernelSU 授权下运行）"
    exit 0
}
cp -a "$TMPD"/. "$SYS"/ 2>/dev/null
# 关键：tmpfs 挂载点的目录权限是 0700、文件 SELinux 标签是 u:object_r:tmpfs:s0。
# 两者不修，uid!=0 的进程（所有 App / WebView / Chrome / SDK）都读不到 CA，
# 系统信任库对它们等于空 —— 每个 HTTPS 站点都会弹「证书不受信任」。
_cacerts_verify

# 安全阀：挂载后核对
cur=$(ls "$SYS" 2>/dev/null | wc -l | tr -d ' ')
if [ "$cur" -lt "$base" ]; then
    log "[certs] 注入后清单残缺（$cur < $base），立即卸载回滚"
    umount "$SYS" 2>/dev/null
    exit 0
fi

log "[certs] 注入完成：$base 张系统 CA + $added 张模块 CA = $cur 张"
exit 0
