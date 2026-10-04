package dns

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"regexp"
	"strings"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/fsys"
)

const InstalledPath = "/usr/bin/gilgamesh-dns"
const global = "/etc/NetworkManager/conf.d/20-gilgamesh-dns.conf"

type Provider struct{ Name, V4, V6, SNI string }

var Providers = []Provider{{"Cloudflare", "1.1.1.1 1.0.0.1", "2606:4700:4700::1111 2606:4700:4700::1001", "cloudflare-dns.com"}, {"Google", "8.8.8.8 8.8.4.4", "2001:4860:4860::8888 2001:4860:4860::8844", "dns.google"}, {"OpenDNS", "208.67.222.222 208.67.220.220", "2620:119:35::35 2620:119:53::53", ""}}

type App struct {
	Runner   run.Runner
	FS       fsys.FS
	In       io.Reader
	Out, Err io.Writer
	UID      int
	Terminal bool
}

func (a App) cmd(ctx context.Context, n string, args ...string) (string, error) {
	c := run.C(n, args...)
	c.Stderr = a.Err
	s, e := a.Runner.Run(ctx, c)
	return strings.TrimSpace(s), e
}
func (a App) quiet(ctx context.Context, n string, args ...string) (string, error) {
	s, e := a.Runner.Run(ctx, run.C(n, args...))
	return strings.TrimSpace(s), e
}
func network(t string) bool { return t == "802-3-ethernet" || t == "802-11-wireless" }
func WithSNI(ips, sni string) string {
	if sni == "" {
		return ips
	}
	a := strings.Fields(ips)
	for i := range a {
		a[i] += "#" + sni
	}
	return strings.Join(a, " ")
}
func (a App) Current(ctx context.Context) (string, error) {
	s, e := a.cmd(ctx, "nmcli", "-t", "-f", "UUID,TYPE,DEVICE", "connection", "show", "--active")
	if e != nil {
		return "", e
	}
	uuid := ""
	for _, l := range strings.Split(s, "\n") {
		v := strings.Split(l, ":")
		if len(v) >= 3 && network(v[1]) && v[2] != "" {
			uuid = v[0]
			break
		}
	}
	if uuid == "" {
		return "DHCP", nil
	}
	ignore, e := a.cmd(ctx, "nmcli", "-g", "ipv4.ignore-auto-dns", "connection", "show", uuid)
	if e != nil {
		return "", e
	}
	servers, e := a.cmd(ctx, "nmcli", "-g", "ipv4.dns", "connection", "show", uuid)
	if e != nil {
		return "", e
	}
	if ignore != "yes" || servers == "" {
		return "DHCP", nil
	}
	first := strings.SplitN(strings.SplitN(strings.SplitN(servers, " ", 2)[0], ",", 2)[0], "#", 2)[0]
	for _, p := range Providers {
		for _, ip := range strings.Fields(p.V4) {
			if ip == first {
				return p.Name, nil
			}
		}
	}
	return "Custom", nil
}

// Intentionally matches the Bash CLI's syntactic validation, including IPv4
// octets >255; NetworkManager remains the final validator.
var ipv4 = regexp.MustCompile(`^[0-9]{1,3}(\.[0-9]{1,3}){3}$`)
var ipv6 = regexp.MustCompile(`^[0-9a-fA-F:]+$`)

func Custom(input string) (string, string, error) {
	var v4, v6 []string
	for _, s := range strings.Fields(strings.ReplaceAll(input, ",", " ")) {
		if ipv4.MatchString(s) {
			v4 = append(v4, s)
		} else if ipv6.MatchString(s) && strings.Contains(s, ":") {
			v6 = append(v6, s)
		} else {
			return "", "", fmt.Errorf("not an IP address: %s", s)
		}
	}
	if len(v4)+len(v6) == 0 {
		return "", "", fmt.Errorf("no servers given")
	}
	return strings.Join(v4, " "), strings.Join(v6, " "), nil
}
func (a App) Run(ctx context.Context, args []string) int {
	e := a.apply(ctx, args)
	if e != nil {
		fmt.Fprintln(a.Err, e)
		return run.Code(e)
	}
	return 0
}
func (a App) apply(ctx context.Context, args []string) error {
	if len(args) == 0 {
		s, e := a.Current(ctx)
		if e == nil {
			fmt.Fprintln(a.Out, s)
		}
		return e
	}
	valid := len(args) == 1
	if valid {
		valid = args[0] == "DHCP" || args[0] == "Custom"
		for _, p := range Providers {
			valid = valid || args[0] == p.Name
		}
	}
	if !valid {
		return fmt.Errorf("usage: gilgamesh-dns [DHCP|Cloudflare|Google|OpenDNS|Custom]")
	}
	name := args[0]
	nixos := a.FS.Exists("/etc/NIXOS")
	if !nixos && a.UID != 0 {
		e := error(nil)
		if !a.Terminal {
			_, e = a.quiet(ctx, "sudo", "-n", "-l", InstalledPath, name)
		}
		n := "sudo"
		if e != nil {
			n = "pkexec"
		}
		s, e := a.Runner.Run(ctx, run.Command{Name: n, Args: []string{InstalledPath, name}, Stdin: a.In, Stdout: a.Out, Stderr: a.Err, Replace: true})
		fmt.Fprint(a.Out, s)
		return e
	}
	v4, v6, dot, ignore := "", "", "-1", "no"
	if name == "Custom" {
		if a.Terminal {
			fmt.Fprint(a.Err, "DNS servers (space separated, e.g. 9.9.9.9 149.112.112.112): ")
		}
		sc := bufio.NewScanner(a.In)
		if !sc.Scan() {
			return fmt.Errorf("no servers given")
		}
		var e error
		v4, v6, e = Custom(sc.Text())
		if e != nil {
			return e
		}
		ignore = "yes"
	} else {
		for _, p := range Providers {
			if p.Name == name {
				v4 = WithSNI(p.V4, p.SNI)
				v6 = WithSNI(p.V6, p.SNI)
				ignore = "yes"
				if p.SNI != "" {
					dot = "opportunistic"
				}
			}
		}
	}
	// Bash process substitutions ignore failures in these two inventory commands.
	profiles, _ := a.cmd(ctx, "nmcli", "-t", "-f", "UUID,TYPE", "connection", "show")
	for _, line := range strings.Split(profiles, "\n") {
		v := strings.Split(line, ":")
		if len(v) < 2 || !network(v[1]) {
			continue
		}
		if _, e := a.cmd(ctx, "nmcli", "connection", "modify", v[0], "ipv4.ignore-auto-dns", ignore, "ipv4.dns", v4, "ipv6.ignore-auto-dns", ignore, "ipv6.dns", v6, "connection.dns-over-tls", dot); e != nil {
			return e
		}
	}
	devices, _ := a.cmd(ctx, "nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status")
	for _, line := range strings.Split(devices, "\n") {
		v := strings.Split(line, ":")
		if len(v) == 3 && v[2] == "connected" && (v[1] == "ethernet" || v[1] == "wifi") {
			_, _ = a.quiet(ctx, "nmcli", "device", "reapply", v[0])
		}
	}
	if !nixos {
		servers := strings.TrimSpace(v4 + " " + v6)
		etcDot := "no"
		if dot == "opportunistic" {
			etcDot = dot
		}
		resolved := "[Resolve]\nDNSOverTLS=no\n"
		if servers != "" {
			if e := a.FS.Write(global, []byte("# Managed by gilgamesh-dns. \"gilgamesh-dns DHCP\" removes it.\n[global-dns]\n\n[global-dns-domain-*]\nservers="+strings.ReplaceAll(servers, " ", ",")+"\n"), 0644); e != nil {
				return e
			}
			resolved = "[Resolve]\nDNS=" + servers + "\nFallbackDNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net\nDNSOverTLS=" + etcDot + "\n"
		} else if e := a.FS.Remove(global); e != nil {
			return e
		}
		if e := a.FS.Write("/etc/systemd/resolved.conf", []byte(resolved), 0644); e != nil {
			return e
		}
		if _, e := a.quiet(ctx, "nmcli", "general", "reload", "conf"); e != nil {
			_, _ = a.cmd(ctx, "systemctl", "reload", "NetworkManager.service")
		}
		if _, e := a.quiet(ctx, "systemctl", "reload", "systemd-resolved.service"); e != nil {
			if _, e = a.cmd(ctx, "systemctl", "restart", "systemd-resolved.service"); e != nil {
				return e
			}
		}
		_, _ = a.quiet(ctx, "nmcli", "general", "reload", "dns-full")
	}
	fmt.Fprintln(a.Out, "DNS: "+name)
	return nil
}
