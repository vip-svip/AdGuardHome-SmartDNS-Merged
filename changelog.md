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
