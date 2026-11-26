// script_host.go —— 给 aghmitm 提供 JS 脚本执行（Q X / Loon / 小火箭 风格）
//
// 支持全局对象（对齐 Quantumult X / Loon 常用 API 子集）：
//   $request  { url, method, headers, body }
//   $response { status, headers, body }
//   $done(obj)     -> 结束本次请求：{ status, headers, body, url } 任一字段生效
//   $notify(title, sub, body)
//   $persistentStore.read(key) / write(value, key)
//   $prefs 同上（Loon 别名）
//
// 脚本匹配：文件内可用一行声明作用域，缺省为全部请求
//   // @match ^https?://example\.com/api
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
}

var (
	jsMu       sync.RWMutex
	scripts    []jsScript
	quarantine = map[string]time.Time{}
	qMu        sync.Mutex
)

// loadScripts 扫描目录下 *.js，读取 @match 声明
func loadScripts(dir string) {
	var out []jsScript
	files, _ := filepath.Glob(filepath.Join(dir, "*.js"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		s := jsScript{path: f, src: string(b)}
		for _, line := range strings.Split(s.src, "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "// @match ") {
				s.re = append(s.re, strings.TrimSpace(strings.TrimPrefix(line, "// @match ")))
			}
		}
		out = append(out, s)
	}
	jsMu.Lock()
	scripts = out
	jsMu.Unlock()
	logf("js scripts loaded: %d", len(out))
}

type jsResult struct {
	handled bool
	status  int
	headers map[string]string
	body    string
	url     string
	notify  []string
}

// runScripts 依次执行匹配的脚本；后者覆盖前者
func runScripts(url, method string, reqHdr map[string]string, reqBody string, resp *jsResult) {
	jsMu.RLock()
	list := append([]jsScript(nil), scripts...)
	jsMu.RUnlock()

	for _, s := range list {
		qMu.Lock(); qUntil, qBad := quarantine[s.path]; qMu.Unlock()
		if qBad && time.Now().Before(qUntil) {
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
		execOne(s, url, method, reqHdr, reqBody, resp)
	}
}

func execOne(s jsScript, url, method string, reqHdr map[string]string, reqBody string, out *jsResult) {
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
		qMu.Lock(); quarantine[s.path] = time.Now().Add(5 * time.Minute); qMu.Unlock()
		vm.Interrupt("timeout")
		out.handled = false
		out.status, out.body, out.url = 0, "", ""
		return
	}
	if !done {
		return
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