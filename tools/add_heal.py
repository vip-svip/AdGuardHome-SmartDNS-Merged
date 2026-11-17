import io, hashlib
SVC = r"F:\BUG\AdguardHome-Magisk\Adguardhome\service.sh"
CFG = r"F:\BUG\AdguardHome-Magisk\Adguardhome\scripts\config.prop"
CUS = r"F:\BUG\AdguardHome-Magisk\Adguardhome\customize.sh"

s = io.open(SVC, encoding="utf-8").read()

FUNC = r'''
# ---------------------------------------------------------------
# 过滤器自愈：全新安装 / 升级后 rules/subscriptions 被清空时，AGH 不会主动
# 重新下载（要等 filters_update_interval 到期），表现是「装了模块但广告照样弹」。
# 这里在「所有过滤器 rules_count 全为 0」时用本地 API 触发一次刷新。
# 凭据取 scripts/config.prop 的 agh_user / agh_pass（默认 root/root）。
# ---------------------------------------------------------------
agh_filter_heal() {
    command -v curl >/dev/null 2>&1 || return 0
    _port=$(awk '/^http:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*address:/{print $2;exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null)
    _port=${_port##*:}
    [ -n "$_port" ] || _port=40251
    _u=$(sed -n 's/^[[:space:]]*agh_user=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    _p=$(sed -n 's/^[[:space:]]*agh_pass=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    [ -n "$_u" ] || _u=root
    [ -n "$_p" ] || _p=root
    _ck="/data/local/tmp/.agh_ck.$$"
    _lc=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -c "$_ck" \
          -H "Content-Type: application/json" \
          -d "{\"name\":\"$_u\",\"password\":\"$_p\"}" \
          "http://127.0.0.1:$_port/control/login" 2>/dev/null)
    if [ "$_lc" != "200" ]; then
        rm -f "$_ck"
        [ "$lang" = "zh" ] && log "[WARN] 无法登录 AGH API（HTTP ${_lc:-无}，改 config.prop 的 agh_user/agh_pass），跳过过滤器自愈。" \
                           || log "[WARN] AGH API login failed (HTTP ${_lc:-none}); set agh_user/agh_pass in config.prop to enable filter self-heal."
        return 0
    fi
    _total=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null \
             | tr ',' '\n' | awk -F: '/rules_count/{gsub(/[^0-9]/,"",$2); s+=$2} END{print s+0}')
    if [ "${_total:-0}" -eq 0 ]; then
        _ids=$(awk '/^filters:/{f=1;next} f&&/^[^[:space:]-]/{exit} f&&/^[[:space:]]+id:/{gsub(/[^0-9]/,"",$2); printf "%s,", $2}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/,$//')
        if [ -z "$_ids" ]; then
            rm -f "$_ck"
            return 0
        fi
        _r=$(curl -s -m 180 -b "$_ck" -H "Content-Type: application/json" \
             -d "{\"whitelist\":false,\"ids\":[$_ids]}" \
             "http://127.0.0.1:$_port/control/filtering/refresh" 2>/dev/null)
        [ "$lang" = "zh" ] && log "过滤器缓存为空，已触发重新下载：${_r:-无响应}" \
                           || log "Filter caches were empty; triggered a fresh download: ${_r:-no response}"
        _after=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null \
                 | tr ',' '\n' | awk -F: '/rules_count/{gsub(/[^0-9]/,"",$2); s+=$2} END{print s+0}')
        [ "$lang" = "zh" ] && log "过滤器自愈完成，规则总数 ${_after:-0}" \
                           || log "Filter self-heal done; total rules ${_after:-0}"
    else
        rm -f "$_ck"
    fi
}

agh_filter_heal
'''

anchor = "\n# ---------------------------------------------------------------\n# 启动 AdGuardHome"
i = s.find(anchor)
if i < 0:
    # 用 ASCII 段注释定位（源码里中文可能被 GBK 二次编码）
    i = s.find('if ! agh_running; then')
    assert i > 0
    # 回退到该行之前的段注释起点
    j = s.rfind('# ---------------------------------------------------------------', 0, i)
    i = j if j > 0 else i
print("insert at", i, repr(s[i:i + 80]))
s = s[:i] + FUNC + "\n" + s[i:]

# 不在 `--no-check-update &` 之后立刻调（AGH 还没监听），插到整个启动块之后
io.open(SVC, "w", encoding="utf-8", newline="\n").write(s)
raw = io.open(SVC, "rb").read()
print("service.sh", len(raw), hashlib.md5(raw).hexdigest())

# config.prop 增加凭据键
c = io.open(CFG, encoding="utf-8").read()
if "agh_user=" not in c:
    if not c.endswith("\n"):
        c += "\n"
    c += ('# AGH 本地 API 凭据：过滤器自愈（缓存为空时自动重新下载规则）要用，默认 root/root\n'
          '# 如果你在 AGH 网页里改过登录密码，把这里同步改掉，否则只会跳过自愈并记一条 WARN。\n'
          'agh_user=root\n'
          'agh_pass=root\n')
    io.open(CFG, "w", encoding="utf-8", newline="\n").write(c)
raw = io.open(CFG, "rb").read()
print("config.prop", len(raw), hashlib.md5(raw).hexdigest())

# customize.sh 升级保留也带上凭据
u = io.open(CUS, encoding="utf-8").read()
old = "for _k in vpn_compat vpn_apps; do"
assert u.count(old) == 1
u = u.replace(old, "for _k in vpn_compat vpn_apps agh_user agh_pass; do")
io.open(CUS, "w", encoding="utf-8", newline="\n").write(u)
raw = io.open(CUS, "rb").read()
print("customize.sh", len(raw), hashlib.md5(raw).hexdigest())