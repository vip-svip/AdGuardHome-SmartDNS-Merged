# AdGuard Home + SmartDNS 合并 Magisk / KernelSU 模块

一个把 **AdGuard Home（去广告 + 查询日志 + 面板）** 与 **SmartDNS（缓存 + 分流 + 最快 IP 测速）** 串成一条链的 Android 模块，额外提供自建**加密上游桥**，让内置 SmartDNS 也能用 DoH / DoT / DoQ 上游。

```
应用 → AGH:53（nat 劫持）→ SmartDNS:6053 → dnsenc:6054 → 加密上游（DoH / DoT / DoQ）
                              └─ 明文上游组（UDP 53）
```

- **作者**：vip-svip
- **许可证**：见 `LICENSE.txt`（AdGuard Home 与 SmartDNS 各自的上游许可）
- **版本号**：纯日期 `YYYYMMDD`（如 `20261124`），`module.prop` 的 `version` 与 `versionCode` 同为一个日期整数，Release 的 tag 也是它。

---

## 核心特性

- **三层拦截**：DNS 域名过滤 + SNI 阻断（HTTP Host 头解析）+ QUIC DROP（UDP 443 强制回落 TCP）
- **SNI 端口扩展**：80/443/8443 默认端口，可扩展至 2053/2054/2083/2087/2089/2091/2096/2480 共 11 个
- **加密上游**：dnsenc 加密桥，支持 DoH / DoT / DoQ，上游数据加密传输
- **内置规则**：广告拦截、隐私追踪、运营商追踪、反诈上报、色情广告、水印六大类，开箱即用
- **自愈守护**：service.sh 启动自动注册过滤器、修复零计数、修正 SNI 端口；iptables/NoAds/ProxyConfig/ModuleMOD 四守护脚本 5 秒循环
- **多手机兼容**：IPT_W 探测、缺失命令兜底、单实例锁、v6=keep
- **代理兼容**：支持 Box、AkashaProxy、Clash MIX 等代理模块，订阅链接自动写入 config.prop

## 模块结构

| 目录 | 内容 |
|---|---|
| `Adguardhome/` | 模块主体（`service.sh` / `customize.sh` / `uninstall.sh` / `module.prop` / `action.sh`） |
| `Adguardhome/bin/` | AdGuardHome + dnsenc arm64 二进制 |
| `Adguardhome/rules/` | 内置过滤规则（广告/隐私/运营商/反诈/色情/水印等） |
| `Adguardhome/scripts/` | 守护脚本组（iptables / NoAds / ProxyConfig / ModuleMOD / sni_filter.awk） |
| `Adguardhome/smartdns/` | SmartDNS 二进制 + 配置 + 面板静态资源 |
| `Adguardhome/hosts/` | hosts 兜底文件 |

## 安装

1. 关闭或卸载其他广告拦截模块、无障碍跳过软件、VPN 代理去广告
2. 在 Magisk / KernelSU 中刷入本模块 zip
3. 重启后访问 Web UI：
   - AdGuard Home 面板：`http://127.0.0.1:53`
   - SmartDNS 面板：`http://127.0.0.1:6053`

## 卸载

执行 `uninstall.sh`，自动清理进程、iptables 规则、代理配置、残留文件，无残留。
