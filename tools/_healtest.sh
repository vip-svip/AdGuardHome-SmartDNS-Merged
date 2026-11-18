#!/system/bin/sh
AGH_DIR=/data/adb/agh
BIN_DIR=$AGH_DIR/bin
SCRIPT_DIR=$AGH_DIR/scripts
ADGPATH=/data/adb/modules/AdGuardHome
MODULES_DIR=/data/adb/modules
lang=zh
HAVE_CURL=1
LOG=/data/local/tmp/_heal.log
: > "$LOG"
log() { echo "$*" >> "$LOG"; }
agh_filter_heal() {

    if [ "${HAVE_CURL:-1}" != "1" ]; then
        log "[WARN] 本机没有 curl，跳过过滤器自愈（请手动在 6081/80 管理页刷新）。"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || return 0
    _port=$(awk '/^http:/{f=1;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*address:/{print $2;exit}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null)
    _port=${_port##*:}
    [ -n "$_port" ] || _port=40251
    _u=$(sed -n 's/^[[:space:]]*agh_user=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    _p=$(sed -n 's/^[[:space:]]*agh_pass=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    [ -n "$_u" ] || _u=root
    [ -n "$_p" ] || _p=root
    _ck="/data/local/tmp/.agh_ck.$$"
    # AGH 刚起来时 /control/* 路由可能还没注册完（首次启动实测返回
    # "404 page not found"，随后让整个自愈流程空转），所以这里轮询到登录成功。
    _lc=""
    _i=0
    while [ "$_i" -lt 20 ]; do
        _lc=$(curl -s -m 6 -o /dev/null -w '%{http_code}' -c "$_ck" \
              -H "Content-Type: application/json" \
              -d "{\"name\":\"$_u\",\"password\":\"$_p\"}" \
              "http://127.0.0.1:$_port/control/login" 2>/dev/null)
        [ "$_lc" = "200" ] && break
        _i=$((_i + 1))
        sleep 1
    done
    if [ "$_lc" != "200" ]; then
        rm -f "$_ck"
        [ "$lang" = "zh" ] && log "[WARN] 无法登录 AGH API（HTTP ${_lc:-无}，改 config.prop 的 agh_user/agh_pass），跳过过滤器自愈。" \
                           || log "[WARN] AGH API login failed (HTTP ${_lc:-none}); set agh_user/agh_pass in config.prop to enable filter self-heal."
        return 0
    fi
    # 模块自带的拦截列表：没注册就先注册（不联网也能生效，装完立刻有拦截）
    _st=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null)
    _bl="$ADGPATH/rules/拦截列表.txt"
    if [ -f "$_bl" ] && ! printf '%s' "$_st" | grep -q '拦截列表\.txt'; then
        curl -s -m 120 -b "$_ck" -H "Content-Type: application/json" \
             -d "{\"data\":{\"name\":\"内置拦截列表\",\"url\":\"$_bl\",\"enabled\":true},\"url\":\"$_bl\",\"whitelist\":false}" \
             "http://127.0.0.1:$_port/control/filtering/add_url" >/dev/null 2>&1
        [ "$lang" = "zh" ] && log "已注册模块内置拦截列表：$_bl" \
                           || log "Registered the bundled blocklist: $_bl"
        _st=$(curl -s -m 15 -b "$_ck" "http://127.0.0.1:$_port/control/filtering/status" 2>/dev/null)
    fi
    _total=0
    if [ "${_total:-0}" -eq 0 ]; then
        _ids=$(awk '/^filters:/{f=1;next} f&&/^[^[:space:]-]/{exit} f&&/^[[:space:]]+id:/{gsub(/[^0-9]/,"",$2); printf "%s,", $2}' "$BIN_DIR/AdGuardHome.yaml" 2>/dev/null | sed 's/,$//')
        if [ -z "$_ids" ]; then
            rm -f "$_ck"
            return 0
        fi
        _r=""
        _i=0
        while [ "$_i" -lt 3 ]; do
            _r=$(curl -s -m 180 -b "$_ck" -H "Content-Type: application/json" \
                 -d "{\"whitelist\":false,\"ids\":[$_ids]}" \
                 "http://127.0.0.1:$_port/control/no_such_route" 2>/dev/null)
            # 路由未就绪时 busybox/AGH 会回 "404 page not found"，重试即可
            case "$_r" in
                *'"updated"'*) break ;;
            esac
            _i=$((_i + 1))
            sleep 2
        done
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
echo "--- log ---"
cat "$LOG"
