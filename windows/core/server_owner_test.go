package core

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCheckServer(t *testing.T) {
	const port, pid = 50123, 4321
	cases := []struct {
		name    string
		running bool
		table   []Listener
		want    ServerState
	}{
		{"own child only", true, []Listener{{Port: 80, PID: 1}, {Port: port, PID: pid}}, ServerOwned},
		{"own child on two addresses", true, []Listener{{Port: port, PID: pid}, {Port: port, PID: pid}}, ServerOwned},
		{"child exited", false, []Listener{{Port: port, PID: pid}}, ServerExited},
		{"not listening yet", true, []Listener{{Port: 80, PID: 1}}, ServerNotListening},
		{"empty table", true, nil, ServerNotListening},
		{"other process only", true, []Listener{{Port: port, PID: 99}}, ServerForeign},
		{"other process next to child", true, []Listener{{Port: port, PID: pid}, {Port: port, PID: 99}}, ServerForeign},
	}
	for _, c := range cases {
		if got := CheckServer(c.running, c.table, port, pid); got != c.want {
			t.Errorf("%s: got %s, want %s", c.name, got, c.want)
		}
	}
}

type rawRow struct {
	port uint16
	pid  uint32
}

func ownerTable(rowSize, portOff, pidOff int, count uint32, rows ...rawRow) []byte {
	buf := make([]byte, 4+len(rows)*rowSize)
	binary.LittleEndian.PutUint32(buf, count)
	for i, r := range rows {
		row := buf[4+i*rowSize:]
		binary.BigEndian.PutUint16(row[portOff:], r.port)
		binary.LittleEndian.PutUint32(row[pidOff:], r.pid)
	}
	return buf
}

func TestParseOwnerPIDTable(t *testing.T) {
	rows := []rawRow{{18080, 1234}, {443, 4}}
	want := []Listener{{Port: 18080, PID: 1234}, {Port: 443, PID: 4}}
	for _, c := range []struct {
		size, portOff, pidOff int
	}{{TCPRowOwnerPIDSize, 8, 20}, {TCP6RowOwnerPIDSize, 20, 52}} {
		got, err := ParseOwnerPIDTable(ownerTable(c.size, c.portOff, c.pidOff, 2, rows...), c.size)
		if err != nil || len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
			t.Fatalf("row size %d: %v %v", c.size, got, err)
		}
	}
	short := ownerTable(TCPRowOwnerPIDSize, 8, 20, 2, rows...)
	if _, err := ParseOwnerPIDTable(short[:len(short)-1], TCPRowOwnerPIDSize); err == nil {
		t.Fatal("truncated table accepted")
	}
	if _, err := ParseOwnerPIDTable(ownerTable(TCPRowOwnerPIDSize, 8, 20, 3, rows...), TCPRowOwnerPIDSize); err == nil {
		t.Fatal("row count larger than the buffer accepted")
	}
	if _, err := ParseOwnerPIDTable(nil, TCPRowOwnerPIDSize); err == nil {
		t.Fatal("empty buffer accepted")
	}
	if _, err := ParseOwnerPIDTable(short, 10); err == nil {
		t.Fatal("unknown row size accepted")
	}
}

func TestFreeLoopbackPort(t *testing.T) {
	p, err := FreeLoopbackPort()
	if err != nil || p <= 0 || p > 65535 {
		t.Fatal(p, err)
	}
}

func TestIsHealthy(t *testing.T) {
	status := http.StatusServiceUnavailable
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(status)
	}))
	defer srv.Close()
	if IsHealthy(srv.URL) {
		t.Fatal("loading server counted as healthy")
	}
	status = http.StatusOK
	if !IsHealthy(srv.URL) {
		t.Fatal("ready server not healthy")
	}
	if IsHealthy("http://127.0.0.1:1") {
		t.Fatal("closed port healthy")
	}
}

func TestCheckedWhisperSendsNothingWhenCheckFails(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		_, _ = io.WriteString(w, "テキスト\n")
	}))
	defer srv.Close()
	wav := EncodeWAV(make([]int16, 100))
	failing := CheckedWhisper{BaseURL: srv.URL, Check: func() error { return errors.New("exited") }}
	if _, err := failing.Recognize(context.Background(), wav, "", false, 0); !errors.Is(err, ErrServerNotOwned) {
		t.Fatal("expected ErrServerNotOwned, got", err)
	}
	if requests != 0 {
		t.Fatal("request sent although the check failed")
	}
	ok := CheckedWhisper{BaseURL: srv.URL, Check: func() error { return nil }}
	if got, err := ok.Recognize(context.Background(), wav, "", false, 0); err != nil || got != "テキスト" || requests != 1 {
		t.Fatal(got, err, requests)
	}
}

func TestStripControl(t *testing.T) {
	cases := map[string]string{
		"そのまま":            "そのまま",
		"a\tb":            "a b",
		"行1\n行2\r\n":      "行1\n行2\r\n",
		"x\x00y\x07z\x1b": "xyz",
		"del\x7f":         "del",
		"c1\u0085\u009b":  "c1",
		"記号 & | ; $ ` 可":  "記号 & | ; $ ` 可",
	}
	for in, want := range cases {
		if got := StripControl(in); got != want {
			t.Errorf("StripControl(%q) = %q, want %q", in, got, want)
		}
	}
	if got := CleanServerText(" 一\x1b[0m行\t目 \n\n 二\x00行目\n"); got != "一[0m行 目 二行目" {
		t.Fatalf("CleanServerText = %q", got)
	}
}
