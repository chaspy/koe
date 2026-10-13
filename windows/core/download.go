package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Download fetches url to dest via dest+".part", resuming a partial file
// with a Range request. progress gets (done, total) bytes; total may be -1.
func Download(ctx context.Context, url, dest string, progress func(done, total int64)) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	part := dest + ".part"
	var have int64
	if fi, err := os.Stat(part); err == nil {
		have = fi.Size()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	if have > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(have, 10)+"-")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	flags := os.O_CREATE | os.O_WRONLY
	switch resp.StatusCode {
	case http.StatusPartialContent:
		flags |= os.O_APPEND
	case http.StatusOK:
		have = 0
		flags |= os.O_TRUNC
	case http.StatusRequestedRangeNotSatisfiable:
		// the part file is probably complete
		if have > 0 {
			return os.Rename(part, dest)
		}
		return fmt.Errorf("download: HTTP %d", resp.StatusCode)
	default:
		return fmt.Errorf("download: HTTP %d", resp.StatusCode)
	}
	total := int64(-1)
	if resp.ContentLength >= 0 {
		total = have + resp.ContentLength
	}
	f, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return err
	}
	done := have
	buf := make([]byte, 256<<10)
	last := time.Time{}
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				f.Close()
				return werr
			}
			done += int64(n)
			if progress != nil && time.Since(last) > 500*time.Millisecond {
				progress(done, total)
				last = time.Now()
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			f.Close()
			return rerr
		}
	}
	if err := f.Close(); err != nil {
		return err
	}
	if total >= 0 && done != total {
		return fmt.Errorf("download: got %d of %d bytes", done, total)
	}
	if progress != nil {
		progress(done, total)
	}
	return os.Rename(part, dest)
}
