package core

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// DefaultUpdateRepo is the public repository whose releases are checked.
const DefaultUpdateRepo = "chaspy/koe"

// WindowsAssetSuffix identifies the Windows build among release assets.
const WindowsAssetSuffix = "-windows-x64.zip"

// GitHubAPI is the base URL of the GitHub REST API.
const GitHubAPI = "https://api.github.com"

// Release is a published version that has a Windows build.
type Release struct {
	Version  string // tag without the leading "v"
	Tag      string
	Page     string // html_url of the release
	AssetURL string // browser_download_url of the Windows zip
	Asset    string // asset file name
}

// ErrNoWindowsAsset means the latest release has no Windows zip.
var ErrNoWindowsAsset = errors.New("latest release has no " + WindowsAssetSuffix + " asset")

// NewerVersion reports whether a is newer than b, comparing dot-separated
// numbers ("0.10.0" > "0.9.1"; missing parts count as 0). A leading "v" and
// any "-suffix" / "+suffix" are ignored; non-numeric parts count as 0.
func NewerVersion(a, b string) bool {
	x, y := versionParts(a), versionParts(b)
	for i := 0; i < len(x) || i < len(y); i++ {
		var p, q int
		if i < len(x) {
			p = x[i]
		}
		if i < len(y) {
			q = y[i]
		}
		if p != q {
			return p > q
		}
	}
	return false
}

func versionParts(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "-+ "); i >= 0 {
		v = v[:i]
	}
	var out []int
	for _, s := range strings.Split(v, ".") {
		n, _ := strconv.Atoi(s)
		out = append(out, n)
	}
	return out
}

// ParseLatestRelease reads the JSON of GET /repos/{repo}/releases/latest and
// picks the asset whose name ends with WindowsAssetSuffix.
func ParseLatestRelease(data []byte) (Release, error) {
	var j struct {
		TagName string `json:"tag_name"`
		HTMLURL string `json:"html_url"`
		Assets  []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(data, &j); err != nil {
		return Release{}, fmt.Errorf("release json: %w", err)
	}
	if j.TagName == "" {
		return Release{}, errors.New("release json: no tag_name")
	}
	r := Release{Tag: j.TagName, Version: strings.TrimPrefix(j.TagName, "v"), Page: j.HTMLURL}
	for _, a := range j.Assets {
		if strings.HasSuffix(strings.ToLower(a.Name), WindowsAssetSuffix) && a.URL != "" {
			r.Asset, r.AssetURL = a.Name, a.URL
			return r, nil
		}
	}
	return r, ErrNoWindowsAsset
}

// ReleasePageURL is where to send the user when the update cannot be done.
func ReleasePageURL(repo string) string {
	return "https://github.com/" + repo + "/releases/latest"
}

// LatestRelease fetches the latest release of repo from apiBase (GitHubAPI).
// A repository without releases returns (Release{}, nil) with an empty Tag.
func LatestRelease(ctx context.Context, apiBase, repo, userAgent string) (Release, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	url := strings.TrimRight(apiBase, "/") + "/repos/" + repo + "/releases/latest"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Release{}, err
	}
	req.Header.Set("User-Agent", userAgent) // required by the GitHub API
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return Release{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return Release{}, err
	}
	if resp.StatusCode == http.StatusNotFound {
		return Release{}, nil
	}
	if resp.StatusCode != http.StatusOK {
		return Release{}, fmt.Errorf("releases/latest: HTTP %d", resp.StatusCode)
	}
	return ParseLatestRelease(body)
}

// ExtractZip extracts zipPath into dest, rejecting entries that would escape it.
func ExtractZip(zipPath, dest string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()
	root, err := filepath.Abs(dest)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	for _, f := range r.File {
		name := strings.ReplaceAll(f.Name, `\`, "/")
		target := filepath.Join(root, filepath.FromSlash(name))
		if target != root && !strings.HasPrefix(target, root+string(filepath.Separator)) {
			return fmt.Errorf("zip entry outside the destination: %q", f.Name)
		}
		if f.FileInfo().IsDir() || strings.HasSuffix(name, "/") {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := extractFile(f, target); err != nil {
			return err
		}
	}
	return nil
}

func extractFile(f *zip.File, target string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, rc); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// FindAppRoot returns the directory under staging that contains exeName:
// staging itself, or its only top-level directory (the zip has "Koe\").
func FindAppRoot(staging, exeName string) (string, error) {
	if fileExists(filepath.Join(staging, exeName)) {
		return staging, nil
	}
	ents, err := os.ReadDir(staging)
	if err != nil {
		return "", err
	}
	var dirs []string
	for _, e := range ents {
		if e.IsDir() {
			dirs = append(dirs, e.Name())
		}
	}
	if len(dirs) == 1 {
		d := filepath.Join(staging, dirs[0])
		if fileExists(filepath.Join(d, exeName)) {
			return d, nil
		}
	}
	return "", fmt.Errorf("%s not found in the downloaded zip", exeName)
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

// UpdatePending is written before Koe quits to install an update, and read
// at the next start to tell whether the update took effect.
type UpdatePending struct {
	From string `json:"from"`
	To   string `json:"to"`
	Page string `json:"page"`
	At   string `json:"at"`
}

// WriteUpdatePending saves p as JSON at path.
func WriteUpdatePending(path string, p UpdatePending) error {
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

// TakeUpdatePending reads and removes the marker. ok is false if none.
func TakeUpdatePending(path string) (p UpdatePending, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return p, false
	}
	_ = os.Remove(path)
	if json.Unmarshal(b, &p) != nil {
		return p, false
	}
	return p, true
}

// UpdateScript is the batch file that installs a staged update. It is pure
// ASCII: every path comes from environment variables set on the cmd.exe
// process (KOE_PID, KOE_SRC, KOE_DST, KOE_WORK, KOE_LOG), so non-ASCII
// folder names work regardless of the console code page.
//
// It waits for Koe (and so its whisper-server, which lives in a kill-on-close
// job) to exit, copies the staged files over the install folder with retries
// (robocopy /E: files are overwritten, nothing extra is deleted), removes the
// staging folder, starts Koe.exe again and deletes itself.
const UpdateScript = `@echo off
setlocal
>>"%KOE_LOG%" echo %DATE% %TIME% update_script_start pid=%KOE_PID%
set /a n=0
:waitkoe
tasklist /FI "PID eq %KOE_PID%" /NH 2>nul | findstr /C:" %KOE_PID% " >nul
if errorlevel 1 goto koegone
set /a n+=1
if %n% GEQ 120 goto koegone
ping -n 2 127.0.0.1 >nul
goto waitkoe
:koegone
rem give the whisper-server job a moment to die and release its DLLs
ping -n 3 127.0.0.1 >nul
set /a try=0
:copy
set /a try+=1
robocopy "%KOE_SRC%" "%KOE_DST%" /E /IS /IT /R:5 /W:2 /NP /NJH /NJS /NDL >>"%KOE_LOG%" 2>&1
if %ERRORLEVEL% LSS 8 goto copied
>>"%KOE_LOG%" echo %DATE% %TIME% update_copy_failed try=%try% code=%ERRORLEVEL%
if %try% GEQ 3 goto restart
ping -n 6 127.0.0.1 >nul
goto copy
:copied
>>"%KOE_LOG%" echo %DATE% %TIME% update_copied try=%try%
:restart
rmdir /S /Q "%KOE_WORK%" 2>nul
start "" /D "%KOE_DST%" "%KOE_DST%\Koe.exe"
>>"%KOE_LOG%" echo %DATE% %TIME% update_script_done
(goto) 2>nul & del "%~f0"
`

// UpdateScriptCRLF is UpdateScript with the CRLF line endings cmd.exe expects.
func UpdateScriptCRLF() []byte {
	return []byte(strings.ReplaceAll(UpdateScript, "\n", "\r\n"))
}
