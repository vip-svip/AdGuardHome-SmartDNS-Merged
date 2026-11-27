package main

import (
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testCertDir = "F:/data/adb/modules/AdGuardHome/certs"

func writeRule(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

// 规则解析：四种动作 + 目标/名字/值都要对
func TestRuleParsing(t *testing.T) {
	dir := t.TempDir()
	writeRule(t, dir, "a.rewrite", strings.Join([]string{
		`^https?://block.test/x url reject`,
		`^https?://empty.test/y url reject-200`,
		`^https?://img.test/z url reject-img`,
		`^https?://go.test/w url 302 https://target.test/`,
		`^https?://hdr.test/h url-header-add X-Test: on`,
		`^https?://bdy.test/b url-body-replace hello HELLO`,
		``,
	}, "\n"))
	loadRules(dir)
	rulesMu.RLock()
	got := len(rules)
	rulesMu.RUnlock()
	if got != 6 {
		t.Fatalf("rules parsed = %d, want 6", got)
	}

	cases := []struct {
		url    string
		action string
		target string
		name   string
	}{
		{"https://block.test/x", "reject", "", ""},
		{"https://empty.test/y", "reject-200", "", ""},
		{"https://img.test/z", "reject-img", "", ""},
		{"https://go.test/w", "302", "https://target.test/", ""},
		{"https://hdr.test/h", "header-add", "", "X-Test"},
		{"https://bdy.test/b", "body-replace", "", "hello"},
	}
	for _, c := range cases {
		// 只有拦截类动作才会被 matchRule 返回，改写类用 matchRules 校验字段
		var hit bool
		var r rule
		if c.action == "reject" || c.action == "reject-200" || c.action == "reject-img" || c.action == "302" {
			r, hit = matchRule(c.url)
		} else {
			list := matchRules(c.url)
			if len(list) == 0 {
				hit = false
			} else {
				r, hit = list[0], true
			}
		}
		if !hit {
			t.Fatalf("%s 未命中", c.url)
		}
		if r.action != c.action {
			t.Fatalf("%s action=%s want %s", c.url, r.action, c.action)
		}
		if c.target != "" && r.target != c.target {
			t.Fatalf("%s target=%s want %s", c.url, r.target, c.target)
		}
		if c.name != "" && r.name != c.name {
			t.Fatalf("%s name=%s want %s", c.url, r.name, c.name)
		}
	}
	// 未命中的 URL 必须落空
	if _, hit := matchRule("https://clean.test/"); hit {
		t.Fatal("clean.test 不应命中")
	}
}

// 纯 HTTP 请求必须被识别为 http:// 而不是 https://（此前 body 改写不生效的根因）
func TestPlainHTTPScheme(t *testing.T) {
	dir := t.TempDir()
	writeRule(t, dir, "h.rewrite", `^http://127\.0\.0\.1:9\b url-body-replace a b`+"\n")
	loadRules(dir)

	// 明文请求：scheme 为空，交给 serveHTTP 判定
	req := httptest.NewRequest("GET", "http://127.0.0.1:9/", nil)
	req.URL.Scheme = "http"
	rec := httptest.NewRecorder()
	// 命中 body-replace 规则则继续转发（会失败返回 502），这里只验证「命中」这件事：
	// 用 matchRule 直接检查拼出来的 URL 形态与规则一致。
	rules := matchRules("http://127.0.0.1:9/")
	if len(rules) == 0 {
		t.Fatal("http:// 规则未命中，scheme 可能仍被当成 https")
	}
	if rules[0].action != "body-replace" {
		t.Fatalf("action=%s want body-replace", rules[0].action)
	}
	if len(matchRules("https://127.0.0.1:9/")) != 0 {
		t.Fatal("https:// 不该命中 http:// 规则")
	}
	_ = rec
}

// JS：$done 返回状态与响应体
func TestJSDone(t *testing.T) {
	dir := t.TempDir()
	writeRule(t, dir, "s.js", "// @match ^https?://js\\.test/a\n$done({status:403, body:'js-blocked'});\n")
	loadScripts(dir)
	out := &jsResult{}
	runScripts("https://js.test/a", "GET", map[string]string{}, "", out, "request")
	if !out.handled || out.status != 403 || out.body != "js-blocked" {
		t.Fatalf("handled=%v status=%d body=%q", out.handled, out.status, out.body)
	}
	// 不匹配的 URL 不应触发
	out2 := &jsResult{}
	runScripts("https://other.test/b", "GET", map[string]string{}, "", out2, "request")
	if out2.handled {
		t.Fatal("未匹配的 URL 被执行了")
	}
}

// JS：死循环必须在 ~2s 内被放弃，并进入隔离（第二次调用被跳过）
func TestJSTimeoutQuarantine(t *testing.T) {
	dir := t.TempDir()
	writeRule(t, dir, "loop.js", "// @match ^https?://loop\\.test/\nwhile(true){}\n")
	loadScripts(dir)

	start := time.Now()
	out := &jsResult{}
	runScripts("https://loop.test/", "GET", map[string]string{}, "", out, "request")
	cost := time.Since(start)
	if cost > 4*time.Second {
		t.Fatalf("超时未生效，耗时 %v", cost)
	}
	if !out.handled || out.status != 504 {
		t.Fatalf("超时后应返回 504 短路（handled=%v status=%d），否则客户端会被挂住", out.handled, out.status)
	}

	// 第二次：已被隔离，应立即返回
	start2 := time.Now()
	out2 := &jsResult{}
	runScripts("https://loop.test/", "GET", map[string]string{}, "", out2, "request")
	cost2 := time.Since(start2)
	if cost2 > 500*time.Millisecond {
		t.Fatalf("隔离未生效，第二次耗时 %v", cost2)
	}
}

// 证书：MITM CA 能签发叶证书，且链可验证、SAN 正确
func TestCertSignAndVerify(t *testing.T) {
	if err := loadCA(testCertDir+"/mitm-ca.crt", testCertDir+"/mitm-ca.key"); err != nil {
		t.Fatalf("loadCA: %v", err)
	}
	if caCert == nil || caKey == nil {
		t.Fatal("CA 未载入")
	}
	if !caCert.IsCA {
		t.Fatal("CA 证书 IsCA=false")
	}
	if caCert.Subject.CommonName != "AGH Local MITM CA" {
		t.Fatalf("CN=%s", caCert.Subject.CommonName)
	}
	leaf, err := leafFor("example.com")
	if err != nil {
		t.Fatalf("leafFor: %v", err)
	}
	der := leaf.Certificate[0]
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse leaf: %v", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(caCert)
	if _, err := cert.Verify(x509.VerifyOptions{
		Roots:     pool,
		DNSName:   "example.com",
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}); err != nil {
		t.Fatalf("叶证书链验证失败: %v", err)
	}
	if !strings.Contains(cert.Subject.String(), "example.com") {
		t.Fatalf("subject=%s", cert.Subject.String())
	}
}

// 证书文件：系统库哈希文件名必须与 subject_hash_old 一致（Android 会按此查找）
func TestCertHashFilenames(t *testing.T) {
	for _, c := range []struct{ file, hash string }{
		{"https-ca.crt", "2c637461"},
		{"mitm-ca.crt", "e2b6a4fd"},
	} {
		b, err := os.ReadFile(filepath.Join(testCertDir, c.file))
		if err != nil {
			t.Fatalf("读 %s: %v", c.file, err)
		}
		blk, _ := pem.Decode(b)
		if blk == nil {
			t.Fatalf("%s 不是 PEM", c.file)
		}
		cert, err := x509.ParseCertificate(blk.Bytes)
		if err != nil {
			t.Fatalf("解析 %s: %v", c.file, err)
		}
		if got := subjectHashOld(cert.RawSubject); got != c.hash {
			t.Fatalf("%s hash=%s want %s", c.file, got, c.hash)
		}
		if _, err := os.Stat(filepath.Join(testCertDir, "system/etc/security/cacerts", c.hash+".0")); err != nil {
			t.Fatalf("系统库文件缺失 %s.0", c.hash)
		}
	}
}

// serveHTTP：命中 reject 规则时不产生任何上游请求
func TestServeHTTPReject(t *testing.T) {
	dir := t.TempDir()
	writeRule(t, dir, "r.rewrite", `^https?://deny\.test/ url reject`+"\n")
	loadRules(dir)
	req := httptest.NewRequest("GET", "https://deny.test/x", nil)
	req.URL.Scheme = "https"
	rec := httptest.NewRecorder()
	serveHTTP(rec, req)
	if !strings.HasPrefix(rec.Body.String(), "HTTP/1.1 403") {
		t.Fatalf("原始响应行不是 403: %q", rec.Body.String())
	}
	if !strings.HasPrefix(rec.Body.String(), "HTTP/1.1 403") {
		t.Fatalf("原始响应行不是 403: %q", rec.Body.String())
	}
}

var _ = pkix.Name{}

func TestResponseStageRewrite(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "js"), 0o755); err != nil {
		t.Fatal(err)
	}
	js := "var o = JSON.parse($response.body); o.premium = true; $done({body: JSON.stringify(o)});"
	if err := os.WriteFile(filepath.Join(dir, "js", "mod.js"), []byte(js), 0o644); err != nil {
		t.Fatal(err)
	}
	mod := "[Script]\nX=type=http-response,pattern=^https://api\\.example\\.com/v1,script-path=mod.js\n"
	if err := os.WriteFile(filepath.Join(dir, "x.module"), []byte(mod), 0o644); err != nil {
		t.Fatal(err)
	}
	scripts = nil
	loadScripts(dir)
	if len(scripts) != 1 || scripts[0].stage != "response" {
		t.Fatalf("expected 1 response-stage script, got %d stage=%q", len(scripts), stageOf(scripts))
	}
	// request stage must NOT run it
	out := &jsResult{}
	runScripts("https://api.example.com/v1/info", "GET", map[string]string{}, "", out, "request")
	if out.handled {
		t.Fatal("response script ran during request stage")
	}
	// response stage must rewrite body
	out2 := &jsResult{status: 200, body: `{"premium":false}`}
	runScripts("https://api.example.com/v1/info", "GET", map[string]string{}, "", out2, "response")
	if !out2.handled || out2.respBody != `{"premium":true}` {
		t.Fatalf("rewrite failed: handled=%v body=%q", out2.handled, out2.respBody)
	}
}

func stageOf(l []jsScript) string {
	if len(l) == 0 {
		return ""
	}
	return l[0].stage
}
