package filtering

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/AdguardTeam/AdGuardHome/internal/aghhttp"
	"github.com/AdguardTeam/AdGuardHome/internal/aghos"
	"github.com/AdguardTeam/AdGuardHome/internal/filtering/rulelist"
	"github.com/AdguardTeam/golibs/errors"
	"github.com/AdguardTeam/golibs/logutil/slogutil"
	"github.com/AdguardTeam/golibs/netutil/urlutil"
	"github.com/miekg/dns"
)

// userFilterDirName is the name of the directory used to store users'
// FS-based rule lists, matching home.userFilterDataDir.
const userFilterDirName = "userfilters"

// validateFilterURL validates the filter list URL or file name.
func (d *DNSFilter) validateFilterURL(urlStr string) (err error) {
	defer func() { err = errors.Annotate(err, "checking filter: %w") }()

	if filepath.IsAbs(urlStr) {
		urlStr = filepath.Clean(urlStr)
		_, err = os.Stat(urlStr)
		if err != nil {
			// The file may not exist yet.  Create an empty rulelist file
			// in place if the path is within the safe FS patterns, so
			// users can add a local file address before filling it.
			if !errors.Is(err, os.ErrNotExist) || !pathMatchesAny(d.safeFSPatterns, urlStr) {
				// Don't wrap the error since it's informative enough as is.
				return err
			}

			file, createErr := os.OpenFile(urlStr, os.O_CREATE|os.O_WRONLY, aghos.DefaultPermFile)
			if createErr != nil {
				return createErr
			}
			file.Close()

			return nil
		}

		if !pathMatchesAny(d.safeFSPatterns, urlStr) {
			return fmt.Errorf("path %q does not match safe patterns", urlStr)
		}

		return nil
	}

	// Treat a bare file name (or a relative path) as a user rulelist file
	// within the workDir's userfilters directory, creating it if needed.
	// This lets users add a local file address such as "mylist.txt" without
	// prefixing the full absolute path.
	if !strings.Contains(urlStr, "://") {
		rel := filepath.Clean("/" + filepath.ToSlash(urlStr))
		if strings.Contains(rel, "..") {
			return fmt.Errorf("relative path %q is not allowed", urlStr)
		}

		full := filepath.Join(d.conf.WorkDir, userFilterDirName, filepath.FromSlash(rel))
		_, statErr := os.Stat(full)
		if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
			return statErr
		}

		if errors.Is(statErr, os.ErrNotExist) {
			mkdirErr := os.MkdirAll(filepath.Dir(full), aghos.DefaultPermDir)
			if mkdirErr != nil {
				return mkdirErr
			}

			file, createErr := os.OpenFile(full, os.O_CREATE|os.O_WRONLY, aghos.DefaultPermFile)
			if createErr != nil {
				return createErr
			}
			file.Close()
		}

		return nil
	}
	u, err := url.ParseRequestURI(urlStr)
	if err != nil {
		// Don't wrap the error, because it's informative enough as is.
		return err
	}

	err = urlutil.ValidateHTTPURL(u)
	if err != nil {
		// Don't wrap the error, because it's informative enough as is.
		return err
	}

	return nil
}

type filterAddJSON struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	Whitelist bool   `json:"whitelist"`
}

// filteringAddFileReq is the request body of the add-file endpoint.  The
// client sends the file contents directly, which is the only reliable way to
// add a local file on Android where the web UI cannot know real filesystem
// paths.
type filteringAddFileReq struct {
	Name      string `json:"name"`
	Content   string `json:"content"`
	Whitelist bool   `json:"whitelist"`
}

// handleFilteringAddFile stores an uploaded filter file and adds it as a
// local filter list.  The file is written into the user filters directory
// under a sanitized version of the given name, and the resulting list is
// registered exactly like a locally-added filter with a file path.
func (d *DNSFilter) handleFilteringAddFile(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	req := &filteringAddFileReq{}
	err := json.NewDecoder(r.Body).Decode(req)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "reading req: %s", err)

		return
	}

	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		req.Name = "imported"
	}

	safeName := sanitizeFilterFileName(req.Name)
	if safeName == "" {
		safeName = "imported"
	}

	if req.Whitelist {
		safeName += "_allow"
	}

	dir := filepath.Join(d.conf.DataDir, "userfilters")
	if mkErr := os.MkdirAll(dir, 0o755); mkErr != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusInternalServerError, "creating dir: %s", mkErr)

		return
	}

	// Pick a free file name.  Re-importing a same-named blocklist used to
	// collide with the existing file and fail with "url already exists".
	filtPath := filepath.Join(dir, safeName+".txt")
	for i := 2; ; i++ {
		if _, statErr := os.Stat(filtPath); statErr != nil {
			break
		}

		filtPath = filepath.Join(dir, fmt.Sprintf("%s-%d.txt", safeName, i))
	}

	if writeErr := os.WriteFile(filtPath, []byte(req.Content), 0o644); writeErr != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusInternalServerError, "writing file: %s", writeErr)

		return
	}

	// Reuse the add-URL logic with the local file path.
	fj := filterAddJSON{
		Name:      req.Name,
		URL:       filtPath,
		Whitelist: req.Whitelist,
	}
	body, jsonErr := json.Marshal(fj)
	if jsonErr != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusInternalServerError, "encoding req: %s", jsonErr)

		return
	}

	r.Body = io.NopCloser(bytes.NewReader(body))
	r.ContentLength = int64(len(body))
	d.handleFilteringAddURL(w, r)
}

func (d *DNSFilter) handleFilteringAddURL(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	fj := filterAddJSON{}
	err := json.NewDecoder(r.Body).Decode(&fj)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			"Failed to parse request body json: %s",
			err,
		)

		return
	}

	err = d.validateFilterURL(fj.URL)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "%s", err)

		return
	}

	// Check for duplicates
	if d.filterExists(fj.URL) {
		err = errFilterExists
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			"Filter with URL %q: %s",
			fj.URL,
			err,
		)

		return
	}

	// Set necessary properties
	filt := FilterYAML{
		Enabled: true,
		URL:     fj.URL,
		Name:    fj.Name,
		white:   fj.Whitelist,
		ID:      d.idGen.next(),
	}

	// Download the filter contents
	ok, err := d.update(&filt)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			"Couldn't fetch filter from URL %q: %s",
			filt.URL,
			err,
		)

		return
	}

	// Local rulelist files (absolute paths) are allowed to be empty when
	// added: the user creates the entry first and fills the file later, so
	// a zero-rule count must not reject the addition.
	if !ok && !filepath.IsAbs(filt.URL) {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			"Filter with URL %q is invalid (maybe it points to blank page?)",
			filt.URL,
		)

		return
	}

	// URL is assumed valid so append it to filters, update config, write new
	// file and reload it to engines.
	err = d.filterAdd(filt)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			"Filter with URL %q: %s",
			filt.URL,
			err,
		)

		return
	}

	d.conf.ConfModifier.Apply(ctx)
	d.EnableFilters(true)

	_, err = fmt.Fprintf(w, "OK %d rules\n", filt.RulesCount)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusInternalServerError,
			"Couldn't write body: %s",
			err,
		)
	}
}

func (d *DNSFilter) handleFilteringRemoveURL(w http.ResponseWriter, r *http.Request) {
	type request struct {
		URL       string `json:"url"`
		Whitelist bool   `json:"whitelist"`
	}

	ctx := r.Context()

	req := request{}
	err := json.NewDecoder(r.Body).Decode(&req)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			d.logger,
			r,
			w,
			http.StatusBadRequest,
			"failed to parse request body json: %s",
			err,
		)

		return
	}

	var deleted FilterYAML
	func() {
		d.conf.filtersMu.Lock()
		defer d.conf.filtersMu.Unlock()

		filters := &d.conf.Filters
		if req.Whitelist {
			filters = &d.conf.WhitelistFilters
		}

		delIdx := slices.IndexFunc(*filters, func(flt FilterYAML) bool {
			return flt.URL == req.URL
		})
		if delIdx == -1 {
			d.logger.ErrorContext(
				ctx,
				"deleting filter",
				"url", req.URL,
				slogutil.KeyError, errFilterNotExist,
			)

			return
		}

		deleted = (*filters)[delIdx]
		p := deleted.Path(d.conf.DataDir)
		err = os.Rename(p, p+".old")
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			d.logger.ErrorContext(
				ctx,
				"renaming filter file",
				"id", deleted.ID,
				"path", p,
				slogutil.KeyError, err,
			)

			return
		}

		*filters = slices.Delete(*filters, delIdx, delIdx+1)

		d.logger.InfoContext(ctx, "deleted filter", "id", deleted.ID)
	}()

	d.conf.ConfModifier.Apply(ctx)
	d.EnableFilters(true)

	// NOTE: The old files "filter.txt.old" aren't deleted.  It's not really
	// necessary, but will require the additional complicated code to run
	// after enableFilters is done.
	//
	// TODO(a.garipov): Make sure the above comment is true.

	_, err = fmt.Fprintf(w, "OK %d rules\n", deleted.RulesCount)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			d.logger,
			r,
			w,
			http.StatusInternalServerError,
			"couldn't write body: %s",
			err,
		)
	}
}

type filterURLReqData struct {
	Name    string `json:"name"`
	URL     string `json:"url"`
	Enabled bool   `json:"enabled"`
}

type filterURLReq struct {
	Data      *filterURLReqData `json:"data"`
	URL       string            `json:"url"`
	Whitelist bool              `json:"whitelist"`
}

func (d *DNSFilter) handleFilteringSetURL(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	fj := filterURLReq{}
	err := json.NewDecoder(r.Body).Decode(&fj)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "decoding request: %s", err)

		return
	}

	if fj.Data == nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			"%s",
			errors.Error("data is absent"),
		)

		return
	}

	err = d.validateFilterURL(fj.Data.URL)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "invalid url: %s", err)

		return
	}

	filt := FilterYAML{
		Enabled: fj.Data.Enabled,
		Name:    fj.Data.Name,
		URL:     fj.Data.URL,
	}

	restart, err := d.filterSetProperties(fj.URL, filt, fj.Whitelist)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "%s", err)

		return
	}

	d.conf.ConfModifier.Apply(ctx)
	if restart {
		d.EnableFilters(true)
	}
}

// filteringRulesReq is the JSON structure for settings custom filtering rules.
type filteringRulesReq struct {
	Rules []string `json:"rules"`
}

func (d *DNSFilter) handleFilteringSetRules(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	if aghhttp.WriteTextPlainDeprecated(ctx, d.logger, w, r) {
		return
	}

	req := &filteringRulesReq{}
	err := json.NewDecoder(r.Body).Decode(req)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, d.logger, r, w, http.StatusBadRequest, "reading req: %s", err)

		return
	}

	d.conf.UserRules = req.Rules
	d.conf.ConfModifier.Apply(ctx)
	d.EnableFilters(true)
}

// filteringViewFileReq is the request body for the view_file endpoint.
type filteringViewFileReq struct {
	URL string `json:"url"`
}

// maxViewFileBytes is the maximum number of bytes read from a rule list file
// when it is shown in the browser.
const maxViewFileBytes = 4 << 20

// resolveFilterFilePath returns the on-disk path of the rule list file behind
// the given filter URL, refreshing the cached copy when it's missing.
func (d *DNSFilter) resolveFilterFilePath(ctx context.Context, urlStr string) (fltPath string, err error) {
	var fltCopy FilterYAML
	var fltFound bool
	d.conf.filtersMu.RLock()
	filters := d.conf.Filters
	filters = append(filters, d.conf.WhitelistFilters...)
	idx := slices.IndexFunc(filters, func(flt FilterYAML) bool {
		return flt.URL == urlStr
	})
	if idx != -1 {
		fltCopy = filters[idx]
		fltFound = true
	}
	d.conf.filtersMu.RUnlock()

	if !fltFound {
		return "", fmt.Errorf("filter not found: %s", urlStr)
	}

	fltPath = fltCopy.Path(d.conf.DataDir)

	// Local filters (added by a file path or by an uploaded file) are edited
	// at the URL itself, so show that file rather than its parsed cache copy.
	if filepath.IsAbs(urlStr) {
		if _, urlStat := os.Stat(urlStr); urlStat == nil {
			return resolveRealPath(urlStr), nil
		}
	}

	if _, stErr := os.Stat(fltPath); stErr != nil {
		// The cache file may be missing right after the filter was added but
		// not yet refreshed.  Fetch it once before giving up.
		if _, updErr := d.update(&fltCopy); updErr != nil {
			return "", fmt.Errorf("filter file not found and refresh failed: %s: %w", fltPath, updErr)
		}

		if _, stErr = os.Stat(fltPath); stErr != nil {
			return "", fmt.Errorf("filter file not found: %s", fltPath)
		}
	}

	// The data directories of the module are symlinks into the module's own
	// rules directory, so resolve them to report the file where it really
	// lives instead of the internal path used to reach it.
	return resolveRealPath(fltPath), nil
}

// resolveRealPath returns p with the symlinks of the module data directories
// resolved, so the reported path is where the file really lives.
func resolveRealPath(p string) (real string) {
	if resolved, err := filepath.EvalSymlinks(p); err == nil {
		return resolved
	}

	return p
}

// viewFileComponents lists the activities that are tried, in order, when a
// rule list file living in a root-only directory has to be opened.  MT Manager
// reads /data/adb directly and opens the file in its text editor, so the
// button jumps to the real file instead of a copy in shared storage.
var viewFileComponents = []string{
	"bin.mt.plus/.OpenTextActivity",
	"bin.mt.plus/.OpenFileActivity",
}

// launchFileViewer opens path in a local app via ACTION_VIEW.
func launchFileViewer(ctx context.Context, path string) (err error) {
	uri := "file://" + path

	for _, comp := range viewFileComponents {
		out, execErr := exec.CommandContext(
			ctx, "am", "start",
			"-a", "android.intent.action.VIEW",
			"-d", uri,
			"-t", "text/plain",
			"-n", comp,
		).CombinedOutput()
		if execErr == nil && !bytes.Contains(out, []byte("Error")) {
			return nil
		}

		err = errors.Annotate(execErr, "starting %s: %w", comp)
	}

	out, execErr := exec.CommandContext(
		ctx, "am", "start",
		"-a", "android.intent.action.VIEW",
		"-d", uri,
		"-t", "text/plain",
	).CombinedOutput()
	if execErr != nil || bytes.Contains(out, []byte("Error")) {
		return fmt.Errorf("starting viewer: %w: %s", execErr, out)
	}

	return nil
}

// handleFilteringViewFile opens the rule list file at its real location with a
// local viewer app.  Nothing is copied to shared storage, so the app shows the
// file that actually lives in the module directory.
func (d *DNSFilter) handleFilteringViewFile(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	req := &filteringViewFileReq{}
	err := json.NewDecoder(r.Body).Decode(req)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "reading req: %s", err)

		return
	}

	fltPath, err := d.resolveFilterFilePath(ctx, req.URL)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "%s", err)

		return
	}

	absPath, absErr := filepath.Abs(fltPath)
	if absErr == nil {
		fltPath = absPath
	}

	var size int64
	if fi, stErr := os.Stat(fltPath); stErr == nil {
		size = fi.Size()
	}

	if launchErr := launchFileViewer(ctx, fltPath); launchErr != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusInternalServerError, "opening %q: %s", fltPath, launchErr)

		return
	}

	l.InfoContext(ctx, "opened filter file", "path", fltPath, "size", size)

	aghhttp.WriteJSONResponseOK(ctx, l, w, r, struct {
		OK   bool   `json:"ok"`
		Path string `json:"path"`
		Size int64  `json:"size"`
	}{OK: true, Path: fltPath, Size: size})
}

// handleFilteringViewFileRaw renders the rule list file in place, so that the
// Web UI shows the file that actually lives in the module directory instead of
// a copy in shared storage.
func (d *DNSFilter) handleFilteringViewFileRaw(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	urlStr := r.URL.Query().Get("url")
	if urlStr == "" {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "empty url")

		return
	}

	fltPath, err := d.resolveFilterFilePath(ctx, urlStr)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "%s", err)

		return
	}

	f, err := os.Open(fltPath)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusInternalServerError, "opening %q: %s", fltPath, err)

		return
	}
	defer func() { _ = f.Close() }()

	content, err := io.ReadAll(io.LimitReader(f, maxViewFileBytes+1))
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusInternalServerError, "reading %q: %s", fltPath, err)

		return
	}

	truncated := len(content) > maxViewFileBytes
	if truncated {
		content = content[:maxViewFileBytes]
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")

	_, _ = w.Write(buildFilterFilePage(fltPath, content, truncated))

	l.InfoContext(ctx, "rendered filter file", "path", fltPath, "bytes", len(content))
}

// buildFilterFilePage returns a small standalone page showing the rule list
// file content together with its on-disk path.
func buildFilterFilePage(fltPath string, content []byte, truncated bool) (page []byte) {
	var b bytes.Buffer

	b.WriteString("<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">")
	b.WriteString("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
	b.WriteString("<title>")
	b.WriteString(html.EscapeString(filepath.Base(fltPath)))
	b.WriteString("</title><style>")
	b.WriteString(":root{color-scheme:light dark}body{margin:0;padding:0;font:14px/1.5 -apple-system,'Segoe UI',Roboto,sans-serif;")
	b.WriteString("background:#f6f7f9;color:#111}header{position:sticky;top:0;background:#fff;border-bottom:1px solid #e3e6ea;padding:10px 14px}")
	b.WriteString("h1{font-size:14px;margin:0 0 4px;font-weight:600}.p{font:12px/1.4 ui-monospace,Menlo,Consolas,monospace;color:#4a5560;")
	b.WriteString("word-break:break-all}.m{font-size:12px;color:#8b95a1;margin-top:4px}pre{margin:0;padding:14px;white-space:pre-wrap;")
	b.WriteString("word-break:break-all;font:12.5px/1.6 ui-monospace,Menlo,Consolas,monospace;background:#fff}")
	b.WriteString("@media(prefers-color-scheme:dark){body{background:#16181c;color:#e6e8eb}header{background:#1e2126;border-color:#2c3138}")
	b.WriteString("pre{background:#1e2126}.p{color:#a8b2bd}.m{color:#7c8794}}")
	b.WriteString("</style></head><body><header><h1>")
	b.WriteString(html.EscapeString(filepath.Base(fltPath)))
	b.WriteString("</h1><div class=\"p\">")
	b.WriteString(html.EscapeString(fltPath))
	b.WriteString("</div><div class=\"m\">")
	b.WriteString(fmt.Sprintf("%d 字节", len(content)))
	if truncated {
		b.WriteString("（已截断，仅显示前 4 MB）")
	}
	b.WriteString(" · 直接编辑该文件即可生效</div></header><pre>")
	b.WriteString(html.EscapeString(string(content)))
	b.WriteString("</pre></body></html>")

	return b.Bytes()
}

// copyFile copies the file at src to dst in chunks.
func copyFile(src, dst string) (err error) {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("opening: %w", err)
	}
	defer func() { err = errors.WithDeferred(err, in.Close()) }()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, aghos.DefaultPermFile)
	if err != nil {
		return fmt.Errorf("creating: %w", err)
	}
	defer func() { err = errors.WithDeferred(err, out.Close()) }()

	_, err = io.Copy(out, in)

	return err
}

func (d *DNSFilter) handleFilteringRefresh(w http.ResponseWriter, r *http.Request) {
	type Req struct {
		White bool `json:"whitelist"`
	}
	var err error

	ctx := r.Context()
	l := d.logger

	req := Req{}
	err = json.NewDecoder(r.Body).Decode(&req)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "json decode: %s", err)

		return
	}

	var ok bool
	resp := struct {
		Updated int `json:"updated"`
	}{}
	resp.Updated, _, ok = d.tryRefreshFilters(!req.White, req.White, true)
	if !ok {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusInternalServerError,
			"filters update procedure is already running",
		)

		return
	}

	aghhttp.WriteJSONResponseOK(ctx, l, w, r, resp)
}

type filterJSON struct {
	URL         string `json:"url"`
	Name        string `json:"name"`
	LastUpdated string `json:"last_updated,omitempty"`

	ID rulelist.APIID `json:"id"`

	RulesCount uint64 `json:"rules_count"`
	Enabled    bool   `json:"enabled"`
}

type filteringConfig struct {
	Filters          []filterJSON `json:"filters"`
	WhitelistFilters []filterJSON `json:"whitelist_filters"`
	UserRules        []string     `json:"user_rules"`
	Interval         uint32       `json:"interval"` // in hours
	Enabled          bool         `json:"enabled"`
}

func filterToJSON(f FilterYAML) filterJSON {
	fj := filterJSON{
		// #nosec G115 -- The overflow is required for backwards compatibility.
		ID:      rulelist.APIID(f.ID),
		Enabled: f.Enabled,
		URL:     f.URL,
		Name:    f.Name,
		// #nosec G115 -- The number of rules must not be negative.
		RulesCount: uint64(f.RulesCount),
	}

	if !f.LastUpdated.IsZero() {
		fj.LastUpdated = f.LastUpdated.Format(time.RFC3339)
	}

	return fj
}

// Get filtering configuration
func (d *DNSFilter) handleFilteringStatus(w http.ResponseWriter, r *http.Request) {
	resp := filteringConfig{}
	d.conf.filtersMu.RLock()
	resp.Enabled = d.conf.FilteringEnabled
	resp.Interval = d.conf.FiltersUpdateIntervalHours
	for _, f := range d.conf.Filters {
		fj := filterToJSON(f)
		resp.Filters = append(resp.Filters, fj)
	}
	for _, f := range d.conf.WhitelistFilters {
		fj := filterToJSON(f)
		resp.WhitelistFilters = append(resp.WhitelistFilters, fj)
	}
	resp.UserRules = d.conf.UserRules
	d.conf.filtersMu.RUnlock()

	aghhttp.WriteJSONResponseOK(r.Context(), d.logger, w, r, resp)
}

// Set filtering configuration
func (d *DNSFilter) handleFilteringConfig(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	req := filteringConfig{}
	err := json.NewDecoder(r.Body).Decode(&req)
	if err != nil {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "json decode: %s", err)

		return
	}

	if !ValidateUpdateIvl(req.Interval) {
		aghhttp.ErrorAndLog(ctx, l, r, w, http.StatusBadRequest, "Unsupported interval")

		return
	}

	func() {
		d.conf.filtersMu.Lock()
		defer d.conf.filtersMu.Unlock()

		d.conf.FilteringEnabled = req.Enabled
		d.conf.FiltersUpdateIntervalHours = req.Interval
	}()

	d.conf.ConfModifier.Apply(ctx)
	d.EnableFilters(true)
}

type checkHostRespRule struct {
	Text string `json:"text"`

	FilterListID rulelist.APIID `json:"filter_list_id"`
}

type checkHostResp struct {
	Reason string `json:"reason"`

	// Rule is the text of the matched rule.
	//
	// Deprecated: Use Rules[*].Text.
	Rule string `json:"rule"`

	Rules []*checkHostRespRule `json:"rules"`

	// for Rewrite:
	CanonName string       `json:"cname"`    // CNAME value
	IPList    []netip.Addr `json:"ip_addrs"` // list of IP addresses

	// FilterID is the ID of the rule's filter list.
	//
	// Deprecated: Use Rules[*].FilterListID.
	FilterID rulelist.APIID `json:"filter_id"`
}

// handleCheckHost is the handler for the GET /control/filtering/check_host HTTP
// API.
func (d *DNSFilter) handleCheckHost(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l := d.logger

	query := r.URL.Query()
	host := query.Get("name")
	if host == "" {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusBadRequest,
			`query parameter "name" is required`,
		)

		return
	}

	qTypeStr := query.Get("qtype")
	qType, err := stringToDNSType(qTypeStr)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusUnprocessableEntity,
			"bad qtype query parameter: %q",
			qTypeStr,
		)

		return
	}

	setts := d.Settings()
	setts.FilteringEnabled = true
	setts.ProtectionEnabled = true

	cli := query.Get("client")
	addr, err := netip.ParseAddr(cli)
	if err == nil {
		d.ApplyAdditionalFiltering(addr, "", setts)
	} else if cli != "" {
		// TODO(s.chzhen):  Set [Settings.ClientName] once urlfilter supports
		// multiple client names.  This will handle the case when a rule exists
		// but the persistent client does not.
		d.ApplyAdditionalFiltering(netip.Addr{}, cli, setts)
	}

	result, err := d.CheckHost(host, qType, setts)
	if err != nil {
		aghhttp.ErrorAndLog(
			ctx,
			l,
			r,
			w,
			http.StatusInternalServerError,
			"couldn't apply filtering: %s: %s",
			host,
			err,
		)

		return
	}

	rulesLen := len(result.Rules)
	resp := checkHostResp{
		Reason:    result.Reason.String(),
		CanonName: result.CanonName,
		IPList:    result.IPList,
		Rules:     make([]*checkHostRespRule, len(result.Rules)),
	}

	if rulesLen > 0 {
		resp.FilterID = result.Rules[0].FilterListID
		resp.Rule = result.Rules[0].Text
	}

	for i, r := range result.Rules {
		resp.Rules[i] = &checkHostRespRule{
			FilterListID: r.FilterListID,
			Text:         r.Text,
		}
	}

	aghhttp.WriteJSONResponseOK(ctx, l, w, r, resp)
}

// stringToDNSType is a helper function that converts a string to DNS type.  If
// the string is empty, it returns the default value [dns.TypeA].
func stringToDNSType(str string) (qtype uint16, err error) {
	if str == "" {
		return dns.TypeA, nil
	}

	qtype, ok := dns.StringToType[str]
	if ok {
		return qtype, nil
	}

	// typePref is a prefix for DNS types from experimental RFCs.
	const typePref = "TYPE"

	if !strings.HasPrefix(str, typePref) {
		return 0, errors.ErrBadEnumValue
	}

	val, err := strconv.ParseUint(str[len(typePref):], 10, 16)
	if err != nil {
		return 0, errors.ErrBadEnumValue
	}

	return uint16(val), nil
}

// setProtectedBool sets the value of a boolean pointer under a lock.  l must
// protect the value under ptr.
//
// TODO(e.burkov):  Make it generic?
func setProtectedBool(mu *sync.RWMutex, ptr *bool, val bool) {
	mu.Lock()
	defer mu.Unlock()

	*ptr = val
}

// protectedBool gets the value of a boolean pointer under a read lock.  l must
// protect the value under ptr.
//
// TODO(e.burkov):  Make it generic?
func protectedBool(mu *sync.RWMutex, ptr *bool) (val bool) {
	mu.RLock()
	defer mu.RUnlock()

	return *ptr
}

// handleSafeBrowsingEnable is the handler for the POST
// /control/safebrowsing/enable HTTP API.
func (d *DNSFilter) handleSafeBrowsingEnable(w http.ResponseWriter, r *http.Request) {
	setProtectedBool(d.confMu, &d.conf.SafeBrowsingEnabled, true)
	d.conf.ConfModifier.Apply(r.Context())
}

// handleSafeBrowsingDisable is the handler for the POST
// /control/safebrowsing/disable HTTP API.
func (d *DNSFilter) handleSafeBrowsingDisable(w http.ResponseWriter, r *http.Request) {
	setProtectedBool(d.confMu, &d.conf.SafeBrowsingEnabled, false)
	d.conf.ConfModifier.Apply(r.Context())
}

// handleSafeBrowsingStatus is the handler for the GET
// /control/safebrowsing/status HTTP API.
func (d *DNSFilter) handleSafeBrowsingStatus(w http.ResponseWriter, r *http.Request) {
	resp := &struct {
		Enabled bool `json:"enabled"`
	}{
		Enabled: protectedBool(d.confMu, &d.conf.SafeBrowsingEnabled),
	}

	aghhttp.WriteJSONResponseOK(r.Context(), d.logger, w, r, resp)
}

// handleParentalEnable is the handler for the POST /control/parental/enable
// HTTP API.
func (d *DNSFilter) handleParentalEnable(w http.ResponseWriter, r *http.Request) {
	setProtectedBool(d.confMu, &d.conf.ParentalEnabled, true)
	d.conf.ConfModifier.Apply(r.Context())
}

// handleParentalDisable is the handler for the POST /control/parental/disable
// HTTP API.
func (d *DNSFilter) handleParentalDisable(w http.ResponseWriter, r *http.Request) {
	setProtectedBool(d.confMu, &d.conf.ParentalEnabled, false)
	d.conf.ConfModifier.Apply(r.Context())
}

// handleParentalStatus is the handler for the GET /control/parental/status
// HTTP API.
func (d *DNSFilter) handleParentalStatus(w http.ResponseWriter, r *http.Request) {
	resp := &struct {
		Enabled bool `json:"enabled"`
	}{
		Enabled: protectedBool(d.confMu, &d.conf.ParentalEnabled),
	}

	aghhttp.WriteJSONResponseOK(r.Context(), d.logger, w, r, resp)
}

// RegisterFilteringHandlers - register handlers
func (d *DNSFilter) RegisterFilteringHandlers() {
	registerHTTP := d.conf.HTTPReg.Register

	registerHTTP(http.MethodPost, "/control/safebrowsing/enable", d.handleSafeBrowsingEnable)
	registerHTTP(http.MethodPost, "/control/safebrowsing/disable", d.handleSafeBrowsingDisable)
	registerHTTP(http.MethodGet, "/control/safebrowsing/status", d.handleSafeBrowsingStatus)

	registerHTTP(http.MethodPost, "/control/parental/enable", d.handleParentalEnable)
	registerHTTP(http.MethodPost, "/control/parental/disable", d.handleParentalDisable)
	registerHTTP(http.MethodGet, "/control/parental/status", d.handleParentalStatus)

	registerHTTP(http.MethodGet, "/control/rewrite/list", d.handleRewriteList)
	registerHTTP(http.MethodGet, "/control/rewrite/settings", d.handleRewriteSettings)
	registerHTTP(http.MethodPost, "/control/rewrite/add", d.handleRewriteAdd)
	registerHTTP(http.MethodPost, "/control/rewrite/delete", d.handleRewriteDelete)
	registerHTTP(http.MethodPut, "/control/rewrite/settings/update", d.handleRewriteSettingsUpdate)
	registerHTTP(http.MethodPut, "/control/rewrite/update", d.handleRewriteUpdate)

	registerHTTP(http.MethodGet, "/control/filtering/status", d.handleFilteringStatus)
	registerHTTP(http.MethodPost, "/control/filtering/config", d.handleFilteringConfig)
	registerHTTP(http.MethodPost, "/control/filtering/add_url", d.handleFilteringAddURL)
	registerHTTP(http.MethodPost, "/control/filtering/add_file", d.handleFilteringAddFile)
	registerHTTP(http.MethodPost, "/control/filtering/remove_url", d.handleFilteringRemoveURL)
	registerHTTP(http.MethodPost, "/control/filtering/set_url", d.handleFilteringSetURL)
	registerHTTP(http.MethodPost, "/control/filtering/refresh", d.handleFilteringRefresh)
	registerHTTP(http.MethodPost, "/control/filtering/set_rules", d.handleFilteringSetRules)
	registerHTTP(http.MethodPost, "/control/filtering/view_file", d.handleFilteringViewFile)
	registerHTTP(http.MethodGet, "/control/filtering/view_file_raw", d.handleFilteringViewFileRaw)
	registerHTTP(http.MethodGet, "/control/filtering/check_host", d.handleCheckHost)
}

// maxUpdateIvlHours is the maximum allowed filter update interval in hours.
const maxUpdateIvlHours = 365 * 24

// ValidateUpdateIvl returns false if i is not a valid filters update interval.
func ValidateUpdateIvl(i uint32) (ok bool) {
	return i <= maxUpdateIvlHours
}
