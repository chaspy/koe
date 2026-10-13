package core

import (
	"archive/zip"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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

const releaseJSON = `{
  "tag_name": "v0.2.0",
  "html_url": "https://github.com/o/r/releases/tag/v0.2.0",
  "assets": [
    {"name": "Koe-0.2.0.dmg", "browser_download_url": "https://example.invalid/Koe-0.2.0.dmg"},
    {"name": "Koe-0.2.0-windows-x64.zip", "browser_download_url": "https://example.invalid/Koe-0.2.0-windows-x64.zip"}
  ]
}`

func TestParseLatestRelease(t *testing.T) {
	r, err := ParseLatestRelease([]byte(releaseJSON))
	if err != nil {
		t.Fatal(err)
	}
	want := Release{Version: "0.2.0", Tag: "v0.2.0", Page: "https://github.com/o/r/releases/tag/v0.2.0",
		AssetURL: "https://example.invalid/Koe-0.2.0-windows-x64.zip", Asset: "Koe-0.2.0-windows-x64.zip"}
	if r != want {
		t.Fatalf("got %#v", r)
	}
	r, err = ParseLatestRelease([]byte(`{"tag_name":"0.3","assets":[{"name":"Koe.dmg","browser_download_url":"x"}]}`))
	if !errors.Is(err, ErrNoWindowsAsset) || r.Version != "0.3" {
		t.Fatalf("got %#v %v", r, err)
	}
	if _, err := ParseLatestRelease([]byte(`{}`)); err == nil {
		t.Fatal("want error for missing tag")
	}
	if _, err := ParseLatestRelease([]byte(`not json`)); err == nil {
		t.Fatal("want error for bad json")
	}
}

func TestLatestRelease(t *testing.T) {
	var ua string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ua = r.Header.Get("User-Agent")
		switch r.URL.Path {
		case "/repos/o/r/releases/latest":
			w.Write([]byte(releaseJSON))
		case "/repos/o/none/releases/latest":
			http.NotFound(w, r)
		default:
			w.WriteHeader(http.StatusForbidden)
		}
	}))
	defer srv.Close()
	ctx := context.Background()
	r, err := LatestRelease(ctx, srv.URL, "o/r", "Koe-test/1")
	if err != nil || r.Version != "0.2.0" || ua != "Koe-test/1" {
		t.Fatalf("got %#v %v ua=%q", r, err, ua)
	}
	if r, err := LatestRelease(ctx, srv.URL, "o/none", "x"); err != nil || r.Tag != "" {
		t.Fatalf("no releases: got %#v %v", r, err)
	}
	if _, err := LatestRelease(ctx, srv.URL, "o/limited", "x"); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("want HTTP 403 error, got %v", err)
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
