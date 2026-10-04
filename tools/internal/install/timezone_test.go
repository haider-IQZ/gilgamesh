package install

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

type httpClientFunc func(*http.Request) (*http.Response, error)

func (f httpClientFunc) Do(r *http.Request) (*http.Response, error) { return f(r) }

// A minimal TZif file: one UTC type and no clock transitions.
func zoneFixture(t *testing.T, i *Installer, zone string) {
	t.Helper()
	b := make([]byte, 54)
	copy(b, "TZif")
	binary.BigEndian.PutUint32(b[36:40], 1)
	binary.BigEndian.PutUint32(b[40:44], 4)
	copy(b[50:], "UTC\x00")
	testkit.Write(t, i.FS, "/usr/share/zoneinfo/"+zone, string(b))
}

type trackedBody struct {
	io.Reader
	closed bool
}

func (b *trackedBody) Close() error { b.closed = true; return nil }

func TestDetectTimezone(t *testing.T) {
	for _, tc := range []struct {
		name, answer, want string
		status             int
	}{
		{"success", "Etc/UTC\n", "Etc/UTC", 200},
		{"bad answer", "<html>unavailable</html>", "", 200},
		{"multiple lines", "Etc/UTC\nEurope/London", "", 200},
		{"empty", "\n", "", 200},
		{"invalid zone", "Europe/Unknown", "", 200},
		{"directory", "Etc", "", 200},
		{"not TZif", "tzdata.zi", "", 200},
		{"traversal", "../Etc/UTC", "", 200},
		{"absolute", "/Etc/UTC", "", 200},
		{"unclean", "Etc/../Etc/UTC", "", 200},
		{"too long", strings.Repeat("x", 257), "", 200},
		{"rate limited", "Etc/UTC", "", 429},
	} {
		t.Run(tc.name, func(t *testing.T) {
			i := &Installer{FS: testkit.FS(t)}
			zoneFixture(t, i, "Etc/UTC")
			testkit.Write(t, i.FS, "/usr/share/zoneinfo/tzdata.zi", "not a timezone file")
			var bodies []*trackedBody
			i.HTTPClient = httpClientFunc(func(r *http.Request) (*http.Response, error) {
				deadline, ok := r.Context().Deadline()
				if !ok || time.Until(deadline) > timezoneTimeout {
					t.Fatal("missing short request deadline")
				}
				b := &trackedBody{Reader: strings.NewReader(tc.answer)}
				bodies = append(bodies, b)
				return &http.Response{StatusCode: tc.status, Body: b}, nil
			})
			if got := i.DetectTimezone(context.Background()); got != tc.want {
				t.Fatalf("got %q want %q", got, tc.want)
			}
			wantCalls := 2
			if tc.want != "" {
				wantCalls = 1
			}
			if len(bodies) != wantCalls {
				t.Fatal("service attempts", len(bodies))
			}
			for _, b := range bodies {
				if !b.closed {
					t.Fatal("response body not closed")
				}
			}
		})
	}
}

func TestTimezoneTimeoutAndFallback(t *testing.T) {
	i := &Installer{FS: testkit.FS(t)}
	zoneFixture(t, i, "Etc/UTC")
	calls := 0
	i.HTTPClient = httpClientFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			if r.URL.Host != "ipapi.co" {
				t.Fatal(r.URL)
			}
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		if r.URL.Host != "ip-api.com" || r.Context().Err() != nil {
			t.Fatal("fallback did not get an independent deadline", r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("Etc/UTC"))}, nil
	})
	if got := i.DetectTimezone(context.Background()); got != "Etc/UTC" || calls != 2 {
		t.Fatal(got, calls)
	}
}

func TestTimezoneCancellation(t *testing.T) {
	i := &Installer{FS: testkit.FS(t)}
	calls := 0
	i.HTTPClient = httpClientFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if got := i.DetectTimezone(ctx); got != "" || calls != 1 {
		t.Fatal(got, calls)
	}
}

type timezoneUI struct {
	*fakeUI
	defaults []string
}

func (u *timezoneUI) Choose(ctx context.Context, title string, opts []string, value string) (string, error) {
	if title == "Timezone" {
		if opts[0] != value {
			return "", errors.New("preselected timezone is not first in the list")
		}
		u.defaults = append(u.defaults, value)
		return "Etc/UTC", nil // The user can override the detected zone.
	}
	return u.fakeUI.Choose(ctx, title, opts, value)
}

func (u *timezoneUI) Summary(ctx context.Context, rows [][2]string) (bool, error) {
	if len(u.defaults) == 1 {
		return false, nil // Editing answers must preserve the user's timezone.
	}
	return u.fakeUI.Summary(ctx, rows)
}

func TestTimezonePreselection(t *testing.T) {
	x := newFixture(t, "virtio")
	zoneFixture(t, x.i, "Europe/London")
	handle := x.r.Handle
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		if c.Name == "timedatectl" {
			return "Etc/UTC\nEurope/London", nil
		}
		return handle(ctx, c)
	}
	u := &timezoneUI{fakeUI: x.u}
	x.i.UI = u
	calls := 0
	x.i.HTTPClient = httpClientFunc(func(*http.Request) (*http.Response, error) {
		calls++
		if len(x.r.Calls) == 0 || x.r.Calls[len(x.r.Calls)-1].Name != "curl" {
			t.Fatal("lookup did not follow connectivity check")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("Europe/London"))}, nil
	})
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Questions(context.Background()); e != nil {
		t.Fatal(e)
	}
	if calls != 1 || len(u.defaults) != 2 || u.defaults[0] != "Europe/London" || u.defaults[1] != "Etc/UTC" {
		t.Fatal(calls, u.defaults)
	}
}

type filterUI struct {
	*fakeUI
	chosen, filtered []string
}

func (u *filterUI) Choose(ctx context.Context, title string, opts []string, value string) (string, error) {
	if title == "Timezone" {
		u.chosen = append(u.chosen, value)
	}
	return u.fakeUI.Choose(ctx, title, opts, value)
}
func (u *filterUI) Filter(_ context.Context, title string, opts []string) (string, error) {
	u.filtered = append(u.filtered, title+":"+strings.Join(opts, ","))
	return "Europe/London", nil
}

// Without a detected zone the whole list is offered through the filterable picker.
func TestTimezoneFilterFallback(t *testing.T) {
	x := newFixture(t, "virtio")
	handle := x.r.Handle
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		if c.Name == "timedatectl" {
			return "Etc/UTC\nEurope/London", nil
		}
		return handle(ctx, c)
	}
	u := &filterUI{fakeUI: x.u}
	x.i.UI = u
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Questions(context.Background()); e != nil {
		t.Fatal(e)
	}
	if len(u.chosen) != 0 || !reflect.DeepEqual(u.filtered, []string{"Timezone:Etc/UTC,Europe/London"}) || x.i.Plan.Answers.Timezone != "Europe/London" {
		t.Fatal(u.chosen, u.filtered, x.i.Plan.Answers.Timezone)
	}
}

func TestDryPrepareSkipsTimezoneHTTP(t *testing.T) {
	x := newFixture(t, "virtio")
	x.i.Dry = true
	x.i.HTTPClient = httpClientFunc(func(*http.Request) (*http.Response, error) {
		t.Error("dry run made an HTTP request")
		return nil, errors.New("unexpected request")
	})
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
}
