// script_host.go —— 给 aghmitm 提供 JS 脚本执行（Q X / Loon / 小火箭 风格）
//
// 支持全局对象（对齐 Quantumult X / Loon 常用 API 子集）：
//
//	$request  { url, method, headers, body }
//	$response { status, headers, body }
//	$done(obj)     -> 结束本次请求：{ status, headers, body, url } 任一字段生效
//	$notify(title, sub, body)
//	$persistentStore.read(key) / write(value, key)
//	$prefs 同上（Loon 别名）
//
// 脚本匹配：文件内可用一行声明作用域，缺省为全部请求
//
//	// @match ^https?://example\.com/api
//	// @stage response      （可选：request | response；缺省两个阶段都跑）
package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
)

type jsScript struct {
	path  string
	src   string
	match *strings.Builder
	re    []string
	stage string // "request" | "response" | "" (both)
}

var (
	jsMu       sync.RWMutex
	scripts    []jsScript
	quarantine = map[string]time.Time{}
	qMu        sync.Mutex
)

// loadScripts 收集要执行的 JS：
//  1. 目录下的 *.js 与 js/ 子目录里的 *.js（独立脚本，可自带 // @match 限定范围）
//  2. 模块/插件/配置（.module/.plugin/.lpx/.sgmodule/.conf）[Script] 段里
//     用 script-path= 引用的 JS —— 这些 JS 由 CGI 在导入时下载到 js/ 子目录，
//     与模块里的 URL 匹配式绑定，只在该 URL 命中时执行。
func loadScripts(dir string) {
	acc := map[string]*jsScript{}
	var order []string
	add := func(path, src string, pats []string, stage string) {
		if s, ok := acc[path]; ok {
			if len(pats) > 0 {
				s.re = append(s.re, pats...)
			}
			if stage != "" {
				s.stage = stage
			}
			// 由模块绑定过 URL 的脚本，不再按「独立脚本全量匹配」运行
			if len(pats) > 0 && len(s.re) == 0 {
				s.re = pats
			}
			return
		}
		acc[path] = &jsScript{path: path, src: src, re: pats, stage: stage}
		order = append(order, path)
	}

	for _, pat := range []string{filepath.Join(dir, "*.js"), filepath.Join(dir, "js", "*.js")} {
		files, _ := filepath.Glob(pat)
		for _, f := range files {
			b, err := os.ReadFile(f)
			if err != nil {
				continue
			}
			var pats []string
			st := ""
			for _, line := range strings.Split(string(b), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "// @match ") {
					pats = append(pats, strings.TrimSpace(strings.TrimPrefix(line, "// @match ")))
				} else if strings.HasPrefix(line, "// @stage ") {
					v := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(line, "// @stage ")))
					if v == "request" || v == "response" {
						st = v
					}
				}
			}
			add(f, string(b), pats, st)
		}
	}

	var mods []string
	for _, ext := range []string{"*.module", "*.plugin", "*.lpx", "*.sgmodule", "*.conf"} {
		files, _ := filepath.Glob(filepath.Join(dir, ext))
		mods = append(mods, files...)
	}
	for _, m := range mods {
		b, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		inSec := false
		for _, raw := range strings.Split(string(b), "\n") {
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") ||
				strings.HasPrefix(line, ";") || strings.HasPrefix(line, "//") {
				continue
			}
			if strings.HasPrefix(line, "[") {
				sec := strings.ToLower(strings.Trim(line, "[]"))
				inSec = sec == "script" || sec == "rewrite_local" || sec == "url rewrite"
				continue
			}
			if !inSec {
				continue
			}
			ref, pat := refOfScriptLine(line)
			if ref == "" || pat == "" {
				continue
			}
			p := strings.TrimPrefix(ref, "./")
			if !filepath.IsAbs(p) {
				p = filepath.Join(dir, "js", filepath.Base(p))
			}
			jsb, err := os.ReadFile(p)
			if err != nil {
				continue
			}
			st := "request"
			if strings.Contains(strings.ToLower(line), "http-response") || strings.Contains(strings.ToLower(line), "script-response-body") || strings.Contains(strings.ToLower(line), "script-echo-response") {
				st = "response"
			}
			add(p, string(jsb), []string{pat}, st)
		}
	}

	out := make([]jsScript, 0, len(order))
	for _, p := range order {
		out = append(out, *acc[p])
	}
	jsMu.Lock()
	scripts = out
	jsMu.Unlock()
	// 同 rules：只在 JS 脚本集合变化时打日志，别让 5s 心跳刷满 mitm.log
	jsig := strings.Join(order, "|")
	if jsig != lastScriptsLog {
		logf("js scripts loaded: %d", len(out))
		lastScriptsLog = jsig
	}
}

var lastScriptsLog string

// refOfScriptLine 从一行 [Script]/[rewrite_local] 规则里取出
// (脚本引用, URL 匹配式)。兼容：
//
//	Loon/Surge : http-response ^https?:\/\/a\.com\/api script-path=foo.js, requires-body=1
//	QX/小火箭  : ^https?:\/\/a\.com\/api url script-response-body https://x/foo.js
func refOfScriptLine(line string) (js, pat string) {
	fields := strings.FieldsFunc(line, func(r rune) bool {
		return r == ' ' || r == '\t' || r == ','
	})
	for _, f := range fields {
		if strings.HasPrefix(f, "script-path=") {
			js = strings.TrimPrefix(f, "script-path=")
			break
		}
	}
	for _, f := range fields {
		if strings.HasPrefix(f, "^") {
			pat = f
			break
		}
	}
	if pat == "" {
		// Loon/小火箭模块格式：pattern=^https://...（逗号后带空格的情况已被 FieldsFunc 切开）
		for _, f := range fields {
			if strings.HasPrefix(f, "pattern=") {
				pat = strings.TrimPrefix(f, "pattern=")
				break
			}
		}
	}
	if js == "" {
		for _, f := range fields {
			if !strings.HasSuffix(f, ".js") || strings.Contains(f, "=") {
				continue
			}
			js = f
			break
		}
	}
	if pat == "" {
		for _, f := range fields {
			if (strings.HasPrefix(f, "http://") || strings.HasPrefix(f, "https://")) &&
				!strings.HasSuffix(f, ".js") {
				pat = f
				break
			}
		}
	}
	return js, pat
}

type jsResult struct {
	handled bool
	status  int
	headers map[string]string
	body    string
	url     string
	notify  []string
	// 响应阶段脚本改写结果
	respStatus int
	respBody   string
	respHdr    map[string]string
}

// runScripts 依次执行匹配的脚本；后者覆盖前者。
// stage="request"：只跑请求型脚本（http-request / 无类型），$request 可用，$done 短路
// stage="response"：只跑响应型脚本（http-response），$response 带上游真实响应，$done({body}) 改写
func runScripts(url, method string, reqHdr map[string]string, reqBody string, resp *jsResult, stage string) {
	jsMu.RLock()
	list := append([]jsScript(nil), scripts...)
	jsMu.RUnlock()

	for _, s := range list {
		qMu.Lock()
		qUntil, qBad := quarantine[s.path]
		qMu.Unlock()
		if qBad && time.Now().Before(qUntil) {
			continue
		}
		if s.stage != "" && stage != "" && s.stage != stage {
			continue
		}
		if len(s.re) > 0 {
			hit := false
			for _, pat := range s.re {
				if ok, _ := matchPattern(pat, url); ok {
					hit = true
					break
				}
			}
			if !hit {
				continue
			}
		}
		execOne(s, url, method, reqHdr, reqBody, resp, stage)
	}
}

func execOne(s jsScript, url, method string, reqHdr map[string]string, reqBody string, out *jsResult, stage string) {
	vm := goja.New()
	done := false

	vm.Set("console", map[string]interface{}{
		"log": func(args ...interface{}) { logf("js %s: %v", filepath.Base(s.path), args) },
	})
	vm.Set("$request", map[string]interface{}{
		"url":     url,
		"method":  method,
		"headers": reqHdr,
		"body":    reqBody,
	})
	if stage == "response" {
		vm.Set("$response", map[string]interface{}{
			"status":  out.status,
			"headers": out.headers,
			"body":    out.body,
		})
	}
	vm.Set("$notify", func(a ...interface{}) {
		if len(a) > 0 {
			out.notify = append(out.notify, sprint(a...))
		}
	})
	store := map[string]string{}
	vm.Set("$persistentStore", map[string]interface{}{
		"read":  func(k string) string { return store[k] },
		"write": func(v string, k string) bool { store[k] = v; return true },
	})
	vm.Set("$prefs", vm.Get("$persistentStore"))
	vm.Set("$done", func(call goja.FunctionCall) goja.Value {
		done = true
		out.handled = true
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		obj := call.Arguments[0].ToObject(vm)
		if stage == "response" {
			if v := obj.Get("status"); v != nil && !goja.IsUndefined(v) {
				out.respStatus = int(v.ToInteger())
			}
			if v := obj.Get("body"); v != nil && !goja.IsUndefined(v) {
				out.respBody = v.String()
			}
			if hv := obj.Get("headers"); hv != nil && !goja.IsUndefined(hv) {
				ho := hv.ToObject(vm)
				out.respHdr = map[string]string{}
				for _, k := range ho.Keys() {
					out.respHdr[k] = ho.Get(k).String()
				}
			}
			return goja.Undefined()
		}
		if v := obj.Get("status"); v != nil && !goja.IsUndefined(v) {
			out.status = int(v.ToInteger())
		}
		if v := obj.Get("body"); v != nil && !goja.IsUndefined(v) {
			out.body = v.String()
		}
		if v := obj.Get("url"); v != nil && !goja.IsUndefined(v) {
			out.url = v.String()
		}
		if hv := obj.Get("headers"); hv != nil && !goja.IsUndefined(hv) {
			ho := hv.ToObject(vm)
			out.headers = map[string]string{}
			for _, k := range ho.Keys() {
				out.headers[k] = ho.Get(k).String()
			}
		}
		return goja.Undefined()
	})

	// 硬超时：goja 的空循环不落到中断检查点，只在语句边界响应 Interrupt，
	// 所以把执行放进 goroutine，超时直接放弃（协程被丢弃，不再持有请求）。
	fin := make(chan string, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				fin <- "panic"
			}
		}()
		if _, err := vm.RunString(s.src); err != nil {
			fin <- err.Error()
			return
		}
		fin <- ""
	}()

	select {
	case errMsg := <-fin:
		if errMsg != "" && errMsg != "panic" {
			logf("js %s error: %s", filepath.Base(s.path), errMsg)
		}
	case <-time.After(2 * time.Second):
		logf("js %s timeout after 2s (discarded, quarantined 5m)", filepath.Base(s.path))
		qMu.Lock()
		quarantine[s.path] = time.Now().Add(5 * time.Minute)
		qMu.Unlock()
		vm.Interrupt("timeout")
		out.handled = true
		out.status, out.body, out.url = 504, "", ""
		return
	}
	if !done {
		out.handled = false
	}
}
func sprint(a ...interface{}) string {
	var b strings.Builder
	for _, v := range a {
		b.WriteString(toString(v))
	}
	return b.String()
}

func toString(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	default:
		return ""
	}
}
