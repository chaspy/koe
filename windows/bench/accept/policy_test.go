package main

import "testing"

func TestParsePolicy(t *testing.T) {
	small, turbo := "ggml-small-q5_1.bin", "ggml-large-v3-turbo-q5_0.bin"
	cases := []struct {
		in    string
		sec   float64
		model string
		want  int
	}{
		{"auto", 2, small, 768}, {"auto", 10, small, 768}, {"auto", 20, small, 1164}, {"0", 2, small, 0}, {"700", 2, small, 700},
		{"auto:384", 2, small, 384}, {"auto:384", 10, small, 614}, {"auto:768", 2, small, 768}, {"auto:768", 20, small, 1164}, {"auto:1000", 5, small, 1000},
		{"full<6", 5.9, small, 0}, {"full<6", 6, small, 768}, {"full<6+auto:768", 7, small, 768},
		{"auto:768", 2, turbo, 0}, {"full<6", 8, turbo, 0},
	}
	for _, c := range cases {
		p, err := parsePolicy(c.in)
		if err != nil {
			t.Fatal(c.in, err)
		}
		if got := p.fn(c.sec, c.model); got != c.want || p.name != c.in {
			t.Errorf("%s(%v, %s) = %d, want %d", c.in, c.sec, c.model, got, c.want)
		}
	}
	for _, bad := range []string{"", "x", "auto:0", "auto:9999", "full<", "full<x", "full<6+0", "-1"} {
		if _, err := parsePolicy(bad); err == nil {
			t.Errorf("%q must be rejected", bad)
		}
	}
}
