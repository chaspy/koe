package core

import (
	"strings"
	"testing"
)

func TestFirstRunMessage(t *testing.T) {
	const dl = "ダウンロードします"
	if m := FirstRunMessage(false); !strings.Contains(m, dl) || !strings.Contains(m, "右 Alt") {
		t.Errorf("model missing: want download sentence, got %q", m)
	}
	if m := FirstRunMessage(true); strings.Contains(m, dl) || !strings.Contains(m, "準備ができたら") {
		t.Errorf("model present: want no download sentence, got %q", m)
	}
}
