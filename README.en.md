# AdGuard Home + SmartDNS Merged Magisk / KernelSU Module

A Android module that chains **AdGuard Home** (ad blocking + query log + web UI) with **SmartDNS** (cache + routing + fastest IP selection), plus a self-built **encrypted upstream bridge** so the built-in SmartDNS can use DoH / DoT / DoQ upstreams.

```
App → AGH:53 (nat hijack) → SmartDNS:6053 → dnsenc:6054 → encrypted upstream (DoH / DoT / DoQ)
                              └─ plain upstream group (UDP 53)
```

- **Author**: vip-svip
- **License**: see `LICENSE.txt` (AdGuard Home and SmartDNS upstream licenses)
- **Version**: date-only `YYYYMMDD` (e.g. `20261124`). `module.prop` `version` and `versionCode` share the same date integer, and the Release tag matches it.

---

## Core Features

- **Three-layer blocking**: DNS domain filtering + SNI blocking (HTTP Host header parsing) + QUIC DROP (UDP 443 forced TCP fallback)
- **SNI port expansion**: 80/443/8443 default, expandable to 2053/2054/2083/2087/2089/2091/2096/2480 (11 ports total)
- **Encrypted upstream**: dnsenc bridge with DoH / DoT / DoQ, upstream data encrypted in transit
- **Built-in rules**: ad blocking, privacy tracking, carrier tracking, anti-fraud reporting, adult ad, watermark — six categories, ready to use
- **Self-healing**: service.sh auto-registers filters, fixes zero-count, corrects SNI ports at startup; iptables/NoAds/ProxyConfig/ModuleMOD four guard scripts run 5s loops
- **Multi-device compatibility**: IPT_W detection, missing-command fallback, single-instance lock, v6=keep
- **Proxy compatibility**: Box, AkashaProxy, Clash MIX and other proxy modules; subscription URL auto-written to config.prop

## Module Layout

| Directory | Content |
|---|---|
| `Adguardhome/` | Module core (`service.sh` / `customize.sh` / `uninstall.sh` / `module.prop` / `action.sh`) |
| `Adguardhome/bin/` | AdGuardHome + dnsenc arm64 binaries |
| `Adguardhome/rules/` | Built-in filter rules (ads/privacy/carrier/anti-fraud/adult/watermark) |
| `Adguardhome/scripts/` | Guard scripts (iptables / NoAds / ProxyConfig / ModuleMOD / sni_filter.awk) |
| `Adguardhome/smartdns/` | SmartDNS binary + config + panel static assets |
| `Adguardhome/hosts/` | hosts fallback file |

## Install

1. Disable or uninstall other ad-blocking modules, accessibility skip tools, VPN ad blockers
2. Flash this module zip in Magisk / KernelSU
3. After reboot, access the Web UI:
   - AdGuard Home panel: `http://127.0.0.1:53`
   - SmartDNS panel: `http://127.0.0.1:6053`

## Uninstall

Run `uninstall.sh` to clean up processes, iptables rules, proxy config, and residual files — no leftovers.
