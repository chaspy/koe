package core

import (
	"archive/zip"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCheckDue(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		last time.Time
		want bool
	}{
		{time.Time{}, true},
		{now, false},
		{now.Add(-59 * time.Second), false},
		{now.Add(-time.Minute), true},
		{now.Add(-3 * time.Hour), true},
		{now.Add(time.Minute), false}, // clock went back
	}
	for _, c := range cases {
		if got := CheckDue(c.last, now, MenuCheckInterval); got != c.want {
			t.Errorf("CheckDue(%v) = %v, want %v", now.Sub(c.last), got, c.want)
		}
	}
}

func TestNewerVersion(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"0.1.2", "0.1.1", true},
		{"0.1.1", "0.1.1", false},
		{"0.1.0", "0.1.1", false},
		{"0.10.0", "0.9.9", true},
		{"1.0", "0.99.99", true},
		{"0.2", "0.2.0", false},
		{"0.2.1", "0.2", true},
		{"v0.2.0", "0.1.9", true},
		{"0.2.0-beta", "0.1.9", true},
		{"0.1.1", "dev", true},
		{"", "0.0.1", false},
	}
	for _, c := range cases {
		if got := NewerVersion(c.a, c.b); got != c.want {
			t.Errorf("NewerVersion(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestTagFromLocation(t *testing.T) {
	cases := map[string]string{
		"https://github.com/o/r/releases/tag/v0.3.1":  "v0.3.1",
		"https://github.com/o/r/releases/tag/v0.3.1/": "v0.3.1",
		"/o/r/releases/tag/0.4":                       "0.4",
		"https://github.com/o/r/releases/tag/v1%2B2":  "v1+2",
		"https://github.com/o/r/releases":             "",
		"https://github.com/o/r/releases/tag/":        "",
		"https://github.com/o/r/releases/tag/a/b":     "",
		"https://github.com/login?return_to=x":        "",
	}
	for in, want := range cases {
		u, _ := url.Parse(in)
		tag, ok := TagFromLocation(u)
		if tag != want || ok != (want != "") {
			t.Errorf("TagFromLocation(%q) = %q %v, want %q", in, tag, ok, want)
		}
	}
	if WindowsAssetName("0.3.1") != "Koe-0.3.1-windows-x64.zip" {
		t.Fatal(WindowsAssetName("0.3.1"))
	}
}

func TestLatestRelease(t *testing.T) {
	var ua, method string
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ua, method = r.Header.Get("User-Agent"), r.Method
		paths = append(paths, r.URL.Path)
		switch r.URL.Path {
		case "/o/r/releases/latest":
			http.Redirect(w, r, "http://"+r.Host+"/o/r/releases/tag/v0.2.0", http.StatusFound)
		case "/o/rel/releases/latest": // relative Location
			w.Header().Set("Location", "/o/rel/releases/tag/0.4")
			w.WriteHeader(http.StatusFound)
		case "/o/none/releases/latest":
			http.Redirect(w, r, "/o/none/releases", http.StatusFound)
		case "/o/r/releases/download/v0.2.0/Koe-0.2.0-windows-x64.zip":
			// the real one redirects to the file host; must not be followed
			http.Redirect(w, r, "http://127.0.0.1:1/asset", http.StatusFound)
		case "/o/rel/releases/download/0.4/Koe-0.4-windows-x64.zip":
			w.WriteHeader(http.StatusOK)
		case "/o/plain/releases/latest", "/o/r/releases/download/v9/Koe-9-windows-x64.zip":
			w.WriteHeader(http.StatusOK)
		case "/o/missing/releases/latest", "/o/none/releases/download/v1/Koe-1-windows-x64.zip":
			http.NotFound(w, r)
		default:
			w.WriteHeader(http.StatusTooManyRequests)
		}
	}))
	defer srv.Close()
	ctx := context.Background()
	r, err := LatestRelease(ctx, srv.URL, "o/r", "Koe-test/1")
	want := Release{Version: "0.2.0", Tag: "v0.2.0", Page: srv.URL + "/o/r/releases/tag/v0.2.0",
		Asset: "Koe-0.2.0-windows-x64.zip", AssetURL: srv.URL + "/o/r/releases/download/v0.2.0/Koe-0.2.0-windows-x64.zip"}
	if err != nil || r != want || ua != "Koe-test/1" || method != http.MethodHead {
		t.Fatalf("got %#v %v ua=%q method=%s", r, err, ua, method)
	}
	if len(paths) != 1 {
		t.Fatalf("redirect was followed: %v", paths)
	}
	if err := WindowsAssetExists(ctx, r, "x"); err != nil {
		t.Fatal("302 asset", err)
	}
	r, err = LatestRelease(ctx, srv.URL, "o/rel", "x")
	if err != nil || r.Version != "0.4" || r.Page != srv.URL+"/o/rel/releases/tag/0.4" {
		t.Fatalf("relative: %#v %v", r, err)
	}
	if err := WindowsAssetExists(ctx, r, "x"); err != nil {
		t.Fatal("200 asset", err)
	}
	for _, repo := range []string{"o/none", "o/missing"} {
		if r, err := LatestRelease(ctx, srv.URL, repo, "x"); err != nil || r.Tag != "" {
			t.Fatalf("%s: got %#v %v", repo, r, err)
		}
	}
	if _, err := LatestRelease(ctx, srv.URL, "o/plain", "x"); err == nil {
		t.Fatal("200 without redirect must be an error")
	}
	if _, err := LatestRelease(ctx, srv.URL, "o/limited", "x"); err == nil || !strings.Contains(err.Error(), "429") {
		t.Fatalf("want HTTP 429 error, got %v", err)
	}
	noAsset := Release{Asset: "Koe-1-windows-x64.zip", AssetURL: srv.URL + "/o/none/releases/download/v1/Koe-1-windows-x64.zip"}
	if err := WindowsAssetExists(ctx, noAsset, "x"); !errors.Is(err, ErrNoWindowsAsset) {
		t.Fatal("404 asset", err)
	}
	noAsset.AssetURL = srv.URL + "/o/other/x.zip"
	if err := WindowsAssetExists(ctx, noAsset, "x"); err == nil || errors.Is(err, ErrNoWindowsAsset) {
		t.Fatal("429 asset", err)
	}
}

func writeZip(t *testing.T, path string, files map[string]string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(body))
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
}

func TestExtractZipAndFindAppRoot(t *testing.T) {
	dir := t.TempDir()
	zp := filepath.Join(dir, "Koe-windows-x64.zip")
	writeZip(t, zp, map[string]string{
		"Koe/":                    "",
		"Koe/Koe.exe":             "exe",
		"Koe/whisper-server.exe":  "srv",
		"Koe/packs/developer.txt": "GitHub\n",
	})
	stage := filepath.Join(dir, "stage")
	if err := ExtractZip(zp, stage); err != nil {
		t.Fatal(err)
	}
	root, err := FindAppRoot(stage, "Koe.exe")
	if err != nil || root != filepath.Join(stage, "Koe") {
		t.Fatalf("root=%q err=%v", root, err)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "packs", "developer.txt")); string(b) != "GitHub\n" {
		t.Fatalf("pack = %q", b)
	}

	// flat zip
	flat := filepath.Join(dir, "flat.zip")
	writeZip(t, flat, map[string]string{"Koe.exe": "exe"})
	fs := filepath.Join(dir, "flat")
	if err := ExtractZip(flat, fs); err != nil {
		t.Fatal(err)
	}
	if root, err := FindAppRoot(fs, "Koe.exe"); err != nil || root != fs {
		t.Fatalf("flat root=%q err=%v", root, err)
	}

	// no Koe.exe
	bad := filepath.Join(dir, "bad.zip")
	writeZip(t, bad, map[string]string{"Other/readme.txt": "x"})
	bs := filepath.Join(dir, "bad")
	if err := ExtractZip(bad, bs); err != nil {
		t.Fatal(err)
	}
	if _, err := FindAppRoot(bs, "Koe.exe"); err == nil {
		t.Fatal("want error when Koe.exe is missing")
	}

	// zip slip
	evil := filepath.Join(dir, "evil.zip")
	writeZip(t, evil, map[string]string{"../escaped.txt": "x"})
	if err := ExtractZip(evil, filepath.Join(dir, "evil")); err == nil {
		t.Fatal("want error for an entry outside the destination")
	}
	if _, err := os.Stat(filepath.Join(dir, "escaped.txt")); err == nil {
		t.Fatal("file escaped the destination")
	}
}

func TestUpdatePending(t *testing.T) {
	p := filepath.Join(t.TempDir(), "update-pending.json")
	if _, ok := TakeUpdatePending(p); ok {
		t.Fatal("no marker yet")
	}
	want := UpdatePending{From: "0.1.1", To: "0.2.0", Page: "https://example.invalid", At: time.Unix(0, 0).UTC().Format(time.RFC3339)}
	if err := WriteUpdatePending(p, want); err != nil {
		t.Fatal(err)
	}
	got, ok := TakeUpdatePending(p)
	if !ok || got != want {
		t.Fatalf("got %#v %v", got, ok)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatal("marker should be removed")
	}
}

func TestUpdateScript(t *testing.T) {
	b := UpdateScriptCRLF()
	for i, c := range b {
		if c > 0x7E && c != '\r' && c != '\n' {
			t.Fatalf("non-ASCII byte at %d", i)
		}
	}
	s := string(b)
	if strings.Contains(strings.ReplaceAll(s, "\r\n", ""), "\n") {
		t.Fatal("bare LF in script")
	}
	for _, want := range []string{"%KOE_PID%", `"%KOE_SRC%" "%KOE_DST%" /E`, `rmdir /S /Q "%KOE_WORK%"`, `"%KOE_DST%\Koe.exe"`} {
		if !strings.Contains(s, want) {
			t.Errorf("script lacks %q", want)
		}
	}
	if strings.Contains(s, "/MIR") || strings.Contains(s, "/PURGE") {
		t.Error("script must not delete files in the install folder")
	}
}

func TestConfigUpdateDefaults(t *testing.T) {
	c, err := ParseConfig([]byte(`{}`))
	if err != nil || !c.UpdateCheck || c.UpdateRepo != DefaultUpdateRepo {
		t.Fatalf("%v %v %q", err, c.UpdateCheck, c.UpdateRepo)
	}
	c, _ = ParseConfig([]byte(`{"updateCheck": false, "updateRepo": " me/fork/ "}`))
	if c.UpdateCheck || c.UpdateRepo != "me/fork" {
		t.Fatalf("%v %q", c.UpdateCheck, c.UpdateRepo)
	}
	c, _ = ParseConfig([]byte(`{"updateRepo": "nonsense"}`))
	if c.UpdateRepo != DefaultUpdateRepo {
		t.Fatalf("%q", c.UpdateRepo)
	}
}

func TestSetConfigValue(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(p, []byte(`{"hotkey": "ralt", "futureKey": {"a": 1}, "prompt": "x & y"}`), 0o644)
	if err := SetConfigValue(p, "hotkey", "rctrl"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	c, err := ParseConfig(b)
	if err != nil || c.Hotkey != "rctrl" || c.Prompt != "x & y" {
		t.Fatalf("%v %#v", err, c)
	}
	if !strings.Contains(string(b), "futureKey") {
		t.Fatalf("unknown key dropped: %s", b)
	}
	// missing file is created
	p2 := filepath.Join(t.TempDir(), "sub", "config.json")
	if err := SetConfigValue(p2, "hotkey", "rctrl"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p2); !strings.Contains(string(b), `"rctrl"`) {
		t.Fatalf("%s", b)
	}
	// broken JSON is not overwritten
	os.WriteFile(p, []byte(`{broken`), 0o644)
	if err := SetConfigValue(p, "hotkey", "ralt"); err == nil {
		t.Fatal("want error for broken JSON")
	}
}

func TestHotkeyVKAndSetHotkey(t *testing.T) {
	if HotkeyVK("ralt") != 0xA5 || HotkeyVK("rctrl") != 0xA3 || HotkeyVK("x") != 0xA5 {
		t.Fatal("vk")
	}
	h := HoldTracker{HotkeyVK: 0xA5, MinHold: 300 * time.Millisecond}
	t0 := time.Now()
	if h.Down(0xA5, t0) != ActStart {
		t.Fatal("start")
	}
	h.SetHotkey(0xA3)
	if h.Holding() {
		t.Fatal("press should be forgotten")
	}
	if act, _ := h.Up(0xA5, t0.Add(time.Second)); act != ActNone {
		t.Fatalf("old key release: %v", act)
	}
	if h.Down(0xA3, t0.Add(2*time.Second)) != ActStart {
		t.Fatal("new key start")
	}
	if act, _ := h.Up(0xA3, t0.Add(3*time.Second)); act != ActFinish {
		t.Fatalf("new key finish: %v", act)
	}
}
