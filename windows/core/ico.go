package core

import (
	"bytes"
	"encoding/binary"
)

// MakeIcon builds a 32x32 32-bit BMP-style .ico of a speech-bubble ring
// (filled when recording). BMP icons load everywhere (LoadImage).
func MakeIcon(r, g, b uint8, filled bool) []byte {
	const n = 32
	px := make([]byte, n*n*4) // BGRA, bottom-up
	cx, cy := 15.5, 14.0
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			dx, dy := float64(x)-cx, float64(y)-cy
			d2 := dx*dx + dy*dy
			on := false
			if filled {
				on = d2 <= 12.5*12.5
			} else {
				on = d2 <= 12.5*12.5 && d2 >= 8.5*8.5
			}
			// little tail at bottom-left
			if x >= 5 && x <= 10 && y >= 24 && y <= 30 && (x-5) >= (y-24)-1 && (x-5) <= (y-24)+2 {
				on = true
			}
			if !on {
				continue
			}
			row := n - 1 - y
			i := (row*n + x) * 4
			px[i], px[i+1], px[i+2], px[i+3] = b, g, r, 255
		}
	}
	mask := make([]byte, n*4) // 1bpp AND mask, rows padded to 4 bytes, all 0 (use alpha)
	var img bytes.Buffer
	w := func(v any) { _ = binary.Write(&img, binary.LittleEndian, v) }
	w(uint32(40))   // biSize
	w(int32(n))     // width
	w(int32(n * 2)) // height (xor + and)
	w(uint16(1))    // planes
	w(uint16(32))   // bpp
	w(uint32(0))    // BI_RGB
	w(uint32(len(px) + len(mask)))
	w(int32(0))
	w(int32(0))
	w(uint32(0))
	w(uint32(0))
	img.Write(px)
	img.Write(mask)

	var out bytes.Buffer
	o := func(v any) { _ = binary.Write(&out, binary.LittleEndian, v) }
	o(uint16(0))
	o(uint16(1)) // icon
	o(uint16(1)) // count
	out.WriteByte(n)
	out.WriteByte(n)
	out.WriteByte(0)
	out.WriteByte(0)
	o(uint16(1))
	o(uint16(32))
	o(uint32(img.Len()))
	o(uint32(6 + 16))
	out.Write(img.Bytes())
	return out.Bytes()
}
