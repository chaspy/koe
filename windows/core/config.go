package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// DefaultModel is quantized small: with the speed-first audio_ctx it was the
// best balance of speed and accuracy on CPU (windows/bench/results.md).
// Users whose config.json already names a model keep it.
const DefaultModel = "ggml-small-q5_1.bin"

// Press modes.
const (
	PressHold   = "hold"
	PressToggle = "toggle"
)

// ModelBaseURL is where model files are downloaded from.
const ModelBaseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

// Config is %APPDATA%\Koe\config.json. Missing keys keep the defaults.
type Config struct {
	Hotkey    string `json:"hotkey"`    // "ralt" | "rctrl"
	PressMode string `json:"pressMode"` // "hold" (record while held) | "toggle" (tap to start, tap to stop)
	Model     string `json:"model"`     // file name in the models dir, or an absolute path
	ModelURL  string `json:"modelURL"`  // empty = ModelBaseURL + Model
	Language  string `json:"language"`
	Port      int    `json:"port"`
	Threads   int    `json:"threads"` // 0 = auto (logical CPUs, up to 16)
	// TemperatureFallback lets whisper re-decode a hard segment at higher
	// temperatures (whisper.cpp's default). Off: one greedy pass, much faster on CPU.
	TemperatureFallback bool     `json:"temperatureFallback"`
	AudioCtx            AudioCtx `json:"audioCtx"`    // encoder window: "auto" (sized to the utterance) | 0 (whole 30 s) | frames
	GPU                 string   `json:"gpu"`         // "auto" (Vulkan build when a GPU works, else CPU) | "off"
	GPUAudioCtx         AudioCtx `json:"gpuAudioCtx"` // encoder window on a GPU; default 0 (whole: fast enough there, most accurate)
	Prompt              string   `json:"prompt"`
	EnabledPacks        []string `json:"enabledPacks"`
	PackSources         []string `json:"packSources"`
	AutoEnter           bool     `json:"autoEnter"`
	EnterApps           []string `json:"enterApps"`
	EnterDelayMs        int      `json:"enterDelayMs"`
	MinHoldSeconds      float64  `json:"minHoldSeconds"`
	Sounds              bool     `json:"sounds"`
	WarmMic             bool     `json:"warmMic"`
	SaveHistory         bool     `json:"saveHistory"`
	HistoryDays         int      `json:"historyDays"`
	ContextPrompt       bool     `json:"contextPrompt"`
	RestoreClipboard    bool     `json:"restoreClipboard"`
	MenuMaskKey         bool     `json:"menuMaskKey"` // send a dummy key while Alt is held so Alt alone does not open the app menu
	UpdateCheck         bool     `json:"updateCheck"` // check GitHub Releases for a newer version at start and daily
	UpdateRepo          string   `json:"updateRepo"`  // "owner/repo" whose releases are checked
}

// DefaultConfig mirrors the mac defaults.
func DefaultConfig() Config {
	return Config{
		Hotkey:         "ralt",
		PressMode:      PressHold,
		Model:          DefaultModel,
		Language:       "ja",
		Port:           18080,
		Prompt:         DefaultPrompt,
		EnabledPacks:   []string{"developer"},
		PackSources:    []string{},
		AutoEnter:      true,
		EnterApps:      append([]string{}, DefaultEnterApps...),
		EnterDelayMs:   350,
		MinHoldSeconds: 0.3,
		Sounds:         true,
		WarmMic:        true,
		SaveHistory:    true,
		HistoryDays:    7,
		ContextPrompt:  true,
		MenuMaskKey:    true,
		UpdateCheck:    true,
		UpdateRepo:     DefaultUpdateRepo,
		AudioCtx:       AudioCtxAuto,
		GPU:            GPUAuto,
		GPUAudioCtx:    0,
	}
}

// ParseConfig overlays JSON on the defaults and sanitizes values.
func ParseConfig(data []byte) (Config, error) {
	c := DefaultConfig()
	var err error
	if len(strings.TrimSpace(string(data))) > 0 {
		err = json.Unmarshal(data, &c)
	}
	d := DefaultConfig()
	c.Hotkey = strings.ToLower(strings.TrimSpace(c.Hotkey))
	if c.Hotkey != "ralt" && c.Hotkey != "rctrl" {
		c.Hotkey = d.Hotkey
	}
	c.PressMode = strings.ToLower(strings.TrimSpace(c.PressMode))
	if c.PressMode != PressToggle {
		c.PressMode = PressHold
	}
	c.Model = NormalizeModel(c.Model)
	if c.Model == "" {
		c.Model = d.Model
	}
	c.GPU = strings.ToLower(strings.TrimSpace(c.GPU))
	if c.GPU != GPUOff {
		c.GPU = GPUAuto
	}
	if c.Threads < 0 {
		c.Threads = 0
	}
	if c.Language == "" {
		c.Language = d.Language
	}
	if c.Port <= 0 || c.Port > 65535 {
		c.Port = d.Port
	}
	if c.Prompt == "" {
		c.Prompt = d.Prompt
	}
	if c.EnabledPacks == nil {
		c.EnabledPacks = d.EnabledPacks
	}
	if len(c.EnterApps) == 0 {
		c.EnterApps = d.EnterApps
	}
	if c.EnterDelayMs <= 0 {
		c.EnterDelayMs = d.EnterDelayMs
	}
	if c.MinHoldSeconds <= 0 {
		c.MinHoldSeconds = d.MinHoldSeconds
	}
	if c.HistoryDays <= 0 {
		c.HistoryDays = d.HistoryDays
	}
	c.UpdateRepo = strings.Trim(strings.TrimSpace(c.UpdateRepo), "/")
	if strings.Count(c.UpdateRepo, "/") != 1 {
		c.UpdateRepo = d.UpdateRepo
	}
	return c, err
}

// LoadConfig reads path; if missing, writes the defaults there.
func LoadConfig(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		c := DefaultConfig()
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		out, _ := json.MarshalIndent(c, "", "  ")
		_ = os.WriteFile(path, out, 0o644)
		return c, nil
	}
	if err != nil {
		return DefaultConfig(), err
	}
	return ParseConfig(b)
}

// HotkeyVK is the Windows virtual-key code of a hotkey name ("ralt" | "rctrl").
func HotkeyVK(name string) uint32 {
	if name == "rctrl" {
		return 0xA3 // VK_RCONTROL
	}
	return 0xA5 // VK_RMENU
}

// HotkeyLabel is the name shown to the user.
func HotkeyLabel(name string) string {
	if name == "rctrl" {
		return "右 Ctrl"
	}
	return "右 Alt"
}

// SetConfigValue sets one top-level key in the JSON file at path, keeping the
// other keys (including ones this version does not know) as they are.
func SetConfigValue(path, key string, value any) error {
	m := map[string]json.RawMessage{}
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if len(strings.TrimSpace(string(b))) > 0 {
		if err := json.Unmarshal(b, &m); err != nil {
			return err
		}
	}
	v, err := json.Marshal(value)
	if err != nil {
		return err
	}
	m[key] = v
	out, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ModelPath resolves the model file (absolute path or name in modelsDir).
func (c Config) ModelPath(modelsDir string) string {
	if filepath.IsAbs(c.Model) || strings.Contains(c.Model, `:\`) {
		return c.Model
	}
	return filepath.Join(modelsDir, c.Model)
}

// ModelDownloadURL is the URL the model is fetched from.
func (c Config) ModelDownloadURL() string {
	if c.ModelURL != "" {
		return c.ModelURL
	}
	return ModelBaseURL + filepath.Base(strings.ReplaceAll(c.Model, `\`, "/"))
}
