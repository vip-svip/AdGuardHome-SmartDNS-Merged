# AdGuard Home + SmartDNS 合并 Magisk / KernelSU 模块

一个把 **AdGuard Home（去广告 + 查询日志 + 面板）** 与 **SmartDNS（缓存 + 分流 + 最快 IP 测速）**
串成一条链的 Android 模块，并额外提供一个自建的**加密上游桥**，让这套内置的 SmartDNS 也能用
DoH / DoT / DoQ 上游。

```
应用 → AGH:53（nat 劫持）→ SmartDNS:6053 → dnsenc:6054 → 加密上游（DoH / DoT / DoQ）
                              └─ 明文上游组（UDP 53）
```

- **作者**：vip-svip
- **许可证**：见 `LICENSE.txt`（AdGuard Home 与 SmartDNS 各自的上游许可）
- 本仓库为**私密仓库**，仅作自用存档与版本管理。
- **版本号规则：纯日期**（`YYYYMMDD`，如 `20261117`），不再带 `vNN` 序号。
  `module.prop` 的 `version` 与 `versionCode` 同为一个日期整数，Release 的 tag 也是它。
  同日多次改动按同日覆盖（重新打包 + 重新上传附件），跨日才升版本号。

---

## 目录结构

| 路径 | 内容 |
|---|---|
| `module/` | 可直接打包刷入的模块文件树（`module.prop` / `customize.sh` / `service.sh` / `bin/` / `smartdns/` / `scripts/`） |
| `src/` | AdGuard Home 源码（基于上游 `v1.0.0-b.2` 的 DNS 层 + 自建 `cmd/dnsenc`） |
| `tools/` | 本次改造用到的构建 / 打补丁脚本 |

`module/bin/AdGuardHome`、`module/bin/dnsenc`、`module/smartdns/usr/local/lib/smartdns/smartdns`
都是**已编译好的 arm64 二进制**，所以仓库克隆下来就能直接 zip 刷入。

---

## 关键组件

### 1. dnsenc（加密上游桥）

`module/bin/dnsenc` 是个小 Go 程序，监听 `127.0.0.1:6054`（UDP + TCP 普通 DNS），
把查询转发给配置里的加密上游，取第一个成功答复。

**为什么需要它**：本模块内置的 SmartDNS 是官方 `aarch64-linux-all` 动态版，
**没有编译 TLS**，`server-tls` / `server-https` 写进去只会显示 Unknown、延迟恒 0。
所以改用本地桥：SmartDNS 只把 `127.0.0.1:6054` 当成一条普通上游。

配置：`module/smartdns/etc/smartdns/encrypted.conf`，一行一条：

```
doh https://223.5.5.5/dns-query
dot 223.5.5.5
doq dns.alidns.com
```

协议别名：`doh` / `doh3`(`h3`) / `dot`(`tls`) / `doq`(`quic`) / `dnscrypt`(`sdns`) / `udp` / `tcp`；
裸地址默认当 DoT。也可以直接写 `https://…`、`tls://…`、`quic://…`、`sdns://…`。

### 2. 按域名分流

`module/smartdns/etc/smartdns/domain-rules.conf`：

```
domain-rules /google.com/ -nameserver enc
domain-rules /example.com/ -nameserver default
domain-rules /ads.example/ -nameserver block
```

加密组带 `-group enc -exclude-default-group`，**没被点名的域名不会多等一次 DoH 握手**。

### 3. 上游管理页（:6081）

`module/scripts/webui/upstream-manage.html` + CGI `cgi-bin/upstream`，由 busybox httpd 提供：

- 明文上游增删（3 个实测最快的国内公共 DNS）
- 加密上游增删 + 延迟探测 + 重启转发
- 按域名分流规则增删
- 清空缓存 / 重启 SmartDNS

入口在 **SmartDNS 面板「上游服务器」页刷新按钮右边**（`＋ 上游服务器`），
AdGuard Home 侧栏里没有这个入口。

管理页里还有三张运维卡片：

- **VPN 共存**：`vpn_compat=auto|proxy|off`。`auto` 检测到隧道接口就把 v4 劫持让路给 VPN；
  `proxy` 始终劫持，但豁免 `-o lo`、六种隧道出接口（`tun/tap/ppp/utun/wg/ipsec`）与 VPN 应用自身 uid。
- **IPv6 DNS**：`v6_dns=auto|redirect|drop|keep`（语义见下面「已修复的坑」）。
- **按域名分流**：直接写 `domain-rules`。

---

## 内置拦截列表

`module/rules/拦截列表.txt`（~3.8MB / 168574 个域名，来自 StevenBlack/hosts + anti-ad easylist，
构建脚本 `tools/build_adlist.py`）随模块一起安装，`service.sh` 的 `agh_filter_heal()` 会在启动后
自动把它注册进 AdGuard Home。这样做是因为：远程过滤器在部分网络下长期下载不到（AGH 的过滤器
下载走它自己的 dnsforward，和 `curl` 不是同一条路径），表现为「装了模块照样弹广告」。

**必须是 AdGuard 原生 ABP 语法 `||domain^`。** 同样的域名换成 hosts 语法 `0.0.0.0 domain` 时，
`filtering/status` 里 `rules_count` 照样显示 168574，但 `check_host` 全部 `NotFilteredNotFound`
—— 只统计不匹配，极易误判成「已加载成功」。

---

## 实测延迟（Redmi / MIUI 14 / Android 13 / 3GB，2026-11-19）

用户视角只看 AdGuard Home 自己记的 `elapsedMs`（`/control/querylog`，一次正常使用后的 800 条）：

| 类型 | n | median | p90 | p99 | max | mean |
|---|---|---|---|---|---|---|
| A | 565 | **0.5 ms** | 2.2 | 208.6 | 2151.4 | 11.2 |
| AAAA | 235 | **0.7 ms** | 3.3 | 48.4 | 515.3 | 5.2 |
| 全部 | 800 | **0.5 ms** | 2.8 | 208.2 | 2151.4 | 9.4 |

端到端（`curl -w %{time_namelookup}`）：

- 热查（`www.baidu.com` ×10）：**4.3 – 6.1 ms**
- 冷查（10 个从未问过的域名，先 `POST /control/cache_clear` + 删 `smartdns.cache` + 重启 smartdns）：
  `cpan.org 1.149s` / `ctan.org 0.168s` / `suckless.org 0.467s` / `cat-v.org 0.758s` /
  `plan9foundation.org 0.677s` / `tuhs.org 0.598s` / `nokia.com 0.104s`，其余 3 个 NXDOMAIN（0）

**冷查那 0.1–1.2 秒不是本模块的。** 交叉 A/B（每组换一批全新域名、每次清持久缓存并重启实例、A/B 顺序对调）：

| 对比 | 先测组（冷） | 后测组（已热） |
|---|---|---|
| 走本机 6053 vs 裸问 223.5.5.5 | 6053 **1534 ms** 均值 | 裸 223 **57 ms** |
| 反序（同一批域名换顺序） | 裸 223 **1187 ms** 均值 | 6053 **28 ms** |

同一批域名**谁先测谁慢** —— 慢的是上游 ISP 递归对生僻域名的首次解析，本机栈只占 1.3 倍以内。

被反复怀疑、实测排掉的三件事（都是交叉 A/B，不是单次抽样）：

| 变量 | 结论 |
|---|---|
| `speed-check-mode ping` vs `none` | 噪声大于差异（真实站点三组交叉：谁先测谁慢；两边都热时 ping **38.4 ms** / none **38.6 ms**）。保留 `ping`：它给 IP 做质量挑选，热查零代价 |
| 明文上游 3 个 vs 2 个 | 同条件差 2.5 倍，全是域名差异，上游数量不是决定性变量 |
| 全局上游再加两条 IP 直连 DoH | 冷 310.5 → 267.9、热 174.3 → 81.9，同样被顺序污染主导，**没有稳定收益**（所以没加进全局） |

私有网段的 PTR 现在由 `smartdns/adblock.conf` 本地秒回（`10.in-addr.arpa` / `168.192` / `172.16-31` / `254.169` / `d.f.ip6.arpa` / `8-b.e.f.ip6.arpa`），
实测 17–30 ms → 7–15 ms，收益只有 10–20 ms；公网 PTR 不受影响。

---

## 加密上游改成 IP 直连（省掉 bootstrap）

`smartdns/etc/smartdns/encrypted.conf` 现在只有两行：

```
doh https://223.5.5.5/dns-query
doh https://1.12.12.12/dns-query
```

理由：IP 直连不需要先解析主机名，于是完全不依赖 bootstrap。`dnsenc -probe -probe-name www.python.org` 实测：

| 写法 | bootstrap | 首查 |
|---|---|---|
| `doh https://dns.alidns.com/dns-query` | `180.184.1.1` | **6386 ms** |
| `doh https://dns.alidns.com/dns-query` | `223.5.5.5` | 133 ms |
| `doh https://1.12.12.12/dns-query` | 不需要 | **180 ms** |
| `doh https://223.5.5.5/dns-query` | 不需要 | 314 ms |

改前 enc 组（`domain-rules.conf` 里 18 条 `-nameserver enc` 的域名）被这个 bootstrap 拖死，实测
`www.python.org` **1700 ms**（普通链路 260）/ `www.rust-lang.org` **4880**（390）/
`www.cloudflare.com` **1090**（260）/ `www.github.com` **720**（210）；
改后 6054 稳态 `www.python.org` 160–460 ms、`www.github.com` 120–130 ms。

**bootstrap 这个 IP 必须在三处完全一致，改一处就会形成 nat 环**：
`service.sh` 的 `DNSENC_BOOTSTRAP`、`scripts/iptables.sh` 的 `DNSENC_BOOTSTRAP`（同时用 `DNSENC_BOOTSTRAP_IP`
建 `--uid-owner 0 -d <IP> --dport 53 -j RETURN` 豁免）、`bin/AdGuardHome.yaml` 的 `bootstrap_dns`。
2026-11 起统一为 `119.28.28.28`（实测 50/80 ms）。原来的 `180.184.1.1` 已废：
ICMP 只有 28 ms，但 DNS 查询要 0.3–15.5 秒 —— **能 ping 通不代表 DNS 可用**。

---

## 已修复的坑（都是真机复现过的）

| 问题 | 原因 | 修法 |
|---|---|---|
| SmartDNS 面板报**「服务器请求处理已暂停，请检查是否有足够的磁盘空间」**，所有查询被丢弃 | UI 的 sqlite 库 `smartdns.db` 建在 `data-dir`，而 `data-dir` 原本是 chroot 内 tmpfs（`/tmp/smartdns`）。开机时目录不存在 → 建库失败 → `statvfs` 返回 0 → `is_process_suspended=true` | `data-dir` 改到持久目录 `/var/lib/smartdns`；`service.sh` 每次启动前建目录 + `chown 9999:9999` + `chmod 755`，老配置自动迁移；起来后查 `/api/stats/overview` 自愈；清缓存不再删 `data-dir` 本身 |
| 卸载后整个 `/data/adb/agh` 与模块目录被清空，用户配置全丢 | `uninstall.sh` 末尾无条件 `rm -rf` 两个目录 | 卸载前把 yaml / 备份 / SmartDNS 配置 / 规则 / hosts 快照到 `/data/adb/agh-uninstalled-<时间>/`，日志写 `/data/adb/agh-uninstall.log`；重装时 `customize.sh` 自动取最新快照灌回 |
| 模块目录会莫名消失（别的模块被牵连） | `service.sh` 发现别的模块带 `system/etc/hosts` 就 `touch "$module/remove"`，让 KernelSU 下次开机把**用户自己的**模块删掉 | 改为只记 `[WARN]`，不删除、继续启动 |
| `service.sh` 出现多个实例，下次开机单实例锁误判「已在运行」直接退出 | `pgrep … \|\| script &` 让整条 `\|\|` 列表进了子 shell，cmdline 仍是 `sh service.sh` | 改 `start_helper()` + `setsid`；锁改 `mkdir` 原子锁 + `trap … EXIT` |
| webui 装完永远是旧版（`ruleslist` 报「未知 action」） | `customize.sh` 只要 `$MODPATH/scripts/webui` 存在就 `cp -rf` 回盖，而那是最早的旧副本 | 每次从 zip 解 `scripts/webui/*` 到 `$AGH_DIR`，反向复制；`$MODPATH` 只作兜底 |
| `adb push` 报 `Operation not permitted`，卸载时 `uninstall.sh` 自己被锁 | `chattr +i` 锁了全部 `*.sh` | 只锁 `action.sh`、`uninstall.sh`、`$SCRIPT_DIR/*.sh` |
| **装了模块但 DNS 根本不走 AGH**，querylog 里只有 `127.0.0.1` 的 PTR、没有任何真实客户端 | nat 链顶部有一条 `-m owner --uid-owner 0 -j RETURN`。Android 的系统解析器 `dnsproxyd` 就跑在 `netd`（uid 0）里 → 所有 App 的查询在进 AGH 之前被豁免 | 删掉「uid 0 全豁免」，只保留 SmartDNS（uid 9999）、回环（`-o lo`）、dnsenc bootstrap 的精确豁免（root 仅 `223.5.5.5:53`）。修完后 AGH 立刻能看到真实客户端与真实域名查询 |
| **shell（uid 2000）下 DNS 秒失败（`Could not resolve host`，3ms），但 AGH / smartdns / nat 链全都正常** | `/dev/socket/dnsproxyd` 是 `srw-rw---- root:inet`，uid 2000（shell/adb）不在 `inet` 组 → `connect` 返回 `EACCES` → 应用 fallback 到 `0.0.0.0:53` → `ECONNREFUSED` → 即刻失败。strace 抓到 `EACCES`，和网络层无关 | `service.sh` 启动时 `chmod 666 /dev/socket/dnsproxyd`，让所有 uid 都能连 dnsproxyd；DNS 查询经 netd → nat REDIRECT → AGH 正常解析 |
| 运营商 IPv6 DNS（`2408:8888::8` 之类）绕过过滤 | 本机内核没有 `ip6tables` 的 `nat` 表（`Table does not exist`），`TPROXY` 在 `OUTPUT` 也报 `Invalid argument`，v6 的 53 端口从来没有被处理 | 新增 `v6_dns=auto\|redirect\|drop\|keep`：`auto` 先试 `modprobe ip6table_nat` 走 nat REDIRECT；**拿不到 nat 表时保持 `keep`（不碰 v6）**，因为实测把 v6:53 丢掉之后 netd 不会可靠回落 v4（系统 DNS 里 `fe80::1%wlan0` 排在前面），整机域名全解析不了。`drop` 保留给「确认本网络有可用 v4 DNS」的用户手动开。v6 链同样支持 VPN 让路与 `proxy` 豁免 |
| 装了模块但偶发「域名全部解析不了」，链看着完全正常 | 换 Wi-Fi / AGH 重启 / smartdns 重新绑定端口之后，偶尔会进入「劫持链在、解析全挂」的状态，重建一次链即恢复 | `iptables.sh` 守护循环加解析自愈看门狗：每 ~60s 探一次 `ping www.baidu.com`，连续 3 次失败就强制 `rebuild_rules`（最多 10 分钟一次，避免频繁动链），日志记 `[WARN] 连续 N 次解析探测失败，强制重建 DNS 劫持链。` |
| dnsenc 的 bootstrap 豁免顺带放过了系统解析器 | bootstrap 写的是 `223.5.5.5:53`，而本机 Wi-Fi 的 `DnsAddresses` 里正好有 `223.5.5.5` —— `--uid-owner 0 -d 223.5.5.5 --dport 53 -j RETURN` 把 netd（uid 0）一起放过了，广告域名直接拿到真实 IP | bootstrap 改成运营商 DNS 之外的地址（2026-11 起为 `119.28.28.28:53`，原 `180.184.1.1` 已废：DNS 要 0.3–15.5 秒），`-bootstrap` 参数写进 `bin/dnsenc` 的启动命令（`service.sh` / `iptables.sh` / `sd-restart.sh` 三处），链里的豁免跟着改 |
| 规则导入超过 4MiB 被截断 / 报错 | `internal/home/middlewares.go` 给每个请求体套 `LimitReader`（默认 64KiB，`set_rules` 放宽到 4MiB） | `limitRequestBody` 直接透传；查看规则文件的上限也从 4MiB 提到 64MiB。实测 11.77MiB / 301280 条导入 HTTP 200 |
| 换到另一台机器（Redmi / Android 13）整栈起不来 | 该 ROM 的 `PATH` 里**连 `nohup` 都没有**，`setsid`/`pgrep`/`netstat`/`mountpoint`/`dirname` 也各自缺；原来 `nohup … &` 的兜底直接失效 | 后台起进程一律 `"$@" </dev/null >/dev/null 2>&1 &`；`pgrep`（读 `/proc/*/stat`）、`netstat`（`ss` → `/proc/net/*`）、`mountpoint`（`/proc/mounts`）、`dirname`/`basename`（纯 shell）全部内置兜底 |
| 开机瞬间起两个 AdGuardHome 抢端口 | `service.sh` 与 `scripts/iptables.sh` 的守护循环都会「检测不到 AGH 就拉起」，两边同时判定「没在跑」 | 两边共用 `$AGH_DIR/.agh.start.lock` 的 `mkdir` 原子锁，抢不到的一方等 12 秒并二次确认；实测并发启动后仍是 1 个实例、锁无残留 |
| 首次启动后过滤器自愈空转，`规则总数 0` | `agh_filter_heal()` 在 AGH 的 `/control/*` 路由还没注册完时就 `refresh`，拿到 `404 page not found` | 登录改成轮询（最多 20 次×1s 直到 200），`refresh` 失败重试 3 次并只认含 `"updated"` 的响应 |
| 老 iptables（1.4.x）上一整条链都建不起来 | 脚本里 50 多处写死 `-w 2`，老版本不接受该参数 | 启动时探测 `IPT_W`（不支持就置空），脚本与管理页 CGI 统一走该变量 |
| Redmi 首次启动 AGH 直接退出 | `initializing auth module: creating session storage: timeout`（`data/sessions.db` 打不开） | `crash.log` 尾出现 `sessions.db` 时自动删 `data/sessions.db*` 再重启 |
| 模块管理器一直提示「有新版本」，一装就把本模块覆盖回上游原版 | `module.prop` 里残留 fork 自上游的 `updateJson`，其 `versionCode` 是 `2026111100`，比日期版 `20261119` 大 | 删除 `updateJson=` 整行，模块不再提示任何更新 |

---

## 上游服务器管理（面板内置）

从 20261124 起，SmartDNS 上游管理页直接做进 AdGuard Home 面板：侧栏点「上游服务器管理」
走面板内路由 `/upstream_manage`（iframe 嵌 busybox httpd :6081 的 upstream-manage.html，
地址按浏览器当前 hostname 动态生成，手机从局域网 IP 打开面板也能加载），不再外跳独立页。
侧栏里 SmartDNS 面板（:6080）外链保留。

同时修复了路由切换卡顿：面板根组件原先把路由 children 包在 `<Show>` 门控里，
导航时第一次显示的还是上一个页面、要手动刷新才对；现在路由 children 常驻挂载、
只用 CSS 门控显隐，切换即时渲染。

---

## 构建

```bash
# 1. UI（AdGuard Home 面板）
cd src/client_v2
npm run build-prod          # 产物落 src/build/static/

# 2. Go 主程序（含 UI embed，注意版本号 ldflags）
cd src
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
  -ldflags "-s -w \
    -X github.com/AdguardTeam/AdGuardHome/internal/version.version=20261117 \
    -X github.com/AdguardTeam/AdGuardHome/internal/version.channel=release" \
  -o ../module/bin/AdGuardHome .

# 3. 加密上游桥
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
  -o ../module/bin/dnsenc ./cmd/dnsenc

# 4. 打包（module/ 目录直接 zip）
cd module && zip -r ../AdGuardHome-SmartDNS-Merged.zip . -x '*.DS_Store'
```

> ⚠️ 必须带 `-X …internal/version.version=…`，否则 `AdGuardHome --version` 输出为空。
> `main.go` 是 `//go:embed build`，UI 必须先构建到 `src/build/static/` 再编 Go。

---

## 开机为什么不卡（`service.sh` 异步分派）

root 实现（ksud / magiskd）执行模块 `service.sh` 时，会**一直等到脚本退出**才继续走 `late_start`。所以脚本里任何同步的慢步骤，都会把 `sys.boot_completed` 永远卡在 0 —— 表现就是开机动画转个不停。

原来这里有三个坑：

| 慢步骤 | 最坏耗时 | 后果 |
|---|---|---|
| `agh_filter_heal` 的过滤器 refresh | `curl -m 180` × 3 次重试 ≈ **9 分钟** | 直接卡死 |
| `sd_health_guard` 重启 smartdns | 两轮 pkill + 等进程退出 + 等端口释放 ≈ 几十秒 | 叠加卡顿 |
| `iptables.sh` 里的 `pm list packages` | PMS 未就绪时 binder 长期不回；调用方还持有 `.ipt.lock` | 后续链操作全部排队 |

现在改成：

```sh
# 开机关键路径 0 秒退出，真正的活在 setsid 出来的 --run 进程里
if [ "$1" != "--run" ]; then
    log "[INFO] service.sh 转入后台执行（--run），开机关键路径不等待本脚本。"
    setsid sh "$0" --run </dev/null >>"$AGH_DIR/agh-boot.log" 2>&1 &
    exit 0
fi

# --run：先等系统真正开机完成（最多 180 秒），再让系统喘 12 秒
_w=0
while [ "$_w" -lt 180 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
    sleep 1
    _w=$((_w + 1))
done
sleep 12
```

配套的三条：

- `iptables.sh` 的 `pkg_uid_cache()` 第一行 `boot_ready || return 0`，开机没完成就不碰 `pm`，uid 缓存等下一轮守护循环再补；
- 所有常驻进程（`AdGuardHome` / `smartdns` / `dnsenc` / `busybox httpd`）显式 `</dev/null` 重定向 stdin，绝不继承启动器的管道；
- 异步分派块必须放在 `setsid` / `dirname` / `basename` 的兜底函数**之后**，否则缺 `setsid` 的 ROM 上会 `command not found`。

这样 AGH 解析 19 万条规则（约 100MB 内存）、smartdns 起 chroot 全部落在 dexopt / zram 高峰之后，不再和系统抢内存。

实测（Redmi sky2 / MIUI 14 / Android 13 / 3GB）：**冷启动 62 秒**完成，模块 enable、无 `.no_start`：

```
06:29:53 [INFO] service.sh 转入后台执行（--run），开机关键路径不等待本脚本。
06:30:33 [INFO] 已等到 sys.boot_completed=1（39s），12 秒后启动 DNS 服务。
06:30:47 加密上游转发生效（1 条 → 127.0.0.1:6054）。
06:30:48 SmartDNS 启动成功 (chroot, :6053, UI :6080)。
06:30:50 AdGuardHome 启动成功。
```

### 万一还是卡住了

不用长按电源，`adb shell` 两条命令就能救：

```sh
su -c 'setprop service.bootanim.exit 1'   # 停开机动画
su -c 'wm dismiss-keyguard'                 # 拉起 Launcher，用户态转 RUNNING_UNLOCKED
```

还起不来再 `touch /data/adb/modules/AdGuardHome/disable` 重启 —— 模块禁用即正常启动，不会影响系统本身。

诊断开关：`touch /data/adb/agh/.no_start` 之后 `service.sh` 只记一行 WARN 就退出，什么都不起，方便二分定位。

> ⚠️ netd 的 `iptables-restore --noflush -w -v` 常驻 `pipe_read` 是**正常设计**：它的写端就在 netd 自己的 fd 上，杀掉会立刻重新 fork 一个。不是死锁，不要动它。
> 低端机 `sys.boot_completed` 卡住的常见真凶是 OOM + zram 晚挂（实测 uptime 108s 才 `swapon`）+ dexopt，`logcat -b crash` 里那条 init 的 SIGABRT 只是伴生现象（此时所有 service 都还在 running）。

---

## 安装

1. 把 zip 放进手机，在 KernelSU / Magisk 里刷入，或
   ```sh
   unzip -oq AGH.zip -d /data/adb/modules/AdGuardHome
   ```
2. 重启（或手动 `sh /data/adb/modules/AdGuardHome/service.sh`）
3. 端口：AGH 面板 `40251` · SmartDNS 面板 `6080` · 上游管理 `6081`（仅 `127.0.0.1`）

---

## 多设备兼容（在 OnePlus / ColorOS 与 Redmi / Android 13 上各跑过一遍）

Android 各家的 `PATH` 和内核差异比想象中大，这个模块原来有一批「只在作者那台机上成立」的假设，现在全部改成运行时探测：

| 依赖 | 现状 | 兜底方式 |
|---|---|---|
| `iptables -w` | 1.8.x legacy 支持，老 1.4.x 不支持 | 启动探测 `IPT_W`，不支持就置空；脚本 50+ 处与 CGI 统一走该变量 |
| `pgrep` | 部分精简 ROM 没有 | 读 `/proc/*/stat` 第 4 字段（父进程）、`cmdline`（`-f`）、`comm` |
| `netstat` / `ss` | 可能都没有 | 依次退到 `/proc/net/{tcp,tcp6,udp,udp6}`，同时识别 `127.0.0.1`、`0.0.0.0`、`::` 三种绑定（只认 `127.0.0.1` 会把绑全网的 6080 / 40251 误判成没监听） |
| `setsid` / `nohup` | Redmi 实测**两者都没有** | 直接 `"$@" </dev/null >/dev/null 2>&1 &`，不依赖任何一个 |
| `mountpoint` | 可能没有 | `grep -qs " $1 " /proc/mounts` |
| `dirname` / `basename` | 可能没有 | 纯 shell：`${1%/*}` / `${1##*/}` |
| `busybox` | 路径各家不同 | `/data/adb/ksu/bin` → `/data/adb/magisk` → `/system/bin` → `/system/xbin` → `/data/adb/bin` |
| `curl` | 可能没有 | 只关闭联网自愈（过滤器 / 挂起恢复），DNS 主链路不受影响 |
| CPU 架构 | 内置二进制只有 arm64 | 非 arm64 直接给出「本机 ABIs 与模块内置二进制不匹配」提示，而不是静默失败 |
| 时区 | 未设置时 AGH 日志全 UTC | 从 `persist.sys.timezone` 补齐并 export |

另外两处跨设备差异已经写进启动流程：

- **单实例锁**：`service.sh` 和 `scripts/iptables.sh` 的守护循环都会「检测不到 AdGuardHome 就拉起」，开机瞬间两边可能同时判定「没在跑」→ 两个实例抢端口。现在共用 `$AGH_DIR/.agh.start.lock` 的 `mkdir` 原子锁。
- **IPv6 keep**：`ip6tables` 的 `nat` 表在一部分内核上根本不存在（`Table does not exist`），`TPROXY` 在 `OUTPUT` 也不可用。`v6_dns=auto` 在这种情况下**保持 `keep`（完全不碰 v6）** —— 实测把 `v6:53` 丢掉之后 netd 不会可靠回落 v4（系统 `DnsAddresses` 里 `fe80::1%wlan0` 排在前面），整机域名全解析不了。

---

## HTTP/SNI/QUIC 三层拦截（fork 内置 snifilter + HTTP Host 解析）

本模块的 AdGuard Home 是定制 fork（liuzq2002/AdguardHome-Mod codex/client-v2 分支），内置 `internal/snifilter` 包，实现三层拦截：

### 拦截层级

| 层 | 端口 | 机制 | 效果 |
|---|---|---|---|
| DNS | 53 | AGH 域名过滤（NXDOMAIN） | 命中过滤列表的域名直接解析失败 |
| HTTP Host | 80 | snifilter 解析 HTTP 请求 Host 头 | 命中过滤列表的 Host → TCP RST 断流 |
| TLS SNI | 443/8443 | snifilter 解析 TLS ClientHello SNI | 命中过滤列表的 SNI → TCP RST 断流 |
| QUIC | UDP 443 | iptables DROP | 丢 QUIC 包强制回落 TCP（让 SNI 层接管） |

### 默认生效

无需开关，`sni_filter.enabled: true` 默认开启。有规则就拦截、无规则就放行，与 DNS 层共用同一份过滤列表（OISD/URLHaus/内置拦截列表）。

### 模块侧链管理（iptables.sh 守护）

守护进程每 5 秒读 AGH yaml `sni_filter` 块，动态挂/拆 filter 表 `AGH_SNI` 链（≤8s 同步）：

```
filter OUTPUT → AGH_SNI 链:
  -o lo RETURN                              # 本地流量放行
  -m owner --uid-owner 0 RETURN             # root 流量豁免（AGH/dnsenc 自身）
  -m owner --uid-owner <vpn_uid> RETURN     # VPN/代理应用豁免（BoxProxy 共存）
  -p tcp --tcp-flags ALL ACK RETURN         # 纯 ACK 放行（减少入队）
  -p udp --dport 443 -j DROP                # QUIC 拦截（drop_quic=true 时）
  -p tcp --dport 80 -j NFQUEUE --queue-num 7 --queue-bypass    # HTTP Host
  -p tcp --dport 443 -j NFQUEUE --queue-num 7 --queue-bypass   # TLS SNI
  -p tcp --dport 8443 -j NFQUEUE --queue-num 7 --queue-bypass  # TLS SNI
```

`--queue-bypass` = fail-open：AGH 进程被杀时流量直通（不会断网）。

### BoxProxy / VPN 共存

`AGH_SNI` 链自动豁免 `config.prop` 里 `vpn_apps` 列出的应用的 uid（`-m owner --uid-owner N RETURN`），VPN 应用自身的 443/80 流量不经过 snifilter。

### 局限

| 局限 | 说明 |
|---|---|
| ECH 加密 SNI | TLS Encrypted ClientHello 加密的 SNI 不可见，无法拦截 |
| QUIC/HTTP3 | QUIC 被 DROP 而非解析（强制 TCP 回落）；如果目标只支持 QUIC 则连接失败 |
| root 流量豁免 | uid 0 的流量被豁免（AGH/dnsenc 自身需要访问 443） |
| 流表限额 | maxFlows 16384 / 每流握手 32KiB / 总预算 16MiB / flowTTL 1min |

### 真机验证（Redmi 6c8dc14781cf / MIUI 14 / Android 13 / 3GB）

| 测试目标 | HTTP(80) | HTTPS(443) | 备注 |
|---|---|---|---|
| v1.cnzz.com（拦截列表） | **RST**（Connection reset by peer） | **RST**（000） | HTTP Host + SNI 双层命中 |
| www.baidu.com（放行） | 200 | 200 | 正常访问 |
| QUIC UDP 443 | — | — | DROP 规则在链 |

### 两个 mksh 兼容 bug（已修复）

1. **mksh 参数展开 `|` 是交替符**：`${var#1|}` 不剥、`%%|*` 全剥光 → NFQUEUE 行报 invalid port/service。改用 `awk -F'|'` 解析。
2. **`pgrep -f "$0"` 守护互斥竞态**：子壳同 cmdline 被数进去 → 误判已有守护静默 exit。改用 pid 文件 + `/proc/<pid>/cmdline` 核对。


## 致谢

- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) — AGPL-3.0
- [SmartDNS](https://github.com/pymumu/smartdns) — GPL-3.0

---

## 发版（更新 Releases）

改完 `module/` 并推到 `main` 之后，跑一条命令就会打包、建 tag、更新 Release 并挂上 zip：

```bash
python tools/release.py                    # tag 用 module.prop 里的 version
python tools/release.py --dry-run          # 只看会做什么
python tools/release.py --notes "本次修了 xxx"
```

Token 读 `GITHUB_TOKEN` 环境变量或仓库外层的 `.gh_token`（不要提交进仓库）。

> 仓库里也有 `.github/workflows/release.yml`（push `v*` tag 自动发版），
> 但当前账号下 Actions 跑不起来（run 3 秒即失败、0 个 step），所以实际用 `tools/release.py`。
> 想用 Actions 的话去 Settings → Actions → General 把 Workflow permissions 改成
> **Read and write permissions**，并确认账号 Actions 配额没耗尽。
