package dns

import (
	"bytes"
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

func TestCurrent(t *testing.T) {
	for _, c := range []struct{ name, active, ignore, servers, want string }{{"none", "", "", "", "DHCP"}, {"automatic", "u:802-3-ethernet:eth0", "no", "1.1.1.1", "DHCP"}, {"empty", "u:802-11-wireless:wlan0", "yes", "", "DHCP"}, {"cloudflare", "u:802-3-ethernet:eth0", "yes", "1.0.0.1#cloudflare-dns.com,1.1.1.1", "Cloudflare"}, {"google", "u:802-3-ethernet:eth0", "yes", "8.8.4.4 8.8.8.8", "Google"}, {"opendns", "u:802-3-ethernet:eth0", "yes", "208.67.220.220", "OpenDNS"}, {"custom", "u:802-3-ethernet:eth0", "yes", "9.9.9.9", "Custom"}, {"vpn only", "u:vpn:tun0", "yes", "1.1.1.1", "DHCP"}} {
		t.Run(c.name, func(t *testing.T) {
			r := &run.Fake{Handle: func(_ context.Context, q run.Command) (string, error) {
				if q.Args[0] == "-t" {
					return c.active, nil
				}
				if q.Args[1] == "ipv4.dns" {
					return c.servers, nil
				}
				return c.ignore, nil
			}}
			got, e := (App{Runner: r}).Current(context.Background())
			if e != nil || got != c.want {
				t.Fatal(got, e)
			}
		})
	}
}
func TestApply(t *testing.T) {
	for _, nixos := range []bool{false, true} {
		for _, provider := range []string{"DHCP", "Cloudflare", "Google", "OpenDNS", "Custom"} {
			t.Run(fmt.Sprint(nixos, "/", provider), func(t *testing.T) {
				f := testkit.FS(t)
				if nixos {
					testkit.Write(t, f, "/etc/NIXOS", "")
				}
				var out bytes.Buffer
				r := &run.Fake{Handle: func(_ context.Context, c run.Command) (string, error) {
					if reflect.DeepEqual(c.Args, []string{"-t", "-f", "UUID,TYPE", "connection", "show"}) {
						return "wired:802-3-ethernet\nwifi:802-11-wireless\nvpn:vpn", nil
					}
					if reflect.DeepEqual(c.Args, []string{"-t", "-f", "DEVICE,TYPE,STATE", "device", "status"}) {
						return "eth0:ethernet:connected\nwlan0:wifi:connected\ntun0:tun:connected\nwlan1:wifi:disconnected", nil
					}
					return "", nil
				}}
				a := App{FS: f, Runner: r, In: strings.NewReader("9.9.9.9,2620:fe::fe\n"), Out: &out, Err: &out}
				if rc := a.Run(context.Background(), []string{provider}); rc != 0 {
					t.Fatal(out.String())
				}
				v4, v6, dot, ignore := "", "", "-1", "no"
				if provider == "Custom" {
					v4, v6, ignore = "9.9.9.9", "2620:fe::fe", "yes"
				}
				for _, p := range Providers {
					if p.Name == provider {
						v4, v6, ignore = WithSNI(p.V4, p.SNI), WithSNI(p.V6, p.SNI), "yes"
						if p.SNI != "" {
							dot = "opportunistic"
						}
					}
				}
				want := []run.Command{run.C("nmcli", "-t", "-f", "UUID,TYPE", "connection", "show")}
				for _, id := range []string{"wired", "wifi"} {
					want = append(want, run.C("nmcli", "connection", "modify", id, "ipv4.ignore-auto-dns", ignore, "ipv4.dns", v4, "ipv6.ignore-auto-dns", ignore, "ipv6.dns", v6, "connection.dns-over-tls", dot))
				}
				want = append(want, run.C("nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"), run.C("nmcli", "device", "reapply", "eth0"), run.C("nmcli", "device", "reapply", "wlan0"))
				if !nixos {
					want = append(want, run.C("nmcli", "general", "reload", "conf"), run.C("systemctl", "reload", "systemd-resolved.service"), run.C("nmcli", "general", "reload", "dns-full"))
				}
				if !reflect.DeepEqual(r.Calls, want) {
					t.Fatalf("commands:\ngot %#v\nwant %#v", r.Calls, want)
				}
				if nixos {
					if f.Exists("/etc/systemd/resolved.conf") {
						t.Fatal("NixOS wrote etc")
					}
				} else {
					b, e := f.Read("/etc/systemd/resolved.conf")
					if e != nil || !strings.Contains(string(b), "[Resolve]") {
						t.Fatal(string(b), e)
					}
					if provider == "DHCP" && f.Exists(global) {
						t.Fatal("DHCP left global DNS")
					}
				}
				if out.String() != "DNS: "+provider+"\n" {
					t.Fatal(out.String())
				}
			})
		}
	}
}
func TestCustom(t *testing.T) {
	for _, c := range []struct {
		s  string
		ok bool
	}{{"9.9.9.9,::1", true}, {"999.999.999.999", true}, {"abcd::", true}, {"", false}, {"1.1.1.1;touch /tmp/oops", false}, {"dns.example", false}, {"1.1.1.1#example", false}} {
		t.Run(c.s, func(t *testing.T) {
			_, _, e := Custom(c.s)
			if (e == nil) != c.ok {
				t.Fatal(e)
			}
		})
	}
}
func TestCLIAndElevation(t *testing.T) {
	for _, c := range []struct {
		name        string
		args        []string
		tty, denied bool
		code        int
		last        string
	}{{"bad", []string{"bad"}, false, false, 1, ""}, {"too many", []string{"DHCP", "x"}, false, false, 1, ""}, {"terminal", []string{"DHCP"}, true, false, 0, "sudo"}, {"permitted", []string{"Google"}, false, false, 0, "sudo"}, {"policykit", []string{"Custom"}, false, true, 0, "pkexec"}, {"child exit", []string{"DHCP"}, true, false, 42, "sudo"}} {
		t.Run(c.name, func(t *testing.T) {
			f := testkit.FS(t)
			var out bytes.Buffer
			r := &run.Fake{Handle: func(_ context.Context, q run.Command) (string, error) {
				if len(q.Args) > 0 && q.Args[0] == "-n" && c.denied {
					return "", run.ExitError{Code: 1}
				}
				if c.code == 42 {
					return "", run.ExitError{Code: 42}
				}
				return "", nil
			}}
			a := App{FS: f, Runner: r, UID: 1000, Terminal: c.tty, In: strings.NewReader(""), Out: &out, Err: &out}
			if got := a.Run(context.Background(), c.args); got != c.code {
				t.Fatal(got, out.String())
			}
			if c.last != "" && r.Calls[len(r.Calls)-1].Name != c.last {
				t.Fatal(r.Calls)
			}
		})
	}
}
func TestReloadFallbacks(t *testing.T) {
	f := testkit.FS(t)
	var out bytes.Buffer
	r := &run.Fake{Handle: func(_ context.Context, c run.Command) (string, error) {
		s := strings.Join(c.Args, " ")
		if s == "general reload conf" || s == "reload systemd-resolved.service" {
			return "", run.ExitError{Code: 1}
		}
		return "", nil
	}}
	a := App{FS: f, Runner: r, In: strings.NewReader(""), Out: &out, Err: &out}
	if a.Run(context.Background(), []string{"DHCP"}) != 0 {
		t.Fatal(out.String())
	}
	found := map[string]bool{}
	for _, c := range r.Calls {
		found[c.Name+" "+strings.Join(c.Args, " ")] = true
	}
	if !found["systemctl reload NetworkManager.service"] || !found["systemctl restart systemd-resolved.service"] {
		t.Fatal(r.Calls)
	}
}

func TestCommandErrorVisibility(t *testing.T) {
	var errout bytes.Buffer
	r := &run.Fake{Handle: func(_ context.Context, c run.Command) (string, error) {
		if c.Stderr != nil {
			fmt.Fprintln(c.Stderr, "command diagnostic")
		}
		return "", run.ExitError{Code: 10}
	}}
	a := App{Runner: r, Err: &errout}
	_, e := a.cmd(context.Background(), "nmcli", "connection", "modify")
	if run.Code(e) != 10 || errout.String() != "command diagnostic\n" {
		t.Fatal(errout.String(), e)
	}
	errout.Reset()
	_, _ = a.quiet(context.Background(), "nmcli", "device", "reapply")
	if errout.Len() != 0 {
		t.Fatal("quiet command leaked diagnostics")
	}
}
