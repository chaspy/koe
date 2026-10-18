package core

import (
	"encoding/json"
	"testing"
)

func TestLowLevelWarningConfig(t *testing.T) {
	for _, tt := range []struct {
		json string
		want bool
	}{
		{`{}`, false},
		{`{"lowLevelWarning":false}`, false},
		{`{"lowLevelWarning":true}`, true},
	} {
		cfg, err := ParseConfig([]byte(tt.json))
		if err != nil || cfg.LowLevelWarning != tt.want {
			t.Fatalf("ParseConfig(%s): enabled=%v, err=%v", tt.json, cfg.LowLevelWarning, err)
		}
	}
	data, err := json.Marshal(DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	var values map[string]any
	if err := json.Unmarshal(data, &values); err != nil {
		t.Fatal(err)
	}
	if enabled, ok := values["lowLevelWarning"]; !ok || enabled != false {
		t.Fatalf("serialized default lowLevelWarning = %v, present=%v", enabled, ok)
	}
}
