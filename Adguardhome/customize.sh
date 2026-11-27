#!/system/bin/sh
SKIPUNZIP=1

# 多语言检测
locale=$(getprop persist.sys.locale | tr '[:upper:]' '[:lower:]')
[ -z "$locale" ] && locale="zh"
ui_print "- $locale"
case $locale in
  en*) language=en ;;
  *)   language=zh ;;
esac
i18n_print() {
  [ "$language" = "zh" ] && ui_print "$2" || ui_print "$1"
}

# 检测所有Hosts模块
i18n_print "- Checking for Hosts modules" "- 正在检测Hosts模块"
found_hosts=false;for module in /data/adb/modules/*;do [ -f "$module/system/etc/hosts" ]&&[ -f "$module/module.prop" ]&&{ [ "$found_hosts" = false ]&&i18n_print "- Found Hosts modules, auto-removing:" "- 发现Hosts模块，正在自动移除:"&&found_hosts=true;ui_print "  $(grep_prop name "$module/module.prop")";touch "$module/remove";};done
[ "$found_hosts" = true ]&&i18n_print "- Conflicting modules have been marked for removal. Please reboot after installation." "- 冲突模块已标记移除，安装完成后请重启设备。"

AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
SCRIPT_DIR="$AGH_DIR/scripts"
BACKUP_DIR="$AGH_DIR/backup"
ADGPATH="/data/adb/modules/AdGuardHome"
RULES_ROOT="$ADGPATH/rules"
SUBS_ROOT="$RULES_ROOT/subscriptions"

# link_rules_dirs 把 AGH 的规则缓存目录与用户规则目录指向模块根目录：
#   data/userfilters -> modules/AdGuardHome/rules
#   data/filters     -> modules/AdGuardHome/rules/subscriptions
# 这样手动上传的规则与网络订阅下载的规则文件都保存在模块根目录下，
# 模块管理器/文件管理器里可以直接看到、直接编辑。
link_rules_dirs() {
    for pair in "$BIN_DIR/data/userfilters:$RULES_ROOT" "$BIN_DIR/data/filters:$SUBS_ROOT"; do
        dst=${pair%:*}
        src=${pair#*:}
        [ -d "$src" ] || mkdir -p "$src" 2>/dev/null
        if [ -d "$dst" ] && [ ! -L "$dst" ]; then
            # 旧版目录里可能已有规则文件，先搬进模块目录再替换成软链接
            for f in "$dst"/*; do
                [ -f "$f" ] || continue
                b=$(basename "$f")
                [ -f "$src/$b" ] || cp -f "$f" "$src/$b" 2>/dev/null
            done
            rm -rf "$dst"
        fi
        [ -L "$dst" ] && rm -f "$dst"
        ln -sfn "$src" "$dst" 2>/dev/null
    done
}
# 幂等重写 safe_fs_patterns：先删掉原有全部条目再写标准 9 行。
# （旧实现用 sed 追加，会重复行、漏 subscriptions、且把 userfilters 那行替换掉）
normalize_safe_fs() {
    Y="$BIN_DIR/AdGuardHome.yaml"
    [ -f "$Y" ] || return 0
    grep -q '^[[:space:]]*safe_fs_patterns:' "$Y" 2>/dev/null || return 0
    SF_TMP="$Y.sfs.$$"
    awk '
        /^[[:space:]]*safe_fs_patterns:/ {
            print "  safe_fs_patterns:"
            print "    - /data/adb/agh/bin/data/userfilters/*"
            print "    - /data/adb/modules/AdGuardHome/rules/*"
            print "    - /data/adb/modules/AdGuardHome/rules/subscriptions/*"
            print "    - /data/adb/modules/AdGuardHome/*"
            print "    - /data/adb/modules/AdGuardHome/hosts/*"
            print "    - /data/adb/agh/bin/data/filters/*"
            print "    - /sdcard/Download/*"
            print "    - /sdcard/*"
            print "    - /storage/emulated/0/*"
            print "    - /data/local/tmp/*"
            skip=1
            next
        }
        skip==1 && /^[[:space:]]*- / { next }
        { skip=0; print }
    ' "$Y" > "$SF_TMP" 2>/dev/null && cat "$SF_TMP" > "$Y" 2>/dev/null
    rm -f "$SF_TMP" 2>/dev/null
    return 0
}

# 确保 yaml 里 sni_filter 配置完整：enabled=true，端口覆盖 80/443/8443 + Cloudflare 备用 TLS 端口，drop_quic=true
ensure_sni_filter() {
    _y="$BIN_DIR/AdGuardHome.yaml"
    [ -f "$_y" ] || return 0
    _af="$BIN_DIR/scripts/sni_filter.awk"
    [ -f "$_af" ] || return 0
    if grep -q '^sni_filter:' "$_y" 2>/dev/null; then
        _yt="$_y.sni.$$"
        awk -f "$_af" "$_y" > "$_yt" 2>/dev/null && cat "$_yt" > "$_y" 2>/dev/null
        rm -f "$_yt"
    else
        cat >> "$_y" <<SNI_EOF

sni_filter:
  enabled: true
  ports:
    - 80
    - 443
    - 8443
    - 2053
    - 2054
    - 2083
    - 2087
    - 2089
    - 2091
    - 2096
    - 2480
  queue_num: 7
  drop_quic: true
SNI_EOF
    fi
}

PROXY_SCRIPT="$AGH_DIR/scripts/ProxyConfig.sh"

# 升级安装：旧模块目录里的 immutable 标志必须在解压前清干净。
# 不只是 *.sh —— 目录也可以是 immutable（chattr +i 到目录上会让整个子树删不动），
# 而 KernelSU/Magisk 在重启时要把 /data/adb/modules/AdGuardHome 整棵删掉，
# 一个 I 标志就让更新装不上（真机实证：模块一直停在旧构建）。
if [ -d "$ADGPATH" ]; then
    find "$ADGPATH" -type f -exec chattr -i {} \; 2>/dev/null
    find "$ADGPATH" -type d -exec chattr -i {} \; 2>/dev/null
fi

i18n_print "- Extracting basic module files" "- 正在解压模块基本文件"
for file in uninstall.sh module.prop service.sh action.sh customize.sh; do
  unzip -oq "$ZIPFILE" "$file" -d "$MODPATH"
done

# 检查并停止运行中的进程
if [ -d "$AGH_DIR" ]; then
i18n_print "- Stopping AdGuardHome and its additional processes" "- 正在终止AdGuardHome及附加进程"
# 用 pkill -f 按命令行匹配，避免遍历 /proc/*/cmdline 时命中已退出进程
# 产生 "can't open /proc/<pid>/cmdline: No such file or directory" 噪声
for i in 1 2 3; do
    found=0
    for pat in "$AGH_DIR/bin/AdGuardHome" "$AGH_DIR/bin/dnsenc" "$AGH_DIR/scripts/" "/usr/local/lib/smartdns/smartdns" "chroot $AGH_DIR/smartdns"; do
        if pgrep -f "$pat" >/dev/null 2>&1; then
            pkill -9 -f "$pat" 2>/dev/null
            found=1
        fi
    done
    [ "$found" -eq 0 ] && break
    sleep 1
done
# 卸载SmartDNS chroot挂载点
for m in dev proc sys tmp run; do
    umount "$AGH_DIR/smartdns/$m" 2>/dev/null
done
fi

# 删除被锁定的残留文件（POSIX sh：不使用 process substitution / local）
if [ -f "$AGH_DIR/scripts/NoAdsService.sh" ]; then
    i18n_print "- Removing locked residual files" "- 正在删除被锁定的残留文件"
    c=0
    u=0
    BLOCK_PATHS=/data/local/tmp/.agh_block_paths.$$
    BLOCK_FILES=/data/local/tmp/.agh_block_files.$$
    grep 'block_ad' "$AGH_DIR/scripts/NoAdsService.sh" | grep -o '".*"' | tr -d '"' > "$BLOCK_PATHS" 2>/dev/null
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || continue
        find "$p" \( -type f -o -type d \) > "$BLOCK_FILES" 2>/dev/null
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            c=$((c+1))
            if [ -d "$f" ]; then
                if lsattr -d "$f" 2>/dev/null | grep -q "i-"; then
                    chattr -i "$f" 2>/dev/null && rmdir "$f" 2>/dev/null && u=$((u+1))
                fi
            else
                if lsattr "$f" 2>/dev/null | grep -q "i-"; then
                    chattr -i "$f" 2>/dev/null && rm -f "$f" 2>/dev/null && u=$((u+1))
                fi
            fi
        done < "$BLOCK_FILES"
    done < "$BLOCK_PATHS"
    rm -f "$BLOCK_PATHS" "$BLOCK_FILES" 2>/dev/null
    i18n_print "- Removed $u locked files out of $c scanned items" "- 从 $c 个文件中删除了 $u 个锁定文件"
fi

# 检查是否首次安装
if [ -d "$AGH_DIR" ]; then
  i18n_print "- Backing up configuration" "- 正在备份配置文件"
  mkdir -p "$BACKUP_DIR"
  [ -f "$BIN_DIR/AdGuardHome.yaml" ] && cp -f "$BIN_DIR/AdGuardHome.yaml" "$BACKUP_DIR/"
  [ -f "$SCRIPT_DIR/config.prop" ] && cp -f "$SCRIPT_DIR/config.prop" "$BACKUP_DIR/"
  [ -f "$SCRIPT_DIR/NoAdsService.sh" ] && cp -f "$SCRIPT_DIR/NoAdsService.sh" "$BACKUP_DIR/"
  [ -d "$ADGPATH/rules" ] && cp -rf "$ADGPATH/rules" "$BACKUP_DIR/"
  [ -f "$ADGPATH/hosts/hosts" ] && cp -f "$ADGPATH/hosts/hosts" "$BACKUP_DIR/hosts" 2>/dev/null && i18n_print "- Backed up module rules" "- 已备份模块规则"
fi

# 解锁脚本防篡改保护
if [ -d "$SCRIPT_DIR" ]; then
    i18n_print "- Unlocking old script files" "- 正在解锁旧脚本文件"
    find "$AGH_DIR/scripts" "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \;
fi

# 清除旧模块残留
if [ -d "$AGH_DIR/ifw" ] || [ -d "$AGH_DIR/scripts" ] || [ -d "$BIN_DIR/agh_pid" ] || [ -d "$BIN_DIR/data/filters" ]; then
  i18n_print "- Cleaning up old module residues" "- 正在清理旧模块残留"
  rm -rf "$AGH_DIR/ifw" "$AGH_DIR/scripts" "$BIN_DIR/agh_pid" "$BIN_DIR/data/filters"
fi

# 创建目录并解压文件
mkdir -p "$AGH_DIR" "$BIN_DIR" "$SCRIPT_DIR" "$BACKUP_DIR"

# 卸载时 uninstall.sh 会把用户数据搬到 /data/adb/agh-uninstalled-<时间>/ 保留下来。
# 若是卸载后重装（BACKUP_DIR 为空），自动把最新快照灌回 BACKUP_DIR，
# 让后面的“恢复原有配置”逻辑照常生效，用户不必手动搬文件。
restore_uninstall_snapshot() {
    [ -f "$BACKUP_DIR/AdGuardHome.yaml" ] && return 0    # 已有备份，无需快照
    _snap=""
    for _d in /data/adb/agh-uninstalled-*; do
        [ -d "$_d" ] || continue
        if [ -z "$_snap" ] || [ "$_d" \> "$_snap" ]; then _snap="$_d"; fi
    done
    [ -n "$_snap" ] || return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    # 快照里的 backup/ 就是原来的 BACKUP_DIR 内容。
    # 逐个复制而不是 cp -rf 整个，避免把 v19 起已移除的 iptables-DROP规则.txt 带回来。
    if [ -d "$_snap/backup" ]; then
        for _bf in "$_snap"/backup/*; do
            [ -e "$_bf" ] || continue
            case "$(basename "$_bf")" in
                iptables-DROP*) continue ;;
                rules)
                    mkdir -p "$BACKUP_DIR/rules" 2>/dev/null
                    for _rf in "$_bf"/*; do
                        [ -f "$_rf" ] || continue
                        case "$(basename "$_rf")" in
                            iptables-DROP*) continue ;;
                        esac
                        cp -f "$_rf" "$BACKUP_DIR/rules/" 2>/dev/null
                    done
                    ;;
                *)
                    if [ -d "$_bf" ]; then
                        cp -rf "$_bf" "$BACKUP_DIR/" 2>/dev/null
                    else
                        cp -f "$_bf" "$BACKUP_DIR/" 2>/dev/null
                    fi
                    ;;
            esac
        done
    fi
    [ -f "$_snap/AdGuardHome.yaml" ] && cp -f "$_snap/AdGuardHome.yaml" "$BACKUP_DIR/AdGuardHome.yaml" 2>/dev/null
    if [ -d "$_snap/smartdns-etc" ]; then
        mkdir -p "$BACKUP_DIR/smartdns" 2>/dev/null
        cp -rf "$_snap/smartdns-etc/." "$BACKUP_DIR/smartdns/" 2>/dev/null
    fi
    if [ -d "$_snap/rules" ]; then
        mkdir -p "$BACKUP_DIR/rules" 2>/dev/null
        for _f in "$_snap"/rules/*; do
            [ -f "$_f" ] || continue
            case "$(basename "$_f")" in
                iptables-DROP*) continue ;;
            esac
            cp -f "$_f" "$BACKUP_DIR/rules/" 2>/dev/null
        done
    fi
    [ -f "$_snap/hosts/hosts" ] && cp -f "$_snap/hosts/hosts" "$BACKUP_DIR/hosts" 2>/dev/null
    i18n_print "- Restored user data from $_snap" "- 已从卸载快照恢复用户数据：$_snap"
    return 0
}
restore_uninstall_snapshot
i18n_print "- Extracting AdGuardHome files" "- 正在解压 AdGuardHome 文件"
unzip -oq "$ZIPFILE" "scripts/*" -d "$AGH_DIR"
# 脚本同时落到模块目录（KernelSU 卸载/管理页都按模块目录找）
# webui 必须每次都从 zip 解出来：$MODPATH 下的旧副本会覆盖 $AGH_DIR 里的新文件
# 历史 bug：这里只解了 sd-restart.sh / iptables.sh 两个文件，模块目录里没有
# certs_install.sh / vpn_dns_sync.sh / ModuleMOD.sh / ProxyConfig.sh / sni_filter.awk /
# config.prop —— cgi-bin/certs 的 `$MODDIR/scripts/certs_install.sh` 那条路径恒假，
# 只能靠 $AGH_DIR 兜底；模块目录也就不是自包含的。现在整包 scripts/* 都解。
unzip -oq "$ZIPFILE" "scripts/*" -d "$MODPATH" 2>/dev/null
chmod 755 "$MODPATH"/scripts/*.sh 2>/dev/null
chmod 644 "$MODPATH"/scripts/config.prop "$MODPATH"/scripts/sni_filter.awk 2>/dev/null
chmod 755 "$MODPATH"/scripts/webui/cgi-bin/* 2>/dev/null
unzip -oq "$ZIPFILE" "bin/*" -d "$AGH_DIR"
chmod 755 "$MODPATH"/bin/AdGuardHome "$MODPATH"/bin/aghmitm "$MODPATH"/bin/dnsenc 2>/dev/null
mkdir -p "$BIN_DIR/data" "$MODPATH/rules" "$MODPATH/rules/subscriptions"
# 数据目录里的规则目录改为指向模块根目录的软链接，让"我添加的规则"和
# "网络订阅下载的规则"都真实落在模块根目录里（AGH 只是通过这些路径读写它们）。
link_rules_dirs

# 升级安装：恢复用户原有 yaml（保留过滤器列表、自定义规则、端口等）
if [ -f "$BACKUP_DIR/AdGuardHome.yaml" ]; then
    cp -f "$BACKUP_DIR/AdGuardHome.yaml" "$BIN_DIR/AdGuardHome.yaml"
    i18n_print "- Restored existing configuration" "- 已保留原有配置"
fi
i18n_print "- Extracting built-in rule files to module root" "- 正在解压内置规则到模块根目录"
mkdir -p "$MODPATH/rules"
if [ -d "$BACKUP_DIR/rules" ]; then
    # 已存在用户修改过的规则：只补缺失的文件，不覆盖
    for f in "$BACKUP_DIR"/rules/*; do
        [ -f "$f" ] || continue
        n=$(basename "$f")
        case "$n" in
            iptables-DROP*) continue ;;   # v19 起该文件已移除，不再恢复
        esac
        [ -f "$MODPATH/rules/$n" ] || cp -f "$f" "$MODPATH/rules/$n"
    done
fi
unzip -oq "$ZIPFILE" "rules/*" -d "$MODPATH" >/dev/null 2>&1
for f in "$BACKUP_DIR"/rules/*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    case "$n" in
        iptables-DROP*) continue ;;       # 同上
    esac
    cp -f "$f" "$MODPATH/rules/$n" 2>/dev/null
done
# v19：旧版遗留的 iptables 指令规则文件一律清掉
rm -f "$MODPATH/rules/iptables-DROP规则.txt" 2>/dev/null
chmod 644 "$MODPATH"/rules/*.txt 2>/dev/null
# smartdns.conf 引用 adblock.conf，缺失会导致启动失败，兜底建一个空文件
if [ ! -f "$AGH_DIR/smartdns/etc/smartdns/adblock.conf" ]; then
    mkdir -p "$AGH_DIR/smartdns/etc/smartdns"
    printf '# adblock rules (optional)\n' > "$AGH_DIR/smartdns/etc/smartdns/adblock.conf" 2>/dev/null
fi
# ---- WebUI：上游服务器管理页（busybox httpd 6081 + CGI）----
i18n_print "- Extracting upstream manager (busybox httpd + CGI)" "- 正在解压上游服务器管理页"
mkdir -p "$SCRIPT_DIR/webui/cgi-bin"
# 以 zip 为准：先解到 $AGH_DIR，再用它覆盖 $SCRIPT_DIR/webui，
# 绝不能用 $MODPATH 里的旧副本回盖（历史 bug：旧版 cgi/页面永远不更新）。
rm -rf "$SCRIPT_DIR/webui"
mkdir -p "$SCRIPT_DIR/webui"
unzip -oq "$ZIPFILE" 'scripts/webui/*' -d "$AGH_DIR" >/dev/null 2>&1
if [ -d "$AGH_DIR/scripts/webui" ]; then
    cp -rf "$AGH_DIR/scripts/webui/." "$SCRIPT_DIR/webui/" 2>/dev/null
fi
if [ ! -f "$SCRIPT_DIR/webui/cgi-bin/upstream" ] && [ -d "$MODPATH/scripts/webui" ]; then
    cp -rf "$MODPATH/scripts/webui/." "$SCRIPT_DIR/webui/" 2>/dev/null
fi
# 全量赋权：cgi-bin 下所有 CGI 都要可执行。
# 历史 bug：这里只 chmod 了 upstream 一个文件，导致 certs/scripts/privacy/mitm/apps
# 装完后权限不是 755，busybox httpd 拒绝执行 → 前端拿到 404/空响应
# （表现为「证书界面读取证书失败」「脚本页空列表」）。
chmod 755 "$SCRIPT_DIR/webui/cgi-bin"/* 2>/dev/null
chmod 644 "$SCRIPT_DIR/webui"/*.html 2>/dev/null
# 校验关键 CGI 是否齐全，缺一个就明确记日志（装机时能在 magisk 安装日志里看到）
for _c in privacy privacy-page certs scripts mitm apps upstream; do
    if [ ! -f "$SCRIPT_DIR/webui/cgi-bin/$_c" ]; then
        ui_print "- WARN: CGI missing after install: $_c"
    fi
done
chmod 644 "$SCRIPT_DIR/webui/upstream-manage.html" 2>/dev/null

# 自检脚本也装一份到设备：升级后可以随时 `sh /data/adb/agh/tests/full_check.sh` 体检，
# 不用再从电脑推。缺这个文件时 full_check 会跳过 6081 那组断言（不阻断）。
unzip -oq "$ZIPFILE" 'tests/*' -d "$AGH_DIR" >/dev/null 2>&1
chmod 755 "$AGH_DIR/tests"/*.sh 2>/dev/null

# 上游管理页也放一份到 smartdns 静态站根：手机直接访问 6080/upstream-manage.html 也能打开
# 同一份管理页也放进 SmartDNS 真实部署目录，手机上直接访问 6080/upstream-manage.html 也能开
SD_WWW="$AGH_DIR/smartdns/usr/share/smartdns/wwwroot"
if [ -f "$SCRIPT_DIR/webui/upstream-manage.html" ] && [ -d "$SD_WWW" ]; then
    cp -f "$SCRIPT_DIR/webui/upstream-manage.html" "$SD_WWW/upstream-manage.html" 2>/dev/null
    chmod 644 "$SD_WWW/upstream-manage.html" 2>/dev/null
fi

i18n_print "- Extracting local hosts file" "- 正在解压本地 hosts 文件"
mkdir -p "$MODPATH/hosts"
if [ -f "$ADGPATH/hosts/hosts" ]; then
    cp -f "$ADGPATH/hosts/hosts" "$MODPATH/hosts/hosts" 2>/dev/null
fi
if [ -f "$BACKUP_DIR/hosts" ]; then
    cp -f "$BACKUP_DIR/hosts" "$MODPATH/hosts/hosts" 2>/dev/null
fi
unzip -oq "$ZIPFILE" "hosts/*" -d "$MODPATH" >/dev/null 2>&1
if [ -f "$BACKUP_DIR/hosts" ]; then
    cp -f "$BACKUP_DIR/hosts" "$MODPATH/hosts/hosts" 2>/dev/null
fi
chmod 644 "$MODPATH/hosts/hosts" 2>/dev/null

# ---- 证书目录 ----
# $MODDIR/certs 同时被三处使用：certs 管理页（cgi-bin/certs）、开机 service.sh 里的
# certs_install.sh、以及 system/etc/security/cacerts 的 overlay 源头。
# 旧版 customize.sh 从没把 certs/ 解到 $MODPATH，安装末尾那次 certs_install 调用因为
# 找不到脚本被静默跳过，重刷后模块目录里没有 certs/ → 系统 CA overlay 丢失、证书页空。
# 这里补上，并且用「旧目录优先」覆盖：设备上已生成的 CA 一旦被包内模板顶掉，
# 之前装过这张 CA 的 App/系统信任库就全部失效。
i18n_print "- Extracting built-in CA / cert store" "- 正在解压内置证书"
mkdir -p "$MODPATH/certs"
if [ -d "$ADGPATH/certs" ] && [ ! "$ADGPATH" = "$MODPATH" ]; then
    cp -rf "$ADGPATH/certs/." "$MODPATH/certs/" 2>/dev/null
fi
unzip -oq "$ZIPFILE" "certs/*" -d "$MODPATH" >/dev/null 2>&1
if [ -d "$ADGPATH/certs" ] && [ ! "$ADGPATH" = "$MODPATH" ]; then
    cp -rf "$ADGPATH/certs/." "$MODPATH/certs/" 2>/dev/null
fi
chmod 644 "$MODPATH"/certs/*.crt 2>/dev/null
chmod 600 "$MODPATH"/certs/*.key 2>/dev/null
# 安装阶段的 CA 注入：脚本本体只解到 $AGH_DIR/scripts，$MODPATH/scripts 里没有它，
# 所以两个位置都试，MODDIR 始终指向正在安装的 $MODPATH。
_cert_installer=""
for _ci in "$MODPATH/scripts/certs_install.sh" "$AGH_DIR/scripts/certs_install.sh"; do
    [ -f "$_ci" ] && { _cert_installer="$_ci"; break; }
done
if [ -n "$_cert_installer" ]; then
    MODDIR="$MODPATH" sh "$_cert_installer" 2>&1 | while read -r _l; do ui_print "$_l"; done
else
    ui_print "- WARN: certs_install.sh not found, CA overlay skipped"
fi

# 升级前备份用户的 SmartDNS 配置（含自加的上游服务器），解压后恢复
SD_ETC="$AGH_DIR/smartdns/etc/smartdns"
SD_BAK="$BACKUP_DIR/smartdns"
if [ -d "$SD_ETC" ]; then
    mkdir -p "$SD_BAK" 2>/dev/null
    for f in servers.conf adblock.conf encrypted.conf smartdns.conf domain-rules.conf; do
        [ -f "$SD_ETC/$f" ] && cp -f "$SD_ETC/$f" "$SD_BAK/$f" 2>/dev/null
    done
fi

i18n_print "- Extracting SmartDNS chroot files" "- 正在解压 SmartDNS 文件"

# SmartDNS UI 数据库目录必须是持久可写目录（data-dir 指向这里）。
# 装完立刻建好，避免首次启动时 UI 建库失败 → 报「服务器请求处理已暂停」。
for _sdv in "var/lib/smartdns" "var/cache/smartdns" "var/log/smartdns"; do
    mkdir -p "$AGH_DIR/smartdns/$_sdv" 2>/dev/null
done
chown 9999:9999 "$AGH_DIR/smartdns/var/lib/smartdns" "$AGH_DIR/smartdns/var/cache/smartdns" 2>/dev/null
chmod 755 "$AGH_DIR/smartdns/var/lib/smartdns" "$AGH_DIR/smartdns/var/cache/smartdns" 2>/dev/null
unzip -oq "$ZIPFILE" "smartdns/*" -d "$AGH_DIR"

# 恢复用户配置：
#  servers.conf  -> 合并：用户自加的全部保留，包内默认上游缺的补上（升级能拿到新上游）
#  adblock.conf  -> 用户文件优先，绝不覆盖
#  smartdns.conf -> 只有备份里已用 conf-file 结构时才恢复，避免旧格式覆盖新模板
if [ -d "$SD_BAK" ]; then
    if [ -s "$SD_BAK/servers.conf" ]; then
        cp -f "$SD_BAK/servers.conf" "$SD_ETC/servers.conf.merged" 2>/dev/null
        # 把包内模板里的 server 行逐条比对，缺的追加
        if [ -f "$SD_ETC/servers.conf" ]; then
            grep -E '^[[:space:]]*server(-tls|-https|-udp|-tcp)?[[:space:]]' "$SD_ETC/servers.conf" 2>/dev/null \
            | sed 's/^[[:space:]]*//' | while IFS= read -r dl; do
                [ -n "$dl" ] || continue
                if ! grep -qxF "$dl" "$SD_ETC/servers.conf.merged" 2>/dev/null; then
                    printf '%s\n' "$dl" >> "$SD_ETC/servers.conf.merged"
                fi
            done
        fi
        cat "$SD_ETC/servers.conf.merged" > "$SD_ETC/servers.conf" 2>/dev/null
        rm -f "$SD_ETC/servers.conf.merged" 2>/dev/null
        chmod 644 "$SD_ETC/servers.conf" 2>/dev/null
    fi
    if [ -s "$SD_BAK/adblock.conf" ]; then
        cp -f "$SD_BAK/adblock.conf" "$SD_ETC/adblock.conf" 2>/dev/null
        chmod 644 "$SD_ETC/adblock.conf" 2>/dev/null
    fi
    if [ -s "$SD_BAK/smartdns.conf" ] && grep -q 'servers.conf' "$SD_BAK/smartdns.conf" 2>/dev/null; then
        cp -f "$SD_BAK/smartdns.conf" "$SD_ETC/smartdns.conf" 2>/dev/null
        chmod 644 "$SD_ETC/smartdns.conf" 2>/dev/null
    fi
    # 加密上游：用户改过的优先，绝不覆盖
    if [ -s "$SD_BAK/encrypted.conf" ]; then
        cp -f "$SD_BAK/encrypted.conf" "$SD_ETC/encrypted.conf" 2>/dev/null
        chmod 644 "$SD_ETC/encrypted.conf" 2>/dev/null
    fi
    # 按域名分流规则：用户改过的优先；用户没动过则用包内新模板（含新增默认规则）
    if [ -s "$SD_BAK/domain-rules.conf" ] && grep -q '^[[:space:]]*domain-rules[[:space:]]' "$SD_BAK/domain-rules.conf" 2>/dev/null; then
        cp -f "$SD_BAK/domain-rules.conf" "$SD_ETC/domain-rules.conf" 2>/dev/null
        chmod 644 "$SD_ETC/domain-rules.conf" 2>/dev/null
    fi
fi

# 加密上游转发列表（由 service.sh / 管理页生成，安装时先清成空模板）
printf '# 由 service.sh 自动生成，请勿手改。\n' > "$SD_ETC/enc-servers.conf" 2>/dev/null
chmod 644 "$SD_ETC/enc-servers.conf" 2>/dev/null
if [ -f "$SD_ETC/smartdns.conf" ] && ! grep -q 'enc-servers\.conf' "$SD_ETC/smartdns.conf" 2>/dev/null; then
    echo "conf-file /etc/smartdns/enc-servers.conf" >> "$SD_ETC/smartdns.conf"
fi
i18n_print "- Setting permissions" "- 设置权限"
find "$AGH_DIR" -type d -exec chmod 0700 {} \;
# SmartDNS chroot 树需要常规读/执行权限（musl loader 读 /lib）
chmod -R 755 "$AGH_DIR/smartdns"
chmod +x "$BIN_DIR/AdGuardHome"
[ -f "$BIN_DIR/dnsenc" ] && chmod 755 "$BIN_DIR/dnsenc"
chmod +x "$SCRIPT_DIR"/*.sh
chown root:net_raw "$BIN_DIR/AdGuardHome"

# 执行脚本防篡改保护
i18n_print "- Locking script files" "- 正在锁定脚本文件"
find "$SCRIPT_DIR" -type f -name "*.sh" -exec chattr +i {} \;

# 迁移旧版规则路径：userfilters -> 模块根目录 rules/
if [ -f "$BIN_DIR/AdGuardHome.yaml" ]; then
    if grep -q "/data/adb/agh/bin/data/userfilters/" "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null; then
        i18n_print "- Migrating rule paths to module root" "- 正在把规则路径迁移到模块根目录"
        sed -i "s|/data/adb/agh/bin/data/userfilters/|/data/adb/modules/AdGuardHome/rules/|g" "$BIN_DIR/AdGuardHome.yaml"
    fi
    normalize_safe_fs
    ensure_sni_filter
fi

# v19：iptables 加固功能已移除，把 yaml 里指向 rules/iptables-DROP规则.txt 的过滤器条目
# 和 user_rules 里的 #!iptables 指令一并清掉（否则 AGH 会因找不到文件而报错）
if [ -f "$BIN_DIR/AdGuardHome.yaml" ] \
    && { grep -q 'iptables-DROP' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null \
         || grep -q '#!iptables' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null; }; then
    i18n_print "- Removing obsolete iptables rule entries" "- 正在清理已移除的 iptables 规则条目"
    Y="$BIN_DIR/AdGuardHome.yaml"
    YT="$Y.v19.$$"
    awk '
        function flush_block() {
            if (blk == "") return
            if (blk !~ /iptables-DROP/ && blk !~ /#!iptables/) printf "%s", blk
            blk = ""
        }
        /^  - / { flush_block(); blk = $0 "\n"; next }
        /^[[:space:]]/ { blk = blk $0 "\n"; next }
        { flush_block(); print }
        END { flush_block() }
    ' "$Y" > "$YT" 2>/dev/null && cat "$YT" > "$Y" 2>/dev/null
    rm -f "$YT" 2>/dev/null
    # 规则文件本体也一并删除（该文件只含 #!iptables 指令，已无用途）
    rm -f "$RULES_ROOT/iptables-DROP规则.txt" 2>/dev/null
fi

# 规则只保留模块根目录一份：清掉旧位置的重复副本。
# 注意：data/userfilters 此时已是指向 rules/ 的软链接，若仍是实体目录才清理，
# 否则会误删模块根目录里的正式规则文件。
if [ ! -L "$BIN_DIR/data/userfilters" ] && [ -f "$BIN_DIR/AdGuardHome.yaml" ] \
    && grep -q "/data/adb/modules/AdGuardHome/rules/" "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null; then
    rm -f "$BIN_DIR/data/userfilters/iptables-DROP规则.txt" "$BIN_DIR/data/userfilters/myallow.txt" 2>/dev/null
fi

# 清理旧版「iptables 加固」子系统（v19 起该功能已整体移除）留下的规则链
if iptables -w 2 -t filter -L AGH_HARDEN >/dev/null 2>&1 || \
   ip6tables -w 2 -t filter -L AGH_HARDEN6 >/dev/null 2>&1; then
    i18n_print "- Removing legacy iptables hardening chains" "- 正在清理旧版 iptables 加固规则链"
    while iptables -w 2 -t filter -D OUTPUT -j AGH_HARDEN 2>/dev/null; do :; done
    iptables -w 2 -t filter -F AGH_HARDEN 2>/dev/null
    iptables -w 2 -t filter -X AGH_HARDEN 2>/dev/null
    while ip6tables -w 2 -t filter -D OUTPUT -j AGH_HARDEN6 2>/dev/null; do :; done
    ip6tables -w 2 -t filter -F AGH_HARDEN6 2>/dev/null
    ip6tables -w 2 -t filter -X AGH_HARDEN6 2>/dev/null
fi

# 正在保留配置文件
[ -f "$BACKUP_DIR/config.prop" ] && \
old_line=$(grep -m1 '^PROXY_URL=' "$BACKUP_DIR/config.prop") && \
[ -n "$old_line" ] && { sed -i "/^PROXY_URL=/d" "$SCRIPT_DIR/config.prop"; printf "%s\n" "$old_line" >> "$SCRIPT_DIR/config.prop"; i18n_print "- Preserved PROXY_URL from backup" "- 已从备份恢复 PROXY_URL"; }
# VPN 共存选择也要跟着升级保留，否则每次刷入都会被重置回 auto
for _k in vpn_compat vpn_apps v6_dns agh_user agh_pass sd_user sd_pass redir_port panel_lan_only; do
    [ -f "$BACKUP_DIR/config.prop" ] || break
    _kv=$(grep -m1 "^[[:space:]]*$_k=" "$BACKUP_DIR/config.prop" 2>/dev/null)
    [ -n "$_kv" ] || continue
    sed -i "/^[[:space:]]*$_k=/d" "$SCRIPT_DIR/config.prop" 2>/dev/null
    [ -n "$(tail -c 1 "$SCRIPT_DIR/config.prop" 2>/dev/null)" ] && printf "\n" >> "$SCRIPT_DIR/config.prop"
    printf "%s\n" "$_kv" >> "$SCRIPT_DIR/config.prop"
    i18n_print "- Preserved $_k from backup" "- 已从备份恢复 $_k"
done
# 重新锁定模块目录脚本，防止被篡改
# 只锁不该被就地修改的脚本；service.sh / customize.sh 必须保持可覆盖，
# 否则升级时 unzip 报 Operation not permitted、模块永远停在旧版安装逻辑。
find "$ADGPATH" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null
# 模块目录里的文件一律不加 immutable：KernelSU/Magisk 应用更新时要把旧目录整棵
# rm -rf 再搬 modules_update 进来，只要有一个 +i（含目录上的 I 标志）就删不动，
# 表现是「包刷进去了、重启后还是旧版」。真机复现：scripts/webui/cgi-bin 带 I 标志，
# 模块一直停在 11-25 的旧构建。防篡改只锁 $SCRIPT_DIR（不在模块目录里）。
for _f in "$SCRIPT_DIR"/*.sh; do
    [ -f "$_f" ] && chattr +i "$_f" 2>/dev/null
done

# 保证上游列表文件存在（SmartDNS 网页「上游服务器 → 添加上游服务器」可编辑）
if [ -f "$AGH_DIR/smartdns/etc/smartdns/smartdns.conf" ] \
    && [ ! -f "$AGH_DIR/smartdns/etc/smartdns/servers.conf" ]; then
    grep -E '^[[:space:]]*server[[:space:]]' "$AGH_DIR/smartdns/etc/smartdns/smartdns.conf" 2>/dev/null \
        | sed 's/^[[:space:]]*//' > "$AGH_DIR/smartdns/etc/smartdns/servers.conf"
    sed -i '/^[[:space:]]*server[[:space:]]/d' "$AGH_DIR/smartdns/etc/smartdns/smartdns.conf" 2>/dev/null
fi
# 自愈：旧版 sed 守卫会把 domain-rules.conf 里的文档示例行（含 →）误取消注释，
# smartdns 遇到那种行会直接报错并放弃加载整份配置。这里按行内容特征修回来。
for _df in "$AGH_DIR/smartdns/etc/smartdns/domain-rules.conf" \
           "$MODPATH/smartdns/etc/smartdns/domain-rules.conf"; do
    [ -f "$_df" ] && sed -i "/^[[:space:]]*domain-rules .*→/s/^/#/" "$_df" 2>/dev/null
done
# ---- update.json 随包装到两个位置 ----
# 1) $AGH_DIR/update.json：自检（full_check 版本三处一致）和开机脚本读的是这份；
# 2) 模块根 update.json：KernelSU/Magisk 管理器「检查更新」直接读它。
# 历史 bug：包里 update.json 已改，但运行目录那份是几版前手工留下的，
# 自检永远报「update.json version≠模块」，看着像发版漏了，其实是没同步。
if [ -f "$MODPATH/update.json" ]; then
    cp -f "$MODPATH/update.json" "$AGH_DIR/update.json" 2>/dev/null
    mkdir -p /data/adb/modules/AdGuardHome 2>/dev/null
    cp -f "$MODPATH/update.json" /data/adb/modules/AdGuardHome/update.json 2>/dev/null
    chmod 644 "$AGH_DIR/update.json" 2>/dev/null
fi

i18n_print "- Installation complete. Reboot device." "- 安装完成，请重启设备。"

# ---- 系统级 CA（HTTPS / MITM）：注入已在解压 certs/ 后执行过一次，这里不再重复 ----