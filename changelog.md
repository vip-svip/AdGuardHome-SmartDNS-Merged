## 20261208
- **「防止局域网探测泄露」(smb) 一处一处挖出来的 8 个真缺陷，全修**
  - **137 被 dns 组重复挡**：`dns=1` 的规则里混进了 `137`，和 smb 组重叠。把 smb 关掉，137 依旧被 dns 挡着 —— 现象就是"开关关了完全没变化"，被当成开关坏了。137 已从 dns 组移除，dns 只管 `5353,1900`
  - **漏 UDP 138**：NetBIOS Datagram Service(138) 才是名字/工作组广播的主通道，原来一个字节都没挡
  - **UDP 445 是死规则**：SMB 只走 TCP 445，原 `udp dports 137,139,445` 三个槽位里两个永远匹配不到
  - **漏 LLMNR 5355 与 WS-Discovery 3702**：Windows 与部分 Android 用它查主机名，回包直接吐出设备名和机型
  - **v6 面 137/139/445 全死**：IPv6 上根本没有 NetBIOS/SMB，那两条照抄 v4 的规则永不命中；v6 该挡的是 5353/5355/3702/1900
  - **v6 回退段残缺**：`ip6tables-restore` 不可用的 ROM 上，v6 只建了 lo/conntrack/dns 三条，其余开关在 v6 面全部哑火。已补齐成与 restore 段逐条等价
  - **`dhcp=1` 会断网**：原来无条件挡 `udp 67`，而本机续租正是 68→67 广播，租约一到期就上不了网。改成只挡"发往非 255.255.255.255 的 67"，续租放行（v6 对应改 547 并排除 `ff02::1:2`）
  - **`-o lo` 只豁免出向**：补 `-i lo`，回环双向豁免，本机自测不再误伤
- **规则集版本号进签名**：`apply()` 的幂等签原来只比 8 个开关值 —— **升级脚本后开关值没动，旧链就被原样留着**，改完代码看规则还是老的，正是"我手机上没看到你改的内容"。现在签名首部带 `rl=2`，脚本一升就强制重建
- **文案与行为对齐**：`smb` 描述从「137/139/445」改成「UDP 137/138/5355/3702、TCP 139/445」；`dhcp` 补上「本机续租广播放行」；`dns` 去掉 NetBIOS（137 归 smb）。40251 内置页与 6081 页两处同步
- **真机实测（`6c8dc14781cf` / sky2 / KernelSU）**
  - 机制有效性：链首临时插 `icmp echo-request DROP` → `ping 192.168.0.1` 由 2/2 收到变 100% 丢包、计数 4 pkts；删掉立刻恢复 ⇒ `AGH_PRIV` 对出向流量确实生效
  - 逐端口命中（发网关单播，先 `iptables -Z` 清零）：UDP 137/138/5355/3702 → smb 行 `4 pkts / 120 B`；UDP 5353 → dns 行 `1/30`；TCP 445 → `tcp dports 139,445` 行 `1/60`，`nc` 返回 1
  - 开关语义：`smb=1` 时 `iptables -S` 同时有 `udp 137,138,5355,3702` 与 `tcp 139,445`；`smb=0` 时 **137 在整条链 0 引用**（dns 组也不再挡它）、5355 归零、v6 的 137 同样归零
  - 页面：40251 的 `main.64ef5859c32ece275993.js` 里 `137/139/445` 出现 0 次、新串 1 次；6081 `/cgi-bin/privacy-page` 渲染文案与新规则一致（真机截图留档）
## 20261207
- **6081 隐私 CGI 的四处真 bug（页面状态与实际配置长期错位的根因，也是"刷新后开关又弹回去"的元凶）**
  - `$0` 在 busybox httpd 下只有文件名（`privacy`），`HTML="${0%/*}/../privacy.html"` 拼出 `privacy/../privacy.html` 这种死路径，`[ -f ]` 永远 false —— **首屏内联真值从安装以来一次都没更新过**。改成"固定安装路径 → `$0` 推导 → 上一级目录"三级回退
  - 内联行替换的 awk 两处错：`^window.__AGH_PRIV=` 要求行首（实际行带缩进，永远匹配不到）；`substr` 取 `}` 位置差一，替换后多出一个 `;`。改为任意位置匹配 + `sprintf("%c",125)` 取花括号 + 正确截断
  - GET 缓存用 `[ "$CONF" -nt "$RESP" ]` 判过期：`cp -p`/tar 还原（mtime 不变或更旧）与同秒写入（mtime 精度 1s）都会判"没变" → conf 已是 1、CGI 一直回 0、页面长期显示旧状态。改成**每次拿 conf 现算 JSON 与落盘 STATE 做内容比对**，不一致就重写
  - `applied` 原来硬编码 `1`，`apply()` 末尾也无条件写 stamp → iptables 建链失败也照样报"已生效"。现在 `applied` 只认 stamp，stamp 只在 `iptables -C OUTPUT -j AGH_PRIV` 成立时才写，否则删掉
- **首屏耗时**：`load_conf` 由 fork 一次 awk + eval 改成纯 shell 内建 `while read`（零 fork）；GET 的内容比对由 `tr` 改成内建 `read`
- **功能三态实测**：conf 里 smb 依次 1→0→1，GET 返回与 `privacy.html` 内联值全部同步；40251 隐私页在 conf 全 1 与 smb=0 两种情况下各录 9s/30fps，逐帧统计开关区绿色像素：其他开关恒定 250，SMB 在新页面出现的第一帧就是目标值，全程无翻转

## 20261206
- **隐私页开关「自己翻一次」根治**：首屏状态从异步 `fetch` 改成**同步 XMLHttpRequest**。原因是 `fetch` 的回调必然排在首帧绘制之后 —— 组件先用编译期默认值（全 `!0`）画一遍，真值回来再改成 conf 里的值，于是你关过的那个开关就"先绿后灰"翻一次。同步请求在首帧绘制之前完成，第一帧画的就是最终值
- **实测对照（本机，conf 里 smb=0，竖屏 30fps 逐帧统计开关区绿色像素）**：旧版 v7 第 110 帧页面出现时 smb 区绿色像素 1004，第 127 帧降到 0 —— 翻了一次；新版 v8 全程 230 帧 smb 区绿色像素 0，页面第一帧就是灰色。DNS/VPN/IP 不翻，是因为它们一直是开（默认值恰好等于真值），不是它们有什么特殊逻辑
- **"标题字体跳一下"同一根因**：某行从开到关时标题字重/颜色跟着变，视觉上就是跳。同步取值后一并消失
- `tools/patch_frontend.py` 增加第 7 步（fetch→同步 XHR），并修掉 sb/par 已 patch 时 `find=-1` 导致字节翻倍的 bug；从 v7 一件复现得到 `67bfa7fa097b06f5f4e9771158685be5`

## 20261205
- **40251 侧栏「脚本」项移除**：`高级设置` 只剩 `隐私` 一项，证书与脚本都不再出现；仍旧用数组 spread `...[]` 等长替换，分组展开正常
- **字体稳定**：7 处 `html { -webkit-tap-highlight-color: transparent; }` 换成 `-webkit-text-size-adjust: 100%`（等长）。关掉 Android WebView 的字体自动放大，长页面下方文本块不再在布局定型后被重新放大，标题不再跳
- **开关区零位移延续**：圆点 `transition:none` + 全 `!0` 首帧，刷新时开关一个像素不动（25 帧连拍实测 5→7 帧像素差 0）
- `tools/patch_frontend.py` 增加菜单「脚本」项与 `text-size-adjust` 两步，从原始二进制一键复现，对已 patch 版本幂等

## 20261204
- **40251 侧栏「证书」项彻底移除**：`高级设置` 分组现在是 `隐私 / 脚本` 两项。做法是把菜单数组里那一项替换成 `...[],`（数组 spread 空占位，等长替换，27,132,064B 不变）。踩过的坑写进工具里：**用 `/*...*/` 注释虽然语法合法，但会让整个分组变成点不开**（实测点击只高亮、箭头不翻转、子项永不出现），所以 `tools/patch_frontend.py` 固定用 spread，不用注释
- **开关圆点过渡置 none**：`.XkM1AwvjnBB5yZeXXHn1:before` 的 `transition: transform var(--t2), background-color var(--t2)` 改成 `transition:none`（4 份 CSS 副本全部改）。首帧不管 `checked` 是何时落到 DOM 上，圆点都直接停在终点，不会再「先关再滑到开」
- **首帧默认值**：延续 20261130 的全 `!0`（与 privacy.conf 实际值一致），首帧绘制的就是最终值；加上这次去掉位移动画，刷新时开关区一个像素都不变
- `tools/patch_frontend.py` 同步：两处新替换（菜单 spread、圆点 transition）都已内置，`--write` 可复现；工具对已 patch 的二进制是幂等的

## 20261203
- **证书子系统整体移除**（按使用方要求）：模块不再生成、安装、覆盖任何自签 CA。删掉 `certs/`（两套 CA + 私钥 + meta + cacerts overlay 源）、`scripts/certs_install.sh`、`cgi-bin/certs` 证书页接口、`bin/aghmitm`（15.9MB）与 `scripts/rewrite/`（MITM 重写规则），安装脚本里那段 `unzip certs/*` + `MODDIR=... certs_install.sh` 也一并去掉
- **MITM 链路一并拆除**：`iptables.sh` 去掉 `mitm_uids` / `mitm_selfheal` / `mitm_redirect_apply` / `mitm_proc_guard` 四个函数与全部调用点，不再给任何 uid 的 443 做 REDIRECT 到 8899、不再给 v6 443 发 tcp-reset；开机 `service.sh` 不再拉起 aghmitm、不再释放 rewrite 默认脚本；`cgi-bin/mitm` 运行时接口删除
- **系统信任库回到原厂状态**：开机不再 mount tmpfs 覆盖 `/system/etc/security/cacerts`，卸载后 125 张原厂 CA 完整，App/WebView 不再因为信任库被替换而报证书错误（真机实测 Quetta 打开 https://www.baidu.com 直接正常，无任何警告）
- **脚本页与 MITM 解耦**：`cgi-bin/scripts` 的脚本库目录从 `scripts/rewrite` 改为 `/data/adb/agh/scriptlib`，内置清单 `catalog/rewrite` 保留（那是可添加的脚本索引，不是 MITM 规则）；脚本页仍可列表/启停/生成 AGH 拦截规则
- **自检同步**：full_check 去掉 aghmitm/证书/信任库相关断言，改为反向校验「8899 不该监听」「cacerts 不该被覆盖」「系统里不该再有模块 CA」

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
