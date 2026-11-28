## 20261214
- **AdGuardHome 侧栏：删掉「上游服务器」入口**
  - `src/client_v2/src/common/ui/Menu/Menu.tsx` 移除 `smartdns_upstream` 的 `<div><a href="http://127.0.0.1:6081/upstream-manage.html">`，保留 `smartdns_ui`（→ 6080）
  - `__locales/en.json`、`zh-cn.json` 删 `smartdns_upstream_manage` 键
  - 重建后 `main.d45b273e62461964a1a2.js`：`upstream-manage` 0 次、`6081` 只剩隐私页 endpoint
- **SmartDNS 侧栏：删掉独立整页的 Upstream Manage 项**
  - `_next/static/chunks/c810cf60f955d2e8.js` 的 nav 数组剔除 `{key:"upstream-manage",...,fullPage:!0}`，25,709B → 25,594B / md5 `d765f8f44ff9e73e436b06caed5f7fc0`
  - 侧栏变为 仪表盘 / 查询日志 / 上游服务器 / 客户端 / 日志 / 设置 / AdGuard Home
- **上游服务器管理内置进 SmartDNS 自己的页面**
  - `dashboard/upstream-servers.html` 注入：标题「上游服务器」右侧挂「管理上游服务器」胶囊按钮；点开是同源全屏浮层（`/upstream-manage.html` iframe，顶部「← 返回」+ 标题）
  - 6081 只当后端（CGI `cgi-bin/upstream`，带 `Access-Control-Allow-Origin: *`），不再对外挂独立页面入口
  - 实测：点按钮 → 浮层弹出，内含 手动添加 / 一键添加 / 当前生效的上游 / 加密上游 / VPN 共存 / IPv6 / 域名规则 / 保存并重启
- **新 bin**：`bin/AdGuardHome` 23,396,512B / md5 `1a3678ed12d36ef3c15c71e52acfcc10`（src 全量重编译，`npm run build-prod` + `go build -s -w -trimpath`）
  - 字符串核查：`upstream-manage` 0、`smartdns_upstream` 0、`smartdns_upstream_manage` 0、`6081/cgi-bin/privacy` 1、`恶意网站拦截` 0
- `dashboard/upstream-servers.html` 46,157B / md5 `c7ac5ded586000a30b625025cc9e5012`

## 20261213
- **隐私页改成源码级重建，不再打二进制补丁**
  - 新增 `src/client_v2/src/components/Privacy/`（`Privacy.tsx` + `Privacy.module.pcss`），在 `Paths.ts` 注册 `Privacy`，在 `App/index.tsx` 挂 `<Route>`，在 `Menu.tsx` 侧栏加「隐私」项（lock 图标，位于查询日志与 SmartDNS 之间）
  - `bin/AdGuardHome` 由 `src/` 全量重编译得到：`npm run build-prod`（22 assets / 3,240,628B → `src/build/static`）+ `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath`，产物 23,396,512B（原 27,132,064B，差额是剥离符号表）
- **根因**：原内嵌页 `const[e,t]=_({dns:!0,vpn:!0,...})` 全真初值 + `A(()=>{同步 XHR GET → r(JSON)})` 挂载后覆盖 → conf 里有 0 的项必然「先绿后灰」。dns/vpn/ip 恒为 1 所以看着不跳
- **新写法**：`createSignal(readState())`——同步 XHR 放进 signal 初值，组件构造期就是真值，首帧即 conf；`toggle()` 只 `setState(next)` + 一次 POST，POST 回调不回写、无任何 effect 重新 GET
- **键集**：固定 dns/vpn/ip/ntp/dhcp/smb/tcp/snmp 八个，`sb` / `par` 两个废键不再出现在前端请求体里
- **页面形态（1:1 复刻原版）**：`<h1>隐私</h1>` + 8 个 `SettingRow(variant:switch, align:top, title, description)`（文案逐字照搬原版）+ 「泄露检测」4 个外链（browserleaks DNS / WebRTC / ipleak / 综合）+ 说明段落；不含恶意网站拦截、成人内容过滤、一键过检测
- 实测：conf `ip=0 ntp=0 dhcp=0 tcp=0` 时打开隐私页，**页面出现的第一帧**（第 5 张采样）就是 IP/NTP/DHCP/TCP 全灰，开关列 hash `f8452d2c`，与第 5 秒的帧完全相同；点「防止明文协议泄露」后 220ms / 440ms / 2.4s 三帧 hash 全等 `B31F39D8`，`nchg=1`、请求体 `dns=1&vpn=1&ip=0&ntp=0&dhcp=0&smb=1&tcp=1&snmp=1`（无 sb/par）；三次强制停进程重开，开关列 hash 全等 `c545d6971c`
- `bin/AdGuardHome` md5 `42eba74ed131fdf020dbb5e75a15df0b`（23,396,512B / aarch64 ELF）

## 20261212
- **隐私开关「关一下再打开」真因找到并根治（改二进制）**
  - 内嵌前端原是 `const[e,t]=_({dns:!0,vpn:!0,...})` + `A(()=>{同步 XHR GET ... r(JSON)})`：首帧先按 8 项全真渲染，挂载后 GET 覆盖。**只要 conf 里有一项是 0，每次打开都「先绿后灰」** —— 这就是跳的来源；dns/vpn/ip 恒为 1 所以看着不跳
  - 改法：把 `{dns:!0,...}` 换成 `Qy()`，新增 `Qy=()=>{同步 XHR GET http://127.0.0.1:6081/cgi-bin/privacy → JSON.parse}`，放在 `Gy` 数组闭合处的注释空白里（279B 正好等长），`bin/AdGuardHome` 仍是 27,132,064B，三词频仍为 0
  - 效果：`const[e,t]=_(Qy())` 在组件创建时同步拿到真值，**首帧即最终值，一次都不翻转**
- 实测：conf 有 4 个 0 时打开隐私页，1.2s 与 4.0s 两帧 md5 完全相同（`9272A8EA…`），差异仅状态栏电量图标 14×11 像素；conf mtime 全程冻结、POST 日志空
- 配套沿用 v20261211：cgi 三层保护、service.sh 自愈白名单、证书/脚本/MITM 三套页移除
- `bin/AdGuardHome` md5 `809adce919337d887a5e9e73487dc63b`（27,132,064B）

## 20261211
- **隐私开关"关一下再打开"彻底解决（服务端）**：`cgi-bin/privacy` 换成三层保护版
  - `save_conf()` 原子写（`.tmp` → `chmod 644` → `mv -f`），不再出现半截文件
  - POST 解析改成 8 键白名单 awk（dns/vpn/ip/ntp/dhcp/smb/tcp/snmp），`sb`/`par` 彻底丢弃
  - 变化计数：单次 POST 改动 ≥2 键且无 `force=1` → 判定前端整表回写，全量恢复原值
  - 时间锁：`/proc/uptime` 百分秒精度，500ms 内重复 POST 丢弃；状态存 `/data/adb/agh/.privacy_post_ts`
  - 每次 POST 落一行诊断日志 `/data/adb/agh/privacy_post.log`（body / nchg / 最终值）
- **实测**：连续打开隐私页 5 次，`privacy.conf` 内容零变化、mtime 冻结、POST 日志为空；单点开关只改 1 键（nchg=1），精确落盘
- **`service.sh` 自愈循环改白名单**：只补 `apps` / `upstream` / `privacy`，其它键 `chattr -i` 后 `rm -f`；开机预热只留 `apps?rebuild=1`，删掉 `privacy?sync=1` 与 `certs/mitm/scripts?rebuild=1`
- **删掉证书 / 脚本 / MITM 三套页**：`cgi-bin/certs`、`cgi-bin/mitm`、`cgi-bin/scripts` 移出包；`certs/` 整套 CA 证书、`scripts/certs_install.sh`、`scripts/rewrite/privacy.rewrite` 一并移除（自签 CA 不再被塞进系统信任区，浏览器不再弹证书警告）
- 侧栏「高级设置」下只剩「隐私」；`恶意网站拦截` / `成人内容过滤` / `一键过检测` 在 `bin/AdGuardHome` 里词频全 0
- `bin/AdGuardHome` md5 `c1e0a64b959287f1175efd9ee37c6a90`（27,132,064B），git blob `43f1713b0e325c010aff87b1bbd39778a4f92b34`

## 20261210
- **6081 并入 6080**：`smartdns/usr/share/smartdns/wwwroot/` 里放一份上游服务器管理页，6080 直接可开；`service.sh` 加 `sync_sd_wwwroot()`（在 `start_webui` 之后调用，`cmp -s` 有差异才拷、顺手 `rm -f` 旧的自建 `privacy.html`）
- **删掉自建隐私页**：`scripts/webui/privacy.html` 与 `scripts/webui/cgi-bin/privacy-page` 整份删除。AGH 面板 40251 → 高级设置 → 隐私 就是唯一入口，不再有同名的第二套页面
- **隐私页再打一轮二进制补丁**（`bin/AdGuardHome`，27,132,064B 等长替换，ELF 结构不动）：
  - 顶部提示句去掉「恶意网站拦截」「成人内容过滤」两个名字
  - 「一键过检测」标题清空
  - 上游不可达时的提示文案清空
  - 初始 state 与同步赋值里的 `sb` / `par` 去掉
  - 校验：`恶意网站拦截`=0、`成人内容过滤`=0、`一键过检测`=0
- **侧栏只剩「隐私」**：高级设置下的「证书」「脚本」两项此前已置空，这版确认渲染为空
- **开关不再翻**：`privacy.conf` 8 项全为 1，与首帧默认值一致；`ntp:!1`/`dhcp:!1` 这类旧默认值在二进制里已是 0 次
- 模块包 `AGH_v20261210.zip`：39,453,832B / 3,245 条目，`bin/AdGuardHome` md5 `c1e0a64b959287f1175efd9ee37c6a90`

## 20261202
- **证书警告的第二层根因**：光修目录权限不够。开机早期 `chcon` 会被策略挡下来，注入完成后文件 SELinux 标签停在默认的 `u:object_r:tmpfs:s0`，untrusted_app 读这些文件被拒 —— 系统信任库对 App 仍然是空的。现在统一用 `restorecon -RF`（走 policy 的 file_contexts，比 chcon 稳）收口，做「异常计数 + 最多 3 次重试」，再挂一个 25 秒延迟复核兜底
- 真机证据：修前 `su 2000 -c "ls /system/etc/security/cacerts"` 直接 Permission denied、`ls -lZ` 是 `u:object_r:tmpfs:s0`；修后 app uid 10106 能读 1224 字节的 mitm-ca、能列出 127 张
- **update.json 长期不同步的根因**：`SKIPUNZIP=1` 自己解压但清单漏了 `update.json`，`$MODPATH/update.json` 压根不存在 → 后面的拷贝分支恒假，运行目录那份停在旧版本，自检永远报「version≠模块」。现在显式 `unzip update.json` 再走原逻辑
- full_check 第 14 节扩到 7 条断言：目录 0755、目录标签、**文件标签全对**、非 root uid 可列举、两张模块 CA 在位

## 20261201
- **修掉「所有 HTTPS 站点都弹证书不受信任」**：tmpfs 覆盖 `/system/etc/security/cacerts` 之后，挂载点的目录权限是 `0700`。uid≠0 的进程（所有 App / WebView / Chrome / 各家 SDK）根本打不开这个目录，系统信任库对它们等于空的 → 每个 HTTPS 站点都报证书错误。现在挂载后显式 `chmod 755`，并且在每次开机的「已挂载 → 核对清单」分支里幂等修正一次（tmpfs 每次开机重建，权限必然退回 0700，所以必须每次修）
- 同时给模块 overlay 目录和 tmpfs 副本目录补齐 `0755`，文件保持 `0644`，SELinux 标签仍是 `u:object_r:system_security_cacerts_file:s0`
- 自检新增 2 条断言：信任库目录权限必须 0755、非 root uid 能列举出 CA 清单

## 20261130
- **修掉真正让「别的开关关一下再打开」的那段代码**：40251 AGH 面板里的「隐私」页不是 6081 那个独立页面，它是编译进 `bin/AdGuardHome` 的一段 SolidJS 组件。那段代码首帧硬编码 `dns/vpn/ip:!0`，`sb/par/ntp/dhcp/smb/tcp/snmp:!1`，组件挂载后才 `fetch` 回真值 —— 于是恰好 DNS/VPN/IP 三个不翻、其余全翻。现直接改二进制内嵌前端（等长替换，文件仍是 27,132,064B）：8 个网络开关的首帧默认值全部改成 `!0`（与 privacy.conf 实际值一致），首帧即最终值，不再翻
- **从该页面删掉「恶意网站拦截」「成人内容过滤」**：把开关数组里 sb / par 两个元素整段注释掉（279 字节等长替换），页面现在只渲染 8 个开关
- 改动可复现：`tools/patch_frontend.py`（默认只体检，`--write` 才落盘；两处替换均等长，不改 ELF 结构）
- 自检新增 2 条断言：二进制里旧默认值 `ntp:!1,dhcp:!1` 必须为 0、新默认值必须 ≥1

## 20261129
- **隐私页彻底停掉自动刷新**：删掉两处自动核对（进页面 900ms 回 GET 一次、切回前台再 GET 一次），读取失败也不再走「把整页画成已关闭」那条分支。这就是「别的开关关一下再打开、DNS/VPN/IP 三个不翻」的根因 —— 不是开关不同，是那两次自动核对里只要一次慢或失败，屏上就先全灰、等下次成功再全绿。现在 8 个开关完全同一套逻辑：只在 ①首帧内联 ②你点「重新读取」③你自己拨开关 这三个时刻变
- **物理级破缓存**：新增 6081 根入口 `http://127.0.0.1:6081/`，每次进入都带毫秒时间戳跳到 `/cgi-bin/privacy-page`（URL 每次都不同，缓存 key 必然不同，旧副本再也命中不到）；`/privacy.html` 静态访问也会自动跳同一个免缓存页；CGI 输出带 `Cache-Control: no-store` + `Pragma` + `Expires: 0`。页底构建号 `20261130` 用于自证浏览器吃的是哪一版
- 移除页面上两个必须异步纠正的引擎开关（真值在 AGH 原生日志引擎里，页面只能先填缓存值再纠正 → 必翻），`--apply` 里对 safebrowsing / parental 幂等关闭
- `module.prop` 描述、`action.sh` 输出统一改为根入口 `http://127.0.0.1:6081/`
- 自检 full_check 增至 **126 项全绿**：新增「页面无 setTimeout(load) 自动核对」「无 visibilitychange 核对」「CGI 输出同样无核对」「根入口 / 会跳免缓存页」「构建号 20261130」；修掉「面板端口 DROP」断言在守护 A/B 换链窗口取样为空导致的假 FAIL（改为取快照 + 最多 3 次重试后本地逐条判）
- 实测：同一页面 1200ms 与 4500ms 两次渲染**字节级一致**（95,980B / MD5 相同），页面静置后状态零变化

## 20261128
- 隐私页刷新彻底不再「关一下再打开」：8 个开关的真值改为**静态内联**在 privacy.html 里（cgi-bin/privacy 每次写完状态原地改写那一行），首屏只需一次静态请求，实测首字节 3~5ms（原来要 `?embed=1` 二次 CGI 65~115ms）——页面第一帧就是最终值，浏览器来不及把上一帧的旧状态留在屏幕上
- 根因是 localStorage 快照分支：旧版内联没命中就按「上次打开页面时的状态」画，GET 回来再纠正，于是只有「动过的那几个」会翻（DNS/VPN/IP 没动过所以看着稳）。该分支已整体删除
- 删除两个引擎开关（真值在 AGH 原生引擎里，页面只能先填 conf 缓存值再异步纠正 → 必翻），并在 `--apply` 里幂等关闭 safebrowsing / parental 两个引擎
- 装机时把包内 update.json 同步到运行目录与模块根（此前运行目录那份是几版前手工留下的，自检永远报「版本不一致」，管理器「检查更新」也读不到新包）
- 自检 full_check 增至 116 项全绿：新增「静态内联值与 GET 真值一致」「页面不再引 ?embed=1」；修掉 SNI 原子性采样把 xtables 锁竞争（`-w 2` 超时返回空）误判成「裸奔窗口」的假 FAIL

## 20261127
- 6081 管理面（脚本/隐私/证书/MITM/应用列表）全部改为缓存直出：privacy 37ms、scripts 38ms、apps 170ms、certs 36ms、mitm 33ms（此前 privacy 1.6~2.7s、apps 19.1s）
- 隐私页开关不再「刷新先关后开」：GET 只读缓存、规则换挂改为原子 -E 换链，连续 5 次刷新规则集 md5 不变
- MITM 静默坏状态自愈：mitm_on 开着但接管名单为空时自动按浏览器/WebView 播种，nat 里缺失的 REDIRECT 自动补回
- 模块目录补全：scripts/* 整包落盘（此前只有 2 个 .sh），bin/ 与 CGI 权限开机自愈，ghmitm/certs_install.sh 不再丢 exec 位
- 日志轮转：mitm.log、in/crash.log、gh.log、dnsenc.log 超过 2MB 自动保留尾部 256KB
- 自检脚本随包装入 	ests/：su -c "sh /data/adb/agh/tests/full_check.sh"（83 项）

## 20261125
- 优化了AGH核心中SNI功能的稳定性
- 拦截了最近疯传的小米云控后门漏洞以及努比亚云控，优化了旧有规则的误杀
- 优化了Iptables脚本，精准放行自身流量避免自噬打崩自身
- 最近这一个月都在疯狂优化AGH核心稳定性，后面我再考虑把规则优化一下
