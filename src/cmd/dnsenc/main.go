// dnsenc —— 本地加密 DNS 转发器（给 SmartDNS 当加密上游用）
//
// 背景：模块内置的 smartdns 构建没有编译 TLS，server-tls / server-https 无法工作。
// 本程序在 127.0.0.1 上开一个普通 UDP/TCP DNS 端口，把查询转给加密上游
// （DoH / DoH3 / DoT / DoQ / DNSCrypt），SmartDNS 只需加一行 server 127.0.0.1:6054。
//
// 用法：
//   dnsenc -listen 127.0.0.1:6054 -conf /path/encrypted.conf
//   dnsenc -probe -conf /path/encrypted.conf
//
// 配置文件每行一条（# 开头为注释）：
//   doh  https://dns.alidns.com/dns-query
//   dot  dns.alidns.com
//   doq  dns.adguard-dns.com
//   h3   dns.google/dns-query
//   sdns sdns://AQcAAAAAAAA...
//   也接受直接写完整 URL：https://dns.alidns.com/dns-query
//
// 按域名分流：在任意一条后面加 "@域名1,域名2"，这条上游就只承接这些域名的查询
// （后缀匹配，按 . 边界，*.google.com 等价 google.com）。没有 @ 的上游是全局上游，
// 只在不命中任何分流规则时才使用；全是分流规则时，未命中的域名会用全部上游兜底。
//
//   doh  https://dns.google/dns-query        @google.com,googleapis.com,youtube.com
//   doh  https://cloudflare-dns.com/dns-query @cloudflare.com,github.com
//   doh  https://dns.alidns.com/dns-query
package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AdguardTeam/dnsproxy/upstream"
	"github.com/miekg/dns"
)

const (
	defaultListen    = "127.0.0.1:6054"
	defaultTimeout   = 5 * time.Second
	defaultBootstrap = "223.5.5.5:53"
)

var schemeAlias = map[string]string{
	"doh":      "https",
	"doh3":     "h3",
	"h3":       "h3",
	"https":    "https",
	"dot":      "tls",
	"tls":      "tls",
	"doq":      "quic",
	"quic":     "quic",
	"dnscrypt": "sdns",
	"sdns":     "sdns",
	"udp":      "udp",
	"tcp":      "tcp",
}

// entry 是一条已连接的加密上游。
type entry struct {
	raw    string
	url    string
	domains []string // 空 = 全局上游；非空 = 只接这些域名（后缀匹配）
	up     upstream.Upstream
	addr   string
	queries atomic.Int64
	ok     atomic.Int64
	fail   atomic.Int64
	lastMs atomic.Int64
}

// splitDomains 抽出行内的 "@a.com,b.com" 域名限定，返回剩余部分与域名列表。
func splitDomains(raw string) (line string, domains []string) {
	var keep []string
	for _, tok := range strings.Fields(raw) {
		if strings.HasPrefix(tok, "@") {
			for _, d := range strings.Split(tok[1:], ",") {
				d = strings.ToLower(strings.TrimSpace(d))
				d = strings.TrimPrefix(d, "*.")
				d = strings.Trim(d, ".")
				if d != "" {
					domains = append(domains, d)
				}
			}
			continue
		}
		keep = append(keep, tok)
	}
	return strings.Join(keep, " "), domains
}

// domainMatch 后缀匹配：name 等于 s，或 name 以 ".s" 结尾。
func domainMatch(name string, suffixes []string) bool {
	name = strings.ToLower(strings.TrimSuffix(dns.Fqdn(name), "."))
	if name == "" {
		return false
	}
	for _, sfx := range suffixes {
		if sfx == "" {
			continue
		}
		if name == sfx || strings.HasSuffix(name, "."+sfx) {
			return true
		}
	}
	return false
}

// normalize 把配置行归一化成 dnsproxy 能识别的 URL。
func normalize(raw string) (urlStr string, err error) {
	line := strings.TrimSpace(raw)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", errors.New("empty")
	}
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return "", errors.New("empty")
	}
	first := fields[0]
	if strings.Contains(first, "://") {
		return line, nil
	}
	scheme, ok := schemeAlias[strings.ToLower(first)]
	if !ok {
		return "", fmt.Errorf("未知协议别名 %q（可用 doh/dot/doq/h3/sdns/udp/tcp）", first)
	}
	if len(fields) < 2 {
		return "", fmt.Errorf("%q 后面缺少地址", first)
	}
	addr := strings.TrimSpace(fields[1])
	// 用户可能写成 "doh https://dns.alidns.com/dns-query"，此时地址已带协议
	if strings.Contains(addr, "://") {
		return addr, nil
	}
	return scheme + "://" + addr, nil
}

// loadRoots 组装 CA 池。Android 的证书在 /system/etc/security/cacerts，
// 而本程序按 linux 构建，Go 默认只找 /etc/ssl/certs，所以这里显式补目录。
func loadRoots() (pool *x509.CertPool) {
	pool, err := x509.SystemCertPool()
	if pool == nil || err != nil {
		pool = x509.NewCertPool()
	}
	dirs := []string{
		"/system/etc/security/cacerts",
		"/apex/com.android.conscrypt/cacerts",
		"/data/misc/keychain/cacerts-added",
		"/etc/ssl/certs",
	}
	for _, d := range dirs {
		ents, derr := os.ReadDir(d)
		if derr != nil {
			continue
		}
		for _, e := range ents {
			if e.IsDir() {
				continue
			}
			b, rerr := os.ReadFile(filepath.Join(d, e.Name()))
			if rerr != nil {
				continue
			}
			pool.AppendCertsFromPEM(b)
		}
	}
	return pool
}

// loadUpstreams 读取配置文件并建立连接。
func loadUpstreams(path string, timeout time.Duration, bootstrap string) (entries []*entry, errs []string, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	opts := &upstream.Options{
		Logger:     logger,
		Timeout:    timeout,
		RootCAs:    loadRoots(),
		HTTPVersions: []upstream.HTTPVersion{
			upstream.HTTPVersion2,
			upstream.HTTPVersion11,
		},
	}
	if bootstrap != "" {
		if r, rerr := upstream.NewUpstreamResolver(bootstrap, &upstream.Options{
			Logger:  logger,
			Timeout: timeout,
		}); rerr == nil {
			opts.Bootstrap = r
		} else {
			errs = append(errs, "bootstrap "+bootstrap+" 不可用: "+rerr.Error())
		}
	}

	for _, raw := range strings.Split(string(data), "\n") {
		line, doms := splitDomains(raw)
		u, nerr := normalize(line)
		if nerr != nil {
			if strings.TrimSpace(raw) != "" && !strings.HasPrefix(strings.TrimSpace(raw), "#") {
				errs = append(errs, fmt.Sprintf("%s -> %v", strings.TrimSpace(raw), nerr))
			}
			continue
		}
		up, uerr := upstream.AddressToUpstream(u, opts)
		if uerr != nil {
			errs = append(errs, fmt.Sprintf("%s -> %v", u, uerr))
			continue
		}
		e := &entry{raw: strings.TrimSpace(raw), url: u, domains: doms, up: up}
		e.addr = up.Address()
		entries = append(entries, e)
	}
	return entries, errs, nil
}

// proxy 把一次查询并行发给所有加密上游，取第一个有效答复。
type proxy struct {
	entries []*entry
	timeout time.Duration
}

var errNoUpstream = errors.New("没有可用的加密上游")

// pick 按查询域名挑上游：命中分流规则 → 只用命中的；否则 → 全局上游；再无 → 全部兜底。
func (p *proxy) pick(name string) (list []*entry) {
	if len(p.entries) == 0 {
		return nil
	}
	var hit, globals []*entry
	for _, e := range p.entries {
		if len(e.domains) == 0 {
			globals = append(globals, e)
			continue
		}
		if domainMatch(name, e.domains) {
			hit = append(hit, e)
		}
	}
	if len(hit) > 0 {
		return hit
	}
	if len(globals) > 0 {
		return globals
	}
	return p.entries
}

func (p *proxy) exchange(ctx context.Context, req *dns.Msg) (resp *dns.Msg, err error) {
	list := p.pick(qname(req))
	if len(list) == 0 {
		return nil, errNoUpstream
	}
	type result struct {
		e   *entry
		msg *dns.Msg
		err error
		ms  int64
	}
	ch := make(chan result, len(list))
	for _, e := range list {
		go func(e *entry) {
			e.queries.Add(1)
			start := time.Now()
			msg, xerr := e.up.Exchange(ctx, req)
			ms := time.Since(start).Milliseconds()
			if xerr != nil || msg == nil {
				e.fail.Add(1)
			} else {
				e.ok.Add(1)
				e.lastMs.Store(ms)
			}
			ch <- result{e: e, msg: msg, err: xerr, ms: ms}
		}(e)
	}
	deadline := time.NewTimer(p.timeout)
	defer deadline.Stop()

	var softFail *dns.Msg
	for i := 0; i < len(list); i++ {
		select {
		case r := <-ch:
			if r.err != nil || r.msg == nil {
				continue
			}
			switch r.msg.Rcode {
			case dns.RcodeSuccess, dns.RcodeNameError:
				return r.msg, nil
			default:
				if softFail == nil {
					softFail = r.msg
				}
			}
		case <-deadline.C:
			if softFail != nil {
				return softFail, nil
			}
			return nil, errors.New("所有加密上游超时")
		}
	}
	if softFail != nil {
		return softFail, nil
	}
	return nil, errors.New("所有加密上游均失败")
}

// warmup 在启动后立刻对每条上游发一次握手查询。
// DoH/DoT/DoQ 的 TLS/QUIC 握手是首次查询的主要延迟（实测冷启首查 5.4s，预热后 100-200ms）。
func (p *proxy) warmup(ctx context.Context, name string) {
	req := new(dns.Msg)
	req.SetQuestion(dns.Fqdn(name), dns.TypeA)
	req.RecursionDesired = true
	for _, e := range p.entries {
		go func(e *entry) {
			start := time.Now()
			msg, err := e.up.Exchange(ctx, req)
			ms := time.Since(start).Milliseconds()
			if err == nil && msg != nil {
				e.lastMs.Store(ms)
			}
		}(e)
	}
}

func (p *proxy) close() {
	for _, e := range p.entries {
		_ = e.up.Close()
	}
}

func main() {
	var (
		listen    = flag.String("listen", defaultListen, "监听地址")
		conf      = flag.String("conf", "", "加密上游配置文件")
		timeoutF  = flag.Duration("timeout", defaultTimeout, "单次上游超时")
		bootstrap = flag.String("bootstrap", defaultBootstrap, "解析 DoH/DoT 域名用的明文上游")
		probe     = flag.Bool("probe", false, "探测每条上游的可用性与延迟（输出 JSON）")
		probeName = flag.String("probe-name", "www.baidu.com", "探测用域名")
		verbose   = flag.Bool("v", false, "打印每次查询日志")
		warm      = flag.Bool("warm", true, "启动后预热各上游（消除首个查询的 TLS/QUIC 握手延迟）")
		warmName  = flag.String("warm-name", "www.baidu.com", "预热用域名")
	)
	flag.Parse()

	if *conf == "" {
		fmt.Fprintln(os.Stderr, "缺少 -conf")
		os.Exit(2)
	}

	entries, errs, err := loadUpstreams(*conf, *timeoutF, *bootstrap)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取配置失败: %v\n", err)
		os.Exit(2)
	}

	if *probe {
		ctx := context.Background()
		out := struct {
			OK    bool `json:"ok"`
			Count int  `json:"count"`
			Items []map[string]any `json:"items"`
			Errs  []string          `json:"errors,omitempty"`
		}{Errs: errs}
		for _, e := range entries {
			req := new(dns.Msg)
			req.SetQuestion(dns.Fqdn(*probeName), dns.TypeA)
			req.RecursionDesired = true
			start := time.Now()
			msg, xerr := e.up.Exchange(ctx, req)
			ms := time.Since(start).Milliseconds()
			it := map[string]any{
				"raw": e.raw,
				"url": e.url,
				"ms":  ms,
			}
			if len(e.domains) > 0 {
				it["domains"] = e.domains
				it["match"] = domainMatch(*probeName, e.domains)
			} else {
				it["domains"] = []string{}
				it["match"] = true
			}
			if xerr != nil || msg == nil {
				it["ok"] = false
				if xerr != nil {
					it["error"] = xerr.Error()
				} else {
					it["error"] = "空响应"
				}
			} else {
				it["ok"] = true
				it["rcode"] = dns.RcodeToString[msg.Rcode]
				var ips []string
				for _, a := range msg.Answer {
					if ar, isA := a.(*dns.A); isA {
						ips = append(ips, ar.A.String())
					}
					if aaaa, isAAAA := a.(*dns.AAAA); isAAAA {
						ips = append(ips, aaaa.AAAA.String())
					}
				}
				it["answer"] = ips
			}
			out.Items = append(out.Items, it)
		}
		out.Count = len(entries)
		out.OK = len(entries) > 0 && len(errs) == 0
		b, _ := json.Marshal(out)
		fmt.Println(string(b))
		for _, e := range entries {
			_ = e.up.Close()
		}
		return
	}

	if len(entries) == 0 {
		fmt.Fprintln(os.Stderr, "配置文件里没有可用的加密上游: "+*conf)
		for _, s := range errs {
			fmt.Fprintln(os.Stderr, "  "+s)
		}
		os.Exit(3)
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	logger.Info("dnsenc starting", "listen", *listen, "upstreams", len(entries))
	for _, e := range entries {
		logger.Info("upstream", "raw", e.raw, "addr", e.addr, "domains", e.domains)
	}
	for _, s := range errs {
		logger.Warn("skipped", "detail", s)
	}

	px := &proxy{entries: entries, timeout: *timeoutF}
	defer px.close()

	handler := dns.HandlerFunc(func(w dns.ResponseWriter, req *dns.Msg) {
		resp, xerr := px.exchange(context.Background(), req)
		if xerr != nil {
			m := new(dns.Msg)
			m.SetRcode(req, dns.RcodeServerFailure)
			_ = w.WriteMsg(m)
			if *verbose {
				logger.Warn("query failed", "name", qname(req), "err", xerr)
			}
			return
		}
		resp.Id = req.Id
		_ = w.WriteMsg(resp)
		if *verbose {
			logger.Info("query", "name", qname(req), "rcode", dns.RcodeToString[resp.Rcode])
		}
	})

	// 同步绑定：端口被占立刻失败退出，避免"报错但仍活着"的僵尸进程
	pc, err := net.ListenPacket("udp", *listen)
	if err != nil {
		logger.Error("bind udp failed", "addr", *listen, "err", err)
		os.Exit(4)
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		_ = pc.Close()
		logger.Error("bind tcp failed", "addr", *listen, "err", err)
		os.Exit(4)
	}
	logger.Info("listening", "addr", *listen)

	udpSrv := &dns.Server{PacketConn: pc, Handler: handler}
	tcpSrv := &dns.Server{Listener: ln, Handler: handler}

	go func() {
		if *warm {
			px.warmup(context.Background(), *warmName)
		}
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if serr := udpSrv.ActivateAndServe(); serr != nil {
			logger.Error("udp serve ended", "err", serr)
		}
	}()
	go func() {
		defer wg.Done()
		if serr := tcpSrv.ActivateAndServe(); serr != nil {
			logger.Error("tcp serve ended", "err", serr)
		}
	}()
	wg.Wait()
}

func qname(req *dns.Msg) string {
	if req == nil || len(req.Question) == 0 {
		return ""
	}
	return req.Question[0].Name
}

func waitListen(addr string, d time.Duration, logger *slog.Logger) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("udp", addr, 200*time.Millisecond)
		if err == nil {
			_ = c.Close()
			logger.Info("listening", "addr", addr)
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	logger.Warn("listen check timed out", "addr", addr)
}

// 保证 netip / context 被引用（bootstrap 相关接口预留）
var _ = netip.Addr{}
var _ = context.Background
