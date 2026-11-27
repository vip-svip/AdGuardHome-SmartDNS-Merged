## 20261128
- 隐私页刷新彻底不再「关一下再打开」：8 个开关的真值改为**静态内联**在 privacy.html 里（cgi-bin/privacy 每次写完状态原地改写那一行），首屏只需一次静态请求，实测首字节 3~5ms（原来要 `?embed=1` 二次 CGI 65~115ms）——页面第一帧就是最终值，浏览器来不及把上一帧的旧状态留在屏幕上
- 根因是 localStorage 快照分支：旧版内联没命中就按「上次打开页面时的状态」画，GET 回来再纠正，于是只有「动过的那几个」会翻（DNS/VPN/IP 没动过所以看着稳）。该分支已整体删除
- 删除「恶意网站拦截」「成人内容过滤」两个开关（它们的真值在 AGH 原生引擎里，页面只能先填 conf 缓存值再异步纠正 → 必翻），并在 `--apply` 里幂等关闭 safebrowsing / parental 两个引擎
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
