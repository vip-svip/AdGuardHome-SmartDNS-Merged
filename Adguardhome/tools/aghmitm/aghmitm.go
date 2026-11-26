// aghmitm：设备侧 MITM 转发器
//   - 用模块内置 MITM CA 动态签发叶证书，做 TLS 解密
//   - 按 .rewrite / .plugin / .conf 里的 URL 重写规则对请求做处置：
//     url reject / reject-200 / reject-img   -> 403 或空响应
//     url 302 <target>                        -> 302 跳转
//     header 增删                             -> 改写请求头
//   - 纯标准库，静态交叉编译到 linux/arm64
package main

import (
	"bufio"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"context"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

type rule struct {
	re     *regexp.Regexp
	action string
	target string
	name   string
	value  string
}

var dialer = &net.Dialer{Timeout: 10 * time.Second}
var (
	rulesMu sync.RWMutex
	rules   []rule

	caCert *x509.Certificate
	caKey  *rsa.PrivateKey

	leafMu sync.Mutex
	leaves = map[string]*tls.Certificate{}
)

func flatten(h http.Header) map[string]string {
	m := map[string]string{}
	for k, vs := range h {
		if len(vs) > 0 {
			m[k] = vs[0]
		}
	}
	return m
}
func logf(format string, a ...interface{}) { log.Printf(format, a...) }

func matchPattern(pat, s string) (bool, error) {
	re, err := regexp.Compile(pat)
	if err != nil {
		return false, err
	}
	return re.MatchString(s), nil
}
func loadCA(crtPath, keyPath string) error {
	cb, err := os.ReadFile(crtPath)
	if err != nil {
		return err
	}
	kb, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	cbk, _ := pem.Decode(cb)
	if cbk == nil {
		return fmt.Errorf("bad ca pem")
	}
	c, err := x509.ParseCertificate(cbk.Bytes)
	if err != nil {
		return err
	}
	kbk, _ := pem.Decode(kb)
	if kbk == nil {
		return fmt.Errorf("bad key pem")
	}
	k, err := x509.ParsePKCS1PrivateKey(kbk.Bytes)
	if err != nil {
		return err
	}
	caCert, caKey = c, k
	return nil
}

// 载入规则：扫描目录下 .rewrite/.plugin/.conf/.sgmodule
func loadRules(dir string) {
	var out []rule
	files, _ := filepath.Glob(filepath.Join(dir, "*"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
				continue
			}
			if strings.HasPrefix(line, "[") || strings.HasPrefix(line, "hostname") {
				continue
			}
			low := strings.ToLower(line)
			if !strings.Contains(low, "url") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) < 3 {
				continue
			}
			pat, act := fields[0], strings.ToLower(fields[1]+" "+fields[2])
			target := ""
			if len(fields) >= 4 {
				target = fields[3]
			}
			var r rule
			switch {
			case strings.Contains(act, "reject-200"):
				r = rule{action: "reject-200"}
			case strings.Contains(act, "reject-img"):
				r = rule{action: "reject-img"}
			case strings.Contains(act, "reject"):
				r = rule{action: "reject"}
			case strings.Contains(act, "302"):
				r = rule{action: "302", target: target}
			case strings.Contains(act, "header-add") || strings.Contains(act, "header-request-add"):
				// ^url url-header-add Name: Value   （fields: [pat, action, Name:, Value...]）
				if len(fields) < 4 {
					continue
				}
				nv := strings.Join(fields[2:], " ")
				nm, val := nv, ""
				if k := strings.Index(nv, ":"); k > 0 {
					nm, val = strings.TrimSpace(nv[:k]), strings.TrimSpace(nv[k+1:])
				}
				r = rule{action: "header-add", name: nm, value: val}
			case strings.Contains(act, "header-del") || strings.Contains(act, "header-request-del"):
				if len(fields) < 3 {
					continue
				}
				r = rule{action: "header-del", name: fields[2]}
			case strings.Contains(act, "body-replace"):
				// ^url url-body-replace OLD NEW
				if len(fields) < 4 {
					continue
				}
				r = rule{action: "body-replace", name: fields[2], value: strings.Join(fields[3:], " ")}
			default:
				continue
			}
			re, err := regexp.Compile(pat)
			if err != nil {
				continue
			}
			r.re = re
			out = append(out, r)
		}
	}
	rulesMu.Lock()
	rules = out
	rulesMu.Unlock()
	log.Printf("rules loaded: %d", len(out))
}

func matchRule(rawURL string) (rule, bool) {
	for _, r := range matchRules(rawURL) {
		if r.action == "reject" || r.action == "reject-200" || r.action == "reject-img" || r.action == "302" {
			return r, true
		}
	}
	return rule{}, false
}

// matchRules 返回所有命中的规则，供 header/body 叠加使用
func matchRules(rawURL string) []rule {
	rulesMu.RLock()
	defer rulesMu.RUnlock()
	var hit []rule
	for _, r := range rules {
		if r.re.MatchString(rawURL) {
			hit = append(hit, r)
		}
	}
	return hit
}

func leafFor(host string) (*tls.Certificate, error) {
	leafMu.Lock()
	defer leafMu.Unlock()
	if c, ok := leaves[host]; ok {
		return c, nil
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 126))
	tpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host, Organization: []string{"AGH MITM"}},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(1, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{host},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	c := &tls.Certificate{Certificate: [][]byte{der, caCert.Raw}, PrivateKey: key}
	leaves[host] = c
	return c, nil
}

// bufferedConn：包装连接，读取时优先走已缓冲的字节
type bufferedConn struct {
	net.Conn
	br *bufio.Reader
}

func (b *bufferedConn) Read(p []byte) (int, error) {
	if b.br != nil {
		return b.br.Read(p)
	}
	return b.Conn.Read(p)
}

// tlsServer 用模块 MITM CA 按 SNI 动态签发叶证书（透明 TLS 模式）
func tlsServer(c net.Conn, br *bufio.Reader) *tls.Conn {
	return tls.Server(&bufferedConn{Conn: c, br: br}, &tls.Config{
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			return leafFor(hello.ServerName)
		},
		NextProtos: []string{"http/1.1"},
	})
}

func serveTLS(c net.Conn, br *bufio.Reader) {
	tc := tlsServer(c, br)
	if err := tc.Handshake(); err != nil {
		log.Printf("transparent handshake failed: %v", err)
		return
	}
	log.Printf("transparent TLS ok: sni handshake")
	for {
		req, err := http.ReadRequest(bufio.NewReader(tc))
		if err != nil {
			log.Printf("transparent read failed: %v", err)
			return
		}
		serveHTTP(tc, req)
	}
}

func handleConn(c net.Conn, tlsPort string) {
	defer c.Close()
	br := bufio.NewReader(c)
	// 透明 TLS：iptables REDIRECT 进来的是原始 TLS 握手，首字节 0x16
	if b, err := br.ReadByte(); err == nil && b == 0x16 {
		log.Printf("transparent TLS enter")
		br.UnreadByte()
		serveTLS(c, br)
		return
	} else if err == nil {
		br.UnreadByte()
	}
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	if req.Method != http.MethodConnect {
		// 明文 HTTP：直接按规则处理
		req.URL.Scheme = "http"
		serveHTTP(c, req)
		return
	}
	host := req.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	fmt.Fprintf(c, "HTTP/1.1 200 Connection Established\r\n\r\n")
	if _, ok := matchRule("https://" + host + "/"); ok {
		// 域名级命中：仍解密以便按路径细分
	}
	crt, err := leafFor(host)
	if err != nil {
		return
	}
	tc := tls.Server(c, &tls.Config{Certificates: []tls.Certificate{*crt}, NextProtos: []string{"http/1.1"}})
	if err := tc.Handshake(); err != nil {
		return
	}
	tbr := bufio.NewReader(tc)
	for {
		ir, err := http.ReadRequest(tbr)
		if err != nil {
			return
		}
		ir.URL.Scheme = "https"
		ir.URL.Host = host
		if !serveHTTP(tc, ir) {
			return
		}
	}
}

// 返回 false 表示连接结束
func serveHTTP(w io.Writer, req *http.Request) bool {
	scheme := "https"
	if req.URL.Scheme == "http" || req.TLS == nil && req.URL.Scheme == "" {
		scheme = "https"
	}
	if req.URL.Scheme == "http" {
		scheme = "http"
	}
	full := scheme + "://" + req.Host + req.URL.RequestURI()
	if r, ok := matchRule(full); ok {
		switch r.action {
		case "302":
			fmt.Fprintf(w, "HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\n\r\n", r.target)
		case "reject-img":
			body := "\x89PNG\r\n\x1a\n"
			fmt.Fprintf(w, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: %d\r\n\r\n%s", len(body), body)
		case "reject-200":
			fmt.Fprint(w, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
		default:
			fmt.Fprint(w, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
		}
		log.Printf("BLOCK %s action=%s", full, r.action)
		return true
	}

	// 改写类规则：请求头增删 + 响应体替换
	var bodyFrom, bodyTo string
	haveBodyRule := false
	for _, r := range matchRules(full) {
		switch r.action {
		case "header-add":
			req.Header.Set(r.name, r.value)
			log.Printf("HDR-ADD %s %s=%s", full, r.name, r.value)
		case "header-del":
			req.Header.Del(r.name)
			log.Printf("HDR-DEL %s %s", full, r.name)
		case "body-replace":
			bodyFrom, bodyTo, haveBodyRule = r.name, r.value, true
			log.Printf("BODY-REPLACE %s %q->%q", full, r.name, r.value)
		}
	}

	// JS 脚本：$request / $done 可短路或改写
	jsr := &jsResult{headers: map[string]string{}}
	runScripts(full, req.Method, flatten(req.Header), "", jsr)
	if jsr.handled && (jsr.status > 0 || jsr.body != "" || jsr.url != "") {
		st := jsr.status
		if st == 0 {
			st = 200
		}
		body := jsr.body
		fmt.Fprintf(w, "HTTP/1.1 %d %s\r\nContent-Length: %d\r\n", st, http.StatusText(st), len(body))
		for k, v := range jsr.headers {
			fmt.Fprintf(w, "%s: %s\r\n", k, v)
		}
		fmt.Fprint(w, "\r\n")
		io.WriteString(w, body)
		log.Printf("JS-DONE %s status=%d len=%d", full, st, len(body))
		return true
	}

	// 转发到真实站点
	outReq, err := http.NewRequest(req.Method, full, req.Body)
	if err != nil {
		fmt.Fprint(w, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		return true
	}
	for k, vs := range req.Header {
		for _, v := range vs {
			outReq.Header.Add(k, v)
		}
	}
	tr := &http.Transport{
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: true},
		ForceAttemptHTTP2:   false,
		DialContext:         dialer.DialContext,
	}
	resp, err := tr.RoundTrip(outReq)
	if err != nil {
		log.Printf("upstream error for %s: %v", full, err)
	}
	if err != nil {
		fmt.Fprint(w, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		return true
	}
	defer resp.Body.Close()
	hdr := resp.Header.Clone()
	hdr.Set("Content-Length", fmt.Sprintf("%d", resp.ContentLength))
	if resp.ContentLength < 0 {
		hdr.Del("Content-Length")
	}
	fmt.Fprintf(w, "HTTP/1.1 %d %s\r\n", resp.StatusCode, http.StatusText(resp.StatusCode))
	hdr.Write(w)
	fmt.Fprint(w, "\r\n")
	if haveBodyRule {
		body, _ := io.ReadAll(resp.Body)
		s := strings.ReplaceAll(string(body), bodyFrom, bodyTo)
		io.WriteString(w, s)
		return true
	}
	io.Copy(w, resp.Body)
	return true
}

func main() {
	listen := flag.String("listen", "127.0.0.1:8899", "listen addr")
	crt := flag.String("ca", "/data/adb/modules/AdGuardHome/certs/mitm-ca.crt", "CA cert")
	key := flag.String("key", "/data/adb/modules/AdGuardHome/certs/mitm-ca.key", "CA key")
	dir := flag.String("rules", "/data/adb/agh/scripts/rewrite", "rules dir")
	dns := flag.String("dns", "127.0.0.1:5353", "resolver (AGH dns port)")
	flag.Parse()

	runtime.GOMAXPROCS(4)
	if err := loadCA(*crt, *key); err != nil {
		log.Fatalf("load ca: %v", err)
	}
	// 用 AGH 的 DNS 端口做解析（Android 的 ::1:53 无人监听）
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return dialer.DialContext(ctx, "udp", *dns)
	}}
	loadRules(*dir)
	loadScripts(*dir)
	go func() {
		for {
			time.Sleep(5 * time.Second)
			// 用 AGH 的 DNS 端口做解析（Android 的 ::1:53 无人监听）
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return dialer.DialContext(ctx, "udp", *dns)
	}}
	loadRules(*dir)
	loadScripts(*dir)
		}
	}()

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("aghmitm listening %s (ca=%s)", *listen, filepath.Base(*crt))
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleConn(c, "")
	}
}

// subjectHashOld：Android 系统信任库按 <MD5(subject DER) 前4字节小端>.0 命名
func subjectHashOld(der []byte) string {
	sum := md5.Sum(der)
	return fmt.Sprintf("%02x%02x%02x%02x", sum[3], sum[2], sum[1], sum[0])
}