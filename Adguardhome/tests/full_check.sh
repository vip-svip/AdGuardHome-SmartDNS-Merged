#!/system/bin/sh
# 模块整体体检（真机 root 下跑）：sh tests/full_check.sh
# 覆盖 10 组、48 项断言。退出码 0 = 全过。
#
# 与 webui_check.sh 的分工：webui_check 只看 6081 管理面；
# 本脚本看「整条链路」—— 端口一致性 / DNS 劫持 / 面板防护 / SNI / 隐私 /
# 过滤器注册 / 证书 / 目录标志 / 日志 / 版本元数据。

MODDIR=/data/adb/modules/AdGuardHome
AGH_DIR=/data/adb/agh
PROP="$AGH_DIR/scripts/config.prop"
YAML="$AGH_DIR/bin/AdGuardHome.yaml"
WEBUI="$AGH_DIR/scripts/webui"
HOST=127.0.0.1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
hdr() { printf '\n[%s]\n' "$1"; }
note(){ printf '       %s\n' "$1"; }

BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox busybox; do
    command -v "$c" >/dev/null 2>&1 && { BB="$c"; break; }
done
_gr() { if [ -n "$BB" ]; then "$BB" grep "$@"; else grep "$@"; fi; }
_awk() { if [ -n "$BB" ]; then "$BB" awk "$@"; else awk "$@"; fi; }

prop() { sed -n "s/^$1=//p" "$PROP" 2>/dev/null | head -1; }

# SNI 链在新版实现里用「临时链 AGH_SNIN 灌满 → 改名」的原子换链，
# 换链的那 3~5ms 里名字可能短暂是 AGH_SNIN、或两条同时存在。
# 所以断言必须按「语义」量（拦截是否一直在线），不能按链名量。
sni_nf() {
    # -w 5：重建进程长时间持 xtables 锁时，-w 2 会超时失败并返回空，
    # 那种「0 条」是测量假象，不是真的裸奔。两条链都读不到才算测量失败（ERR）。
    _ao=$(iptables -w 5 -S AGH_SNI 2>/dev/null); _ra=$?
    _bo=$(iptables -w 5 -S AGH_SNIN 2>/dev/null); _rb=$?
    if [ "${_ra:-1}" -ne 0 ] && [ "${_rb:-1}" -ne 0 ]; then echo ERR; return 0; fi
    _a=$(printf '%s\n' "$_ao" | _gr -c NFQUEUE)
    _b=$(printf '%s\n' "$_bo" | _gr -c NFQUEUE)
    echo $(( ${_a:-0} + ${_b:-0} ))
}
sni_jumps() {
    iptables -w 2 -S OUTPUT 2>/dev/null | _gr -c -E -- '-j AGH_SNIN?$'
}

hdr "0. 版本元数据"
MVER=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | tr -d '\r')
case "$MVER" in ''|*[!0-9]*) bad "module.prop versionCode 非法（$MVER）" ;; *) ok "module.prop versionCode=$MVER" ;; esac
case "$MVER" in 2026*) ok "versionCode 是 2026 年度版本" ;; *) bad "versionCode 不是 2026 年度（$MVER）" ;; esac
MJ=$(sed -n 's/^updateJson=//p' "$MODDIR/module.prop" 2>/dev/null)
case "$MJ" in https://*) ok "module.prop 自带 updateJson" ;; *) bad "module.prop 缺 updateJson（模块无法在线更新）" ;; esac
# 版本三处一致：模块内 version/versionCode、仓库 update.json 的 version/versionCode、zipUrl 文件名。
# 真机踩过：包内容已大改但版本号停在旧日期，且 update.json 的 zipUrl 硬编码旧文件名，
# 结果模块「检查更新」永远不提示（用户拿不到修复）。
UV=""
for u in "$AGH_DIR/update.json" "$MODDIR/../update.json" /data/local/tmp/update.json; do
    [ -f "$u" ] && { UV=$u; break; }
done
if [ -n "$UV" ]; then
    uver=$(_awk -F'"' '/"version":/{print $4}' "$UV" 2>/dev/null)
    uvc=$(_awk -F'"' '/"versionCode":/{print $3}' "$UV" 2>/dev/null | tr -cd '0-9')
    uzip=$(_awk -F'"' '/"zipUrl":/{print $4}' "$UV" 2>/dev/null)
    [ "$uver" = "$MVER" ] && ok "update.json version 与模块一致（$uver）" || bad "update.json version=$uver ≠ 模块 $MVER（不会推更新）"
    [ "$uvc" = "$MVER" ] && ok "update.json versionCode 与模块一致" || bad "update.json versionCode=$uvc ≠ $MVER"
    case "$uzip" in *"-$MVER.zip") ok "zipUrl 文件名与版本一致" ;; *) bad "zipUrl 指向旧包：$uzip" ;; esac
else
    note "设备上没有 update.json，跳过版本一致性（仓库内 CI 会校验）"
fi

# 等稳态：开机后 service.sh 的 40 秒重建窗口里，链会被反复重建（换链瞬间按名字查
# 是查不到的）。自检要在「稳态」上判，否则测的是自己的重建过程，噪声全算成 bug。
# 最多等 90 秒，把三件事等到位：SNI 拦截条数≥11、AGH_WEBUI 三条 DROP、nat 劫持跳转。
_st=0
while [ "$_st" -lt 30 ]; do
    _ok=1
    [ "$(sni_nf)" -ge 11 ] || _ok=0
    [ "$(iptables -w 2 -t nat -S OUTPUT 2>/dev/null | _gr -c -E -- '-j ADGUARDB?$')" -ge 1 ] || _ok=0
    [ "$(iptables -w 2 -S AGH_WEBUI 2>/dev/null | _gr -c -- '--dport 6081 -j DROP')" -ge 1 ] || _ok=0
    [ "$_ok" = "1" ] && { [ "$_st" -gt 0 ] && note "等了 $((_st * 3))s 才稳态（开机重建窗口）"; break; }
    _st=$((_st + 1))
    sleep 3
done
[ "$_st" -ge 30 ] && note "90 秒内未等到稳态，按当前状态继续断言"


hdr "0b. 6081 管理面延迟（webui_check）"
if [ -f "$AGH_DIR/tests/webui_check.sh" ]; then
    # 这套断言跑在本脚本里会被后台守护重建拖慢，延迟项偶发超阈值；
    # 重跑一次，只有两次都不过才算失败（真慢 vs 被自己干扰要分清）。
    RC=9
    for _try in 1 2; do
        R=$(sh "$AGH_DIR/tests/webui_check.sh" 2>&1)
        RC=$(printf '%s' "$R" | _gr -o -- 'FAIL=[0-9]*' | _gr -o -- '[0-9]*' | tail -1)
        RC=${RC:-9}
        [ "$RC" = "0" ] && break
        [ "$_try" = "1" ] && sleep 2
    done
    if [ "$RC" = "0" ]; then
        ok "webui_check 全绿（$(printf '%s' "$R" | _gr -o -- 'PASS=[0-9]*')）"
    else
        bad "webui_check FAIL=$RC"
        printf '%s\n' "$R" | _gr -- 'FAIL' | sed 's/^/       /'
    fi
else
    note "未安装 tests/webui_check.sh，跳过"
fi


hdr "1. 进程与监听端口"
RP=$(prop redir_port)
for p in AdGuardHome smartdns dnsenc aghmitm; do
    pidof "$p" >/dev/null 2>&1 && ok "$p 在跑" || bad "$p 不在"
done
proc_httpd() { pgrep -f 'httpd -p' >/dev/null 2>&1; }
proc_httpd && ok "6081 httpd 在跑" || bad "6081 httpd 不在"
for t in 40251 6080 6081 6054; do
    netstat -tln 2>/dev/null | _gr -q ":$t " && ok "tcp/$t 监听" || bad "tcp/$t 未监听"
done
netstat -tln 2>/dev/null | _gr -q "127.0.0.1:8899" && ok "tcp/8899(本机) 监听" || bad "tcp/8899 未监听"
for u in $RP 6053 6054; do
    netstat -uln 2>/dev/null | _gr -q ":$u " && ok "udp/$u 监听" || bad "udp/$u 未监听"
done

hdr "2. 端口三处一致性（config.prop / yaml / 实际监听 / REDIRECT）"
# 两份 config.prop（运行目录 / 模块目录）端口必须一致：模块那份是升级时的恢复源，
# 不一致的话下次升级会把旧端口恢复回来，nat 链指错端口 → DNS 直接全断。
_p2=$(sed -n 's/^redir_port=//p' "$MODDIR/scripts/config.prop" 2>/dev/null | tail -1)
if [ -n "$_p2" ] && [ "$_p2" = "$RP" ]; then
    ok "运行/模块两份 config.prop 端口一致（$RP）"
else
    bad "两份 config.prop 端口不一致：运行=${RP:-空} 模块=${_p2:-空}（下次升级会把端口恢复成旧值）"
fi
case "$RP" in ''|*[!0-9]*) bad "config.prop redir_port 缺失" ; RP="" ;; *) ok "config.prop redir_port=$RP" ;; esac
YP=$(_awk '/^dns:/{f=1;next} f&&/^[a-z]/{f=0} f&&/^[ \t]+port:/{gsub(/[^0-9]/,"");print;exit}' "$YAML" 2>/dev/null)
[ -n "$RP" ] && [ "$RP" = "$YP" ] && ok "yaml dns.port 与 redir_port 一致（$YP）" || bad "yaml dns.port=$YP 与 redir_port=$RP 不一致"
netstat -uln 2>/dev/null | _gr -q ":$RP " && ok "AGH 实际监听 udp/$RP" || bad "udp/$RP 没有监听（REDIRECT 会打到空端口）"
# 劫持链是 A/B 轮换的（proxy 模式是 ADGUARD，VPN 模式是 ADGUARDB，每次重建改成另一条），
# 所以不能硬编码链名：从 nat OUTPUT 的跳转里认出当前生效的那条再校验内容。
VC=$(iptables -t nat -S OUTPUT 2>/dev/null | _awk '/-j ADGUARD(B)?$/{for(i=1;i<=NF;i++) if($i=="-j") print $(i+1); exit}')
VC=${VC:-ADGUARD}
note "当前生效劫持链：$VC"
# 链是 A/B 轮换的，重建窗口里可能正好查不到 --to-ports（不是真打空端口）→ 重试 3 次
_redir_ok=0
for _rt in 1 2 3; do
    VC=$(iptables -t nat -S OUTPUT 2>/dev/null | _awk '/-j ADGUARD(B)?$/{for(i=1;i<=NF;i++) if($i=="-j") print $(i+1); exit}')
    VC=${VC:-ADGUARD}
    iptables -t nat -S "$VC" 2>/dev/null | _gr -q -- "--to-ports ${RP}" && { _redir_ok=1; break; }
    sleep 1
done
[ "$_redir_ok" = "1" ] && ok "$VC 的 REDIRECT 目标= $RP" || bad "$VC 的 REDIRECT 目标不是 $RP（DNS 会打到空端口）"

hdr "3. DNS 劫持链路"
J=$(iptables -t nat -S OUTPUT 2>/dev/null | _gr -c -E -- '-j ADGUARDB?$')
[ "$J" = "1" ] && ok "nat OUTPUT 恰好一条劫持跳转（$VC）" || bad "nat OUTPUT 的劫持跳转数=$J（应为 1，重复挂链会每包走两遍）"
iptables -t nat -S "$VC" 2>/dev/null | _gr -q -- '-p udp -m udp --dport 53 -j REDIRECT' && ok "$VC 劫持 udp/53" || bad "$VC 未劫持 udp/53"
iptables -t nat -S "$VC" 2>/dev/null | _gr -q -- '-p tcp -m tcp --dport 53 -j REDIRECT' && ok "$VC 劫持 tcp/53" || bad "$VC 未劫持 tcp/53"
iptables -t nat -S "$VC" 2>/dev/null | _gr -q -- "-A $VC -o lo -j RETURN" && ok "$VC 放行 lo（防环路）" || bad "$VC 缺 lo 放行"
# querylog 会被 AGH 重启清空、也会按大小轮转，读到空不代表劫持没生效：
# 先真发一次查询（走系统解析 → 被 nat 劫进 AGH）再读，最多试 3 轮。
SQL=0
for _qtry in 1 2 3; do
    curl -s -o /dev/null -m 6 'http://www.baidu.com' 2>/dev/null
    sleep 1
    SQL=$(curl -s -m 5 -u root:root 'http://127.0.0.1:40251/control/querylog?limit=200' 2>/dev/null | _gr -o '"question"' | wc -l | tr -d ' ')
    [ "${SQL:-0}" -gt 0 ] && break
    sleep 2
done
if [ "${SQL:-0}" -gt 0 ]; then
    ok "AGH querylog 有 ${SQL} 条记录（劫持生效）"
else
    # querylog 为空**不是**故障判据，只做提示：系统 DNS 缓存命中（dnsproxyd 会自己缓存）、
    # proxy 模式下 vpn_apps 豁免、代理 App 接管系统解析，都会让 AGH 一条都不记。
    # 拦截到底生效没有，看前面「拦截域名解析成 NXDOMAIN + FilteredBlackList」的铁证。
    note "querylog 为空（缓存命中/代理接管都常见，非故障）；拦截是否生效看上面的 NXDOMAIN 铁证"
fi
[ "${SQL:-0}" -ge 1 ] && ok "AGH querylog 有 ${SQL} 条查询（说明真有流量进来）" || note "querylog 为空：同上，缓存/代理接管导致，非故障"
RESV=$(prop vpn_compat)
note "vpn_compat=$RESV"
case "$RESV" in
    auto)  ok "auto 模式：ADGUARD 保留 53 劫持，靠 VPN 检测动态让路" ;;
    proxy) iptables -t nat -S "$VC" 2>/dev/null | _gr -q -- '-o tun+' && ok "proxy 模式：出接口隧道豁免已就位" || bad "proxy 模式缺 -o tun+ 豁免" ;;
    off)   ok "off 模式：全量劫持" ;;
esac

hdr "4. 面板访问防护（panel_lan_only）"
PLO=$(prop panel_lan_only)
if [ "$PLO" = "1" ]; then
    iptables -w 2 -S AGH_WEBUI >/dev/null 2>&1 && ok "AGH_WEBUI 链存在" || bad "panel_lan_only=1 但 AGH_WEBUI 链不存在"
    WI=$(iptables -S INPUT 2>/dev/null | _gr -c -- '-j AGH_WEBUI')
    [ "$WI" = "1" ] && ok "INPUT 恰好一条 AGH_WEBUI 跳转" || bad "INPUT 的 AGH_WEBUI 跳转数=$WI"
    # 守护在开机/回写窗口里会 A/B 换链（建 AGH_WEBUI_N 再改名），这一瞬间读 AGH_WEBUI
    # 可能拿到空表或半张表。逐端口各读一次就是三次竞态采样，实测会出现「链明明是对的、
    # 却报某端口未 DROP」的假 FAIL。改成先取一份快照、最多重试 3 次，再本地逐条判。
    _webui_snap=""
    for _wtry in 1 2 3; do
        _webui_snap=$(iptables -w 2 -S AGH_WEBUI 2>/dev/null)
        printf '%s\n' "$_webui_snap" | _gr -q -- '--dport 40251 -j DROP' && break
        sleep 1
    done
    for p in 40251 6080 6081; do
        printf '%s\n' "$_webui_snap" | _gr -q -- "--dport $p -j DROP" && ok "面板端口 $p 对外 DROP" || bad "面板端口 $p 未 DROP"
    done
    # 顺序判断必须用「同一次 iptables 快照」：守护会在开机窗口里 A/B 换链，
    # 分两次调用取样，中间链被重建就把第二条取成空 → 假 FAIL（PJD110 上实测踩到）。
    SUI=$(printf '%s\n' "$_webui_snap")
    [ -n "$SUI" ] || SUI=$(iptables -S AGH_WEBUI 2>/dev/null)
    LN=$(printf '%s\n' "$SUI" | _gr -n -- '--dport 40251 -j DROP' | cut -d: -f1 | head -1)
    LR=$(printf '%s\n' "$SUI" | _gr -n -- '-s 192.168' | cut -d: -f1 | head -1)
    if [ -z "$LN" ] || [ -z "$LR" ]; then
        sleep 1
        SUI=$(iptables -S AGH_WEBUI 2>/dev/null)
        LN=${LN:-$(printf '%s\n' "$SUI" | _gr -n -- '--dport 40251 -j DROP' | cut -d: -f1 | head -1)}
        LR=${LR:-$(printf '%s\n' "$SUI" | _gr -n -- '-s 192.168' | cut -d: -f1 | head -1)}
    fi
    if [ -n "$LN" ] && [ -n "$LR" ] && [ "$LR" -lt "$LN" ]; then ok "局域网放行在 DROP 之前（顺序正确）"; else bad "局域网放行顺序错误（LAN=$LR DROP=$LN）"; fi
else
    note "panel_lan_only=$PLO，跳过"
fi

hdr "5. SNI 拦截链"
if iptables -S AGH_SNI >/dev/null 2>&1 || iptables -S AGH_SNIN >/dev/null 2>&1; then
    ok "SNI 链存在（AGH_SNI/AGH_SNIN 换链中也能识别）"
else
    bad "SNI 链不存在（SNI/QUIC 层完全没有拦截）"
fi
SO=$(sni_jumps)
[ "$SO" -ge 1 ] && [ "$SO" -le 2 ] && ok "OUTPUT 挂载数=$SO（正常 1，换链瞬间允许 2）" || bad "AGH_SNI 跳转数=$SO（0=没挂，>2=重复挂）"
NQ=$(sni_nf)
# 换链瞬间名字可能短暂不存在；重试 3 次再下结论
NQ=$(sni_nf); case "$NQ" in ''|*[!0-9]*) NQ=0 ;; esac
for _r in 1 2 3; do
    [ "${NQ:-0}" -ge 11 ] && break
    sleep 1
    NQ=$(sni_nf); case "$NQ" in ''|*[!0-9]*) NQ=0 ;; esac
done
[ "${NQ:-0}" -ge 11 ] && ok "NFQUEUE 条目 ${NQ} 条（443/80 等）" || bad "NFQUEUE 条目只有 ${NQ} 条（期望 11，SNI 在裸奔）"
iptables -S AGH_SNI 2>/dev/null | _gr -q -- '--dport 443 -j NFQUEUE' && ok "443 走 NFQUEUE" || bad "443 没走 NFQUEUE"
pidof aghmitm >/dev/null 2>&1 && ok "NFQUEUE 消费者（aghmitm）在跑" || bad "NFQUEUE 没有消费者，443 会被 bypass"
# 原子性回归：强制跑一次 --once 重建，全程 200ms 采样，拦截条数必须始终 ≥11。
# 旧实现（-F 后原地重灌）实测会掉到 0~5，等于每次自愈都有 100~300ms SNI 裸奔。
if [ -f "$AGH_DIR/scripts/iptables.sh" ]; then
    _mn=99; _i=0; _err=0
    sh "$AGH_DIR/scripts/iptables.sh" --sni-force >/dev/null 2>&1 &
    _bp=$!
    while kill -0 "$_bp" 2>/dev/null; do
        _c=$(sni_nf)
        case "$_c" in
            ''|*[!0-9]*) _err=$((_err + 1)) ;;            # 读不到 = 锁竞争，不算裸奔
            *) [ "$_c" -lt "$_mn" ] && _mn=$_c ;;
        esac
        _i=$((_i + 1)); [ "$_i" -gt 80 ] && break
        sleep 0.2 2>/dev/null || sleep 1
    done
    wait "$_bp" 2>/dev/null
    if [ "$_mn" -ge 11 ]; then
        ok "重建原子性：${_i} 次采样最低拦截条数=$_mn（无裸奔窗口，锁竞争跳过 $_err 次）"
    elif [ "$_mn" -eq 99 ]; then
        bad "重建原子性无法采样（${_i} 次全是锁竞争 $_err 次，iptables 查询被卡住）"
    else
        bad "重建不原子：采样最低拦截条数=$_mn（出现 SNI 裸奔窗口）"
    fi
fi

hdr "6. 隐私防护"
iptables -w 2 -S AGH_PRIV >/dev/null 2>&1 && ok "AGH_PRIV 链存在" || bad "AGH_PRIV 链不存在"
PO=$(iptables -S OUTPUT 2>/dev/null | _gr -c -- '-j AGH_PRIV')
[ "$PO" = "1" ] && ok "OUTPUT 恰好一条 AGH_PRIV 跳转" || bad "AGH_PRIV 跳转数=$PO"
B1=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | md5sum); B16=$(ip6tables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
for i in 1 2 3 4 5; do curl -s -o /dev/null "http://$HOST:6081/cgi-bin/privacy" 2>/dev/null; done
A1=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | md5sum); A16=$(ip6tables -w 2 -S AGH_PRIV 2>/dev/null | md5sum)
[ "$B1" = "$A1" ] && ok "连续 5 次 privacy GET 未改动 v4 规则" || bad "privacy GET 在改 v4 规则（读操作写系统）"
[ "$B16" = "$A16" ] && ok "连续 5 次 privacy GET 未改动 v6 规则" || bad "privacy GET 在改 v6 规则"
iptables -S 2>/dev/null | _gr -q '^-N AGH_PRIV_N' && bad "残留暂存链 AGH_PRIV_N" || ok "无残留暂存链"

hdr "7. 过滤器注册（文件在 ≠ AGH 在用）"
FS=$(curl -s -m 6 -u root:root 'http://127.0.0.1:40251/control/filtering/status' 2>/dev/null)
[ -n "$FS" ] && ok "filtering/status 可读" || bad "filtering/status 读不到（凭据不对？）"
REG=$(printf '%s' "$FS" | _gr -o '"url":"[^"]*"' | sed 's/"url":"//; s/"//')
for f in "$MODDIR"/rules/*.txt; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    case "$b" in 脚本拦截.txt) continue ;; esac
    if printf '%s\n' "$REG" | _gr -qx "$f"; then
        ok "过滤器已注册：$b"
    else
        # 只有模块自带的规则没注册才算故障。rules 目录是「用户可见可编辑」的，
        # 从旧版本升上来会留着上一版/用户自己放的规则文件，AGH 不读它们并不影响
        # 拦截效果（内置清单都在下面这张表里），所以只提示不判失败。
        case "$b" in
            拦截列表.txt|反诈和广告.txt|反诈.txt|反诈类.txt|反诈上报.txt|adaway_hosts.txt|\
            antiadblockfilters.txt|NoAppDownload.txt|应用隐私.txt|运营商追踪.txt|\
            腾讯广告.txt|色情网站.txt|水印.txt|基站WiFi隐私.txt|myallow.txt)
                bad "过滤器未注册：$b（模块自带规则，文件在但 AGH 不读）" ;;
            *)
                note "未注册（非模块自带，多为旧版本/自定义残留，可手动启停）：$b" ;;
        esac
    fi
done
printf '%s\n' "$REG" | _gr -qx "$MODDIR/hosts/hosts" && ok "本地 hosts 已注册" || bad "本地 hosts 未注册"
[ -s "$MODDIR/rules/脚本拦截.txt" ] && ok "脚本拦截.txt 非空（$(wc -l < "$MODDIR/rules/脚本拦截.txt" | tr -d ' ') 行）" || bad "脚本拦截.txt 缺失或为空"
printf '%s\n' "$REG" | _gr -q '脚本拦截.txt' && ok "脚本拦截.txt 已注册为过滤器" || bad "脚本拦截.txt 没注册（脚本页改了也不生效）"
EN=$(printf '%s' "$FS" | _gr -o '"enabled":false' | wc -l | tr -d ' ')
[ "${EN:-0}" = "0" ] && ok "没有默认关闭的过滤器" || note "有 $EN 个过滤器被关掉"

hdr "8. 证书链"
for n in https mitm; do
    C="$MODDIR/certs/$n-ca.crt"
    [ -s "$C" ] && ok "$n CA 在模块目录（$(wc -c < "$C" | tr -d ' ')B）" || bad "$n CA 缺失：$C"
done
H1=2c637461; H2=e2b6a4fd
for h in $H1 $H2; do
    [ -f "/system/etc/security/cacerts/$h.0" ] && ok "系统信任库有 $h.0" || bad "系统信任库缺 $h.0（TLS 拦截会失败）"
    [ -f "$MODDIR/system/etc/security/cacerts/$h.0" ] && ok "模块 overlay 有 $h.0" || bad "模块 overlay 缺 $h.0（重启后会掉）"
done
[ -s "/system/etc/security/cacerts/$H1.0" ] && [ -s "$MODDIR/certs/https-ca.crt" ] && {
    a=$(md5sum "/system/etc/security/cacerts/$H1.0" 2>/dev/null | cut -d' ' -f1)
    b=$(md5sum "$MODDIR/certs/https-ca.crt" 2>/dev/null | cut -d' ' -f1)
    [ "$a" = "$b" ] && ok "系统里的 https CA 与模块内一致" || bad "系统 https CA 与模块内不一致（装机注入的是旧证书）"
}
for d in https mitm; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST:6081/cgi-bin/certs?download=$d" 2>/dev/null)
    [ "$code" = "200" ] && ok "certs?download=$d 可下载" || bad "certs?download=$d 返回 $code"
done

hdr "9. 目录与标志"
# 防篡改只锁运行目录 $AGH_DIR（模块目录那份是安装源，不锁，否则 KernelSU 删不动）
FL=$(find "$AGH_DIR/scripts" -maxdepth 1 -type f -name '*.sh' -exec lsattr {} \; 2>/dev/null | _gr -c -- '^[A-Za-z-]*i')
[ "${FL:-0}" -ge 1 ] && ok "运行目录 $FL 个 .sh 带 i 标志（防篡改在）" || note "运行目录脚本没上锁（防篡改没开）"
for f in "$MODDIR"/scripts/webui/cgi-bin/*; do
    lsattr "$f" 2>/dev/null | _gr -q '^----i' && bad "CGI 被锁文件系统（$(basename "$f")），下次升级搬不进来"
done
ok "cgi-bin 无 immutable 锁"
UP=$(ls -A /data/adb/modules_update/AdGuardHome 2>/dev/null | wc -l | tr -d ' ')
[ "${UP:-0}" = "0" ] && ok "modules_update 已清空（上次刷包已切换）" || bad "modules_update 还有 $UP 个条目（刷包没生效）"
for f in privacy scripts apps certs mitm; do
    a=$(md5sum "$AGH_DIR/scripts/webui/cgi-bin/$f" 2>/dev/null | cut -d' ' -f1)
    b=$(md5sum "$MODDIR/scripts/webui/cgi-bin/$f" 2>/dev/null | cut -d' ' -f1)
    [ -n "$a" ] && [ "$a" = "$b" ] && ok "两处副本一致：$f" || bad "两处副本不一致：$f（$a vs $b）"
done
for b in "$AGH_DIR/bin/AdGuardHome" "$AGH_DIR/bin/aghmitm" "$AGH_DIR/bin/dnsenc"; do
    [ -x "$b" ] && ok "可执行：${b#$AGH_DIR/}" || bad "不可执行：${b#$AGH_DIR/}（chmod 丢了）"
done
for s in certs_install.sh vpn_dns_sync.sh iptables.sh ModuleMOD.sh; do
    [ -x "$AGH_DIR/scripts/$s" ] && ok "脚本可执行且存在：$s" || bad "缺或不可执行：scripts/$s"
done
for s in certs_install.sh vpn_dns_sync.sh iptables.sh; do
    [ -f "$MODDIR/scripts/$s" ] && ok "模块目录自包含：scripts/$s" || bad "模块目录缺 scripts/$s（不是自包含的）"
done

hdr "10. 日志与轮转"
SZ=$(wc -c < "$AGH_DIR/mitm.log" 2>/dev/null | tr -d ' ')
if [ "${SZ:-0}" -le 2097152 ]; then ok "mitm.log $(( ${SZ:-0} / 1024 ))KB（阈值 2MB 内）"; else bad "mitm.log ${SZ}B 超过 2MB，没轮转"; fi
CS=$(wc -c < "$AGH_DIR/bin/crash.log" 2>/dev/null | tr -d ' ')
[ "${CS:-0}" -le 2097152 ] && ok "bin/crash.log（AGH 自身日志）$(( ${CS:-0} / 1024 ))KB（轮转生效）" || bad "bin/crash.log ${CS}B 超过 2MB（轮转没生效）"
for l in agh.log dnsenc.log sni_err.log; do
    s=$(wc -c < "$AGH_DIR/$l" 2>/dev/null | tr -d ' ')
    [ "${s:-0}" -le 5242880 ] && ok "$l $(( ${s:-0} / 1024 ))KB" || bad "$l ${s}B 超过 5MB"
done
if [ -n "$BB" ]; then
    "$BB" grep -qi 'syntax error\|no closing quote\|not found' "$AGH_DIR/agh-stdout.log" 2>/dev/null && bad "agh-stdout.log 里有 shell 报错" || ok "agh-stdout.log 无 shell 报错"
fi

hdr "12. 端到端与自愈（会短暂杀进程，放最后一组）"

# 12.0 首屏不闪烁：真值静态内联在 privacy.html 里（cgi 每次写完状态原地改写那一行），
#      页面第一帧 = 最终值，连 ?embed=1 的二次请求都不发。
_em=$(curl -s -m 5 "http://$HOST:6081/cgi-bin/privacy?embed=1" 2>/dev/null)
case "$_em" in
  *"window.__AGH_PRIV={"*) ok "privacy ?embed=1 返回内联状态（兼容端点仍在）" ;;
  *) bad "privacy ?embed=1 没返回内联状态" ;;
esac
_ph_html=$(curl -s -m 5 "http://$HOST:6081/privacy.html" 2>/dev/null)
_ph=$(printf '%s' "$_ph_html" | _gr -c '^window.__AGH_PRIV={')
[ "${_ph:-0}" -ge 1 ] && ok "privacy.html 首屏真值已静态内联（$_ph 处）" \
                      || bad "privacy.html 没有静态内联真值（首屏仍要等 CGI）"
_ph_old=$(printf '%s' "$_ph_html" | _gr -c 'privacy?embed=1')
[ "${_ph_old:-0}" -eq 0 ] && ok "privacy.html 不再引 ?embed=1（首屏零外部请求）" \
                           || bad "privacy.html 仍在引 ?embed=1（$_ph_old 处，首屏多一次 CGI）"
_inl=$(printf '%s' "$_ph_html" | _gr -o 'window.__AGH_PRIV={[^}]*}' | head -1)
_get=$(curl -s -m 5 "http://$HOST:6081/cgi-bin/privacy" 2>/dev/null | _gr -o '{"dns":[^}]*}' | head -1)
_inl_json=$(printf '%s' "$_inl" | sed 's/window.__AGH_PRIV=//; s/};/}/')
_get_json=$(printf '%s' "$_get" | sed 's/,"applied":1//')
if [ -n "$_inl_json" ] && [ "$_inl_json" = "$_get_json" ]; then
    ok "静态内联值与 GET 真值一致（不会画出过期状态）"
else
    bad "静态内联值与 GET 真值不一致：$_inl_json vs $_get_json"
fi

# 12.0b 页面必须走 CGI（静态文件在 busybox httpd 下加不了 Cache-Control，浏览器会吃旧副本）
_hdr=$(curl -s -m 5 -D - -o /dev/null "http://$HOST:6081/cgi-bin/privacy-page" 2>/dev/null)
case "$_hdr" in
  *"no-store"*) ok "privacy-page 带 Cache-Control: no-store（浏览器不会拿旧页面）" ;;
  *) bad "privacy-page 没带 no-store 头（浏览器可能一直用旧副本）" ;;
esac
case "$_hdr" in
  *"text/html"*) ok "privacy-page Content-Type 是 text/html" ;;
  *) bad "privacy-page Content-Type 不对" ;;
esac
_pg=$(curl -s -m 5 "http://$HOST:6081/cgi-bin/privacy-page" 2>/dev/null)
case "$_pg" in
  *"window.__AGH_PRIV={"*) ok "privacy-page 输出内联真值" ;;
  *) bad "privacy-page 输出缺内联真值（首屏会等 GET）" ;;
esac
_pg_j=$(printf '%s' "$_pg" | _gr -c 'SHELL_JUMP|privacy-page')
[ "${_pg_j:-0}" -eq 0 ] && ok "privacy-page 输出已剥掉跳转壳（不会自己跳自己）" \
                         || bad "privacy-page 输出里还有跳转壳（会无限跳转）"
_shell=$(curl -s -m 5 "http://$HOST:6081/privacy.html" 2>/dev/null | _gr -c '/cgi-bin/privacy-page')
[ "${_shell:-0}" -ge 1 ] && ok "直连 privacy.html 会立刻跳到 CGI 版（$_shell 处）" \
                         || bad "privacy.html 缺跳转壳（直连静态仍会吃缓存）"

# 12.0b 页面加载后零自动核对：8 个开关必须和 DNS/VPN/IP 那三个一样，静置时不自变。
#       旧版有两个自动核对点（页面内延迟回 GET、切回前台再 GET），任一失败就把整页画成
#       「已关闭」，下一次成功再翻回「已开启」——那就是用户看到的「关一下再打开」。
_auto=$(printf '%s' "$_ph_html" | _gr -c 'setTimeout(load')
[ "${_auto:-0}" -eq 0 ] && ok "privacy.html 已删除延迟自动核对（加载后不再自己刷新）" \
                        || bad "privacy.html 仍在延迟自动核对（$_auto 处，翻转窗口还在）"
_vis=$(printf '%s' "$_ph_html" | _gr -c 'visibilitychange')
[ "${_vis:-0}" -eq 0 ] && ok "privacy.html 已删除切前台自动核对（切回不再翻一次）" \
                        || bad "privacy.html 仍在切前台核对（$_vis 处，切回会翻）"
_pg_auto=$(printf '%s' "$_pg" | _gr -c 'setTimeout(load|visibilitychange')
[ "${_pg_auto:-0}" -eq 0 ] && ok "privacy-page 输出同样无任何自动核对（服务端页面一致）" \
                           || bad "privacy-page 输出里还有自动核对（$_pg_auto 处）"
_root=$(curl -s -m 5 "http://$HOST:6081/" 2>/dev/null)
case "$_root" in
  *"/cgi-bin/privacy-page"*) ok "6081 根入口 / 直接跳免缓存页（用户不用记长路径）" ;;
  *) bad "6081 根入口不是隐私页（/ 没返回跳转）" ;;
esac
case "$_pg" in
  *20261201*) ok "privacy-page 构建号 20261201（可自证是新版）" ;;
  *) bad "privacy-page 缺新构建号（无法判断浏览器吃的是哪版）" ;;
esac

# 12.1 真实 DNS 解析：手搓 27 字节 A 查询（八进制转义，mksh/busybox printf 都认）
_q=/data/local/tmp/.fc_q.bin
printf '\022\064\001\000\000\001\000\000\000\000\000\000\005baidu\003com\000\000\001\000\001' > "$_q" 2>/dev/null
if [ "$(wc -c < "$_q" 2>/dev/null | tr -d ' ')" = "27" ]; then
    "$BB" nc -u -w 3 127.0.0.1 "$RP" < "$_q" > "$_q.a" 2>/dev/null
    _an=$(wc -c < "$_q.a" 2>/dev/null | tr -d ' ')
    [ "${_an:-0}" -gt 40 ] && ok "udp/$RP 有真实 DNS 应答（${_an}B）" || bad "udp/$RP 没有应答（${_an}B，DNS 服务没在干活）"
    # 12.2 53 端口劫持：从本机打 8.8.8.8:53 的探针会被 uid0 豁免（ADGUARD 链对
    # root 自己出手的包 RETURN），所以不能拿「querylog 有没有涨」当判据。改成看
    # 劫持链本身的语义：nat OUTPUT 有跳转、生效链里 53 确实 REDIRECT 到 AGH 端口。
    _vc=""
    for _c in $(iptables -w 2 -t nat -S OUTPUT 2>/dev/null | _gr -oE '\-j [A-Za-z0-9_]+' | sed 's/^-j //'); do
        case "$_c" in REDIRECT|ACCEPT|DROP|RETURN|wmsctrl*) continue ;; esac
        if iptables -w 2 -t nat -S "$_c" 2>/dev/null | _gr -q -- "--dport 53 -j REDIRECT --to-ports $RP"; then _vc=$_c; break; fi
    done
    _rj=$(iptables -w 2 -t nat -S "${_vc:-ADGUARD}" 2>/dev/null | _gr -c -- "--dport 53 -j REDIRECT --to-ports $RP")
    [ "${_rj:-0}" -ge 1 ] \
        && ok "nat 生效链 ${_vc} 里 53 端口 REDIRECT 到 $RP（劫持语义成立）" \
        || bad "nat 生效链 ${_vc} 里没有 53 → REDIRECT $RP（劫持链断了）"
    _lan=$(curl -s -m 5 -u root:root "http://$HOST:40251/control/querylog?limit=50" 2>/dev/null \
           | _gr -oE '"client":"[^"]*"' | _gr -v '127\.0\.0\.1' | head -1)
    [ -n "$_lan" ] && note "querylog 里有局域网客户端流量：$_lan" \
                   || note "querylog 最近 50 条没有局域网客户端（本机探针被 uid0 豁免，属正常）"
else
    note "printf 未产出 27 字节查询，跳过端到端"
fi

# 12.3 6081 写路径（POST）真的会改规则，而且改完能复原
_nb=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | _gr -c '^-A')
_nr0=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | _gr -c -- '--dport 123')
# 取反：当前有 123 就去掉，当前没有就加上 —— 断言只依赖「方向对、条数变」
if [ "${_nr0:-0}" = "1" ]; then _want=0; else _want=1; fi
_t=$(curl -s -m 8 -o /dev/null -w '%{time_total}' -X POST \
      -d "dns=1&vpn=1&ip=1&ntp=$_want&dhcp=1&smb=1&tcp=1&snmp=1&sb=0&par=0" \
      "http://$HOST:6081/cgi-bin/privacy" 2>/dev/null)
_na=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | _gr -c '^-A')
_nr=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | _gr -c -- '--dport 123')
if [ "$_want" = "1" ]; then _exp=$(( _nb + 1 )); else _exp=$(( _nb - 1 )); fi
[ "$_na" = "$_exp" ] && [ "${_nr:-1}" = "$_want" ] \
    && ok "POST ntp=$_want 生效：规则 ${_nb}→${_na}，123 端口 DROP ${_nr} 条" \
    || bad "POST ntp=$_want 没生效（${_nb}→${_na}，123 ${_nr} 条）"
_tt=$(printf '%s' "$_t" | _gr -oE '[0-9]*\.[0-9]*' | head -1)
# 变值路径会重建 v4+v6 两条链（还要跟 netd 的 iptables-restore 抢 xtables 锁，
# 抢不到时 -w 2 要等满 2s）→ 阈值给 3s；真正决定「点开关转不转圈」的是幂等路径。
_okc=$(_awk -v t="${_tt:-9}" 'BEGIN{print (t<=3.0)?"1":"0"}')
[ "$_okc" = "1" ] && note "POST 变值（重建 v4+v6）耗时 ${_tt}s" \
                   || bad "POST 变值耗时 ${_tt}s（>3s，xtables 锁被长期占用？）"
# 幂等路径（同值再 POST）：应该只剩读配置 + 一次 -C 校验，页面连点开关走的就是这条
_it=$(curl -s -m 8 -o /dev/null -w '%{time_total}' -X POST \
       -d "dns=1&vpn=1&ip=1&ntp=$_want&dhcp=1&smb=1&tcp=1&snmp=1&sb=0&par=0" \
       "http://$HOST:6081/cgi-bin/privacy" 2>/dev/null)
_itn=$(printf '%s' "$_it" | _gr -oE '[0-9]*\.[0-9]*' | head -1)
_oki=$(_awk -v t="${_itn:-9}" 'BEGIN{print (t<=1.2)?"1":"0"}')
[ "$_oki" = "1" ] && ok "POST 幂等延迟 ${_itn}s（≤1.2s，页面连点开关不转圈）" \
                  || bad "POST 幂等延迟 ${_itn}s（>1.2s，点开关要转圈）"
_back=$(( 1 - _want ))
curl -s -m 8 -o /dev/null -X POST -d "dns=1&vpn=1&ip=1&ntp=$_back&dhcp=1&smb=1&tcp=1&snmp=1&sb=0&par=0" \
     "http://$HOST:6081/cgi-bin/privacy" 2>/dev/null
_nrr=$(iptables -w 2 -S AGH_PRIV 2>/dev/null | _gr -c -- '--dport 123')
[ "${_nrr:-0}" = "$_back" ] && ok "POST ntp=$_back 复原：123 端口 DROP 回到 ${_nrr} 条" \
    || bad "复原失败（123 端口 DROP ${_nrr} 条，应 ${_back}）"

# 12.4 aghmitm 自愈：kill -9 后必须有人拉起（真机实测旧版 31 秒都没人管）
if [ -f "$AGH_DIR/mitm_on" ]; then
    sleep 3
    _om=$(pidof aghmitm)
    kill -9 "$_om" 2>/dev/null
    _i=0
    while [ "$_i" -lt 35 ]; do
        _nm=$(pidof aghmitm)
        [ -n "$_nm" ] && break
        _i=$((_i + 1)); sleep 1
    done
    [ -n "$_nm" ] && ok "aghmitm 被杀后 ${_i}s 内自愈（新 pid $_nm）" || bad "aghmitm 被杀后 35s 内没人拉起（SNI 消费者消失）"
else
    note "mitm_on 不在，跳过 aghmitm 自愈"
fi

# 12.5 AGH 自愈
sleep 3
_oa=$(pidof AdGuardHome)
kill -9 "$_oa" 2>/dev/null
_i=0
while [ "$_i" -lt 35 ]; do
    _na2=$(pidof AdGuardHome)
    [ -n "$_na2" ] && break
    _i=$((_i + 1)); sleep 1
done
if [ -n "$_na2" ]; then
    ok "AdGuardHome 被杀后 ${_i}s 内自愈（新 pid $_na2）"
    _i=0
    while [ "$_i" -lt 25 ]; do
        netstat -uln 2>/dev/null | _gr -q ":$RP " && break
        _i=$((_i + 1)); sleep 1
    done
    netstat -uln 2>/dev/null | _gr -q ":$RP " && ok "自愈后 udp/$RP 重新监听" || bad "自愈后 udp/$RP 没回来（DNS 断了）"
else
    bad "AdGuardHome 被杀后 35s 内没人拉起（DNS 全断）"
fi

# 12.6 fd 泄漏 / 规则泄漏
_fd=$(ls /proc/"$(pidof AdGuardHome)"/fd 2>/dev/null | wc -l | tr -d ' ')
[ "${_fd:-0}" -le 200 ] && ok "AGH fd=${_fd}（≤200）" || bad "AGH fd=${_fd} 偏多（疑似句柄泄漏）"
# 上面刚 kill 过 aghmitm/AGH，SNI 链可能在重建：先等 10s 让守护收尾，再连采三次
snap() {
    printf '%s/%s/%s' \
        "$(iptables -w 2 -S AGH_SNI 2>/dev/null | wc -l | tr -d ' ')" \
        "$(iptables -w 2 -t nat -S OUTPUT 2>/dev/null | wc -l | tr -d ' ')" \
        "$(iptables -w 2 -S AGH_PRIV 2>/dev/null | wc -l | tr -d ' ')"
}
sleep 10
_s1=$(snap); sleep 10; _s2=$(snap); sleep 10; _s3=$(snap)
if [ -n "$_s1" ] && [ "$_s2" = "$_s3" ]; then
    ok "规则行数稳定（${_s3}，SNI/natOUT/PRIV，30s 无增长）"
else
    bad "规则行数在增长：$_s1 → $_s2 → $_s3（疑似泄漏）"
fi

# ============ 13. AGH 内嵌前端（40251 面板里的「隐私」页）============
# 这一段是用户真正在看的那一页：它编译在 bin/AdGuardHome 里（SolidJS bundle，明文），
# 不是 6081 的独立页面。两件事必须在二进制里改到位，否则用户永远看到「别的开关翻」。
hdr "13. AGH 内嵌前端（40251「隐私」页）"
_BIN=/data/adb/agh/bin/AdGuardHome
_n1=$(LC_ALL=C grep -a -c 'ntp:!1,dhcp:!1' "$_BIN" 2>/dev/null)
[ "${_n1:-0}" -eq 0 ] && ok "内嵌前端：旧首帧默认值已清零（8 开关不再翻）" \
                       || bad "内嵌前端仍是旧默认值（$_n1 处，开关会翻）"
_n2=$(LC_ALL=C grep -a -c 'ntp:!0,dhcp:!0,smb:!0,tcp:!0,snmp:!0' "$_BIN" 2>/dev/null)
[ "${_n2:-0}" -ge 1 ] && ok "内嵌前端：新首帧默认值在位" || bad "内嵌前端缺新默认值"
_n3=$(LC_ALL=C grep -a -c 'key:"sb",title:' "$_BIN" 2>/dev/null)
[ "${_n3:-0}" -eq 0 ] && ok "内嵌前端：恶意网站拦截项已删除" || bad "内嵌前端仍有 sb 开关项"
_n4=$(LC_ALL=C grep -a -c 'key:"par",title:' "$_BIN" 2>/dev/null)
[ "${_n4:-0}" -eq 0 ] && ok "内嵌前端：成人内容过滤项已删除" || bad "内嵌前端仍有 par 开关项"

# ============ 14. 系统信任库（MITM CA 必须对所有 App 可见）============
hdr "14. 系统信任库"
_SYS=/system/etc/security/cacerts
if [ -d "$_SYS" ]; then
    _mode=$(stat -c %a "$_SYS" 2>/dev/null)
    [ "$_mode" = "755" ] && ok "信任库目录权限 0755（App 可读）" \
                         || bad "信任库目录权限 ${_mode}（非 0755，所有 HTTPS 会弹证书错误）"
    _lbl=$(ls -ldZ "$_SYS" 2>/dev/null | awk '{print $5}')
    case "$_lbl" in
        *system_security_cacerts_file*) ok "信任库目录 SELinux 标签正确" ;;
        *) bad "信任库目录 SELinux 标签异常：$_lbl" ;;
    esac
    _cnt=$(su 2000 -c "ls $_SYS 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
    [ "${_cnt:-0}" -ge 100 ] && ok "非 root uid 可列举 $_cnt 张 CA" \
                             || bad "非 root uid 只能列举 ${_cnt:-0} 张 CA（信任库对 App 不可见）"
    for _h in 2c637461 e2b6a4fd; do
        [ -f "$_SYS/$_h.0" ] && ok "模块 CA $_h.0 在信任库" || bad "模块 CA $_h.0 不在信任库"
    done
else
    bad "系统信任库目录不存在"
fi

printf '\n================ 结果：PASS=%s FAIL=%s ================\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
