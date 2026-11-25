#!/system/bin/sh
AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
YAML_FILE="$BIN_DIR/AdGuardHome.yaml"
MODDIR="/data/adb/modules/AdGuardHome"
SD_CONF="/data/adb/agh/smartdns/etc/smartdns/smartdns.conf"

echo "等待 1 秒..."
echo "刷新页面以查看更改。"
sleep 1

# 获取 Web UI 端口：http 段的 address 行（0.0.0.0:PORT / [::]:PORT / 127.0.0.1:PORT 都能匹配）
PORT=$(awk '/^http:/{f=1;next} /^[^[:space:]]/{f=0} f&&/^[[:space:]]+address:[[:space:]]/{print;exit}' "$YAML_FILE" 2>/dev/null \
       | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')

# 兜底 1：yaml 里任意 address 行
if [ -z "$PORT" ]; then
    PORT=$(sed -n 's/.*address:[[:space:]]*[^:]*:\([0-9][0-9]*\).*/\1/p' "$YAML_FILE" 2>/dev/null | head -n1)
fi

# 兜底 2：从运行中进程的实际监听端口取
if [ -z "$PORT" ]; then
    PORT=$(netstat -ltnp 2>/dev/null | grep -i 'AdGuardHome' | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]].*/\1/p' | head -n1)
fi

if [ -z "$PORT" ]; then
    echo "错误：未能解析到 AdGuard Home Web UI 端口。"
    echo "yaml 中的 address 行："
    grep -n 'address:' "$YAML_FILE" 2>/dev/null
    echo "当前监听端口："
    netstat -ltn 2>/dev/null | grep -E 'LISTEN' | head -n 20
    exit 1
fi

echo "Web UI 端口：$PORT"
echo "打开：http://127.0.0.1:$PORT"
LAN_IP=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.\/]*\) .*/\1/p' | head -1 | cut -d/ -f1)
if [ -n "$LAN_IP" ]; then
    echo "打开：http://$LAN_IP:$PORT （局域网地址，部分隐私浏览器禁 localhost 就用这个）"
    echo "本机地址：http://127.0.0.1:$PORT"
    am start -a android.intent.action.VIEW -d "http://$LAN_IP:$PORT"
else
    am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT"
fi
echo "SmartDNS 管理 UI: http://127.0.0.1:6080 (账号 root/root)"
echo "上游服务器管理:  http://127.0.0.1:6081/upstream-manage.html"`necho "隐私防护设置:    http://127.0.0.1:6081/privacy.html"
echo "内置规则目录:    $MODDIR/rules"
echo "本地 hosts 文件: $MODDIR/hosts/hosts"
echo "smartdns 主配置: $SD_CONF   (上游在 servers.conf)"

