package install

import (
	"context"
	"io"
	"net/http"
	"path"
	"strings"
	"time"
)

// HTTPClient keeps geo-IP requests injectable, including in full-flow tests.
type HTTPClient interface {
	Do(*http.Request) (*http.Response, error)
}

const timezoneTimeout = 1500 * time.Millisecond

// DetectTimezone is best effort. An empty result preserves the existing default.
// Each service gets its own deadline, including reading the response body.
func (i *Installer) DetectTimezone(ctx context.Context) string {
	client := i.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: timezoneTimeout}
	}
	for _, endpoint := range []string{"https://ipapi.co/timezone", "http://ip-api.com/line?fields=timezone"} {
		if ctx.Err() != nil {
			break
		}
		zone := i.timezoneFrom(ctx, client, endpoint)
		if zone != "" {
			return zone
		}
	}
	return ""
}

func (i *Installer) timezoneFrom(ctx context.Context, client HTTPClient, endpoint string) string {
	ctx, cancel := context.WithTimeout(ctx, timezoneTimeout)
	defer cancel()
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if e != nil {
		return ""
	}
	resp, e := client.Do(req)
	if e != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, 257))
	if e != nil || ctx.Err() != nil || len(b) > 256 {
		return ""
	}
	zone := strings.TrimSpace(string(b))
	if zone == "" || strings.HasPrefix(zone, "/") || path.Clean(zone) != zone || zone == "." || zone == ".." || strings.HasPrefix(zone, "../") {
		return ""
	}
	for _, c := range zone {
		if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_-+", c) {
			return ""
		}
	}
	// Require an actual installed TZif file, not just a directory or tzdata text.
	b, e = i.FS.Read("/usr/share/zoneinfo/" + zone)
	if e != nil {
		return ""
	}
	if _, e = time.LoadLocationFromTZData(zone, b); e != nil {
		return ""
	}
	return zone
}
