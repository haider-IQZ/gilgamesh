package main

import (
	"context"
	"os"

	"github.com/haider-IQZ/gilgamesh/tools/internal/dns"
	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"golang.org/x/sys/unix"
)

func main() {
	_, e := unix.IoctlGetTermios(int(os.Stdin.Fd()), unix.TCGETS)
	_, nixosErr := os.Stat("/etc/NIXOS")
	if os.Geteuid() == 0 && len(os.Args) == 2 && os.IsNotExist(nixosErr) {
		_ = os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin")
	}
	a := dns.App{Runner: &run.Real{}, In: os.Stdin, Out: os.Stdout, Err: os.Stderr, UID: os.Geteuid(), Terminal: e == nil}
	os.Exit(a.Run(context.Background(), os.Args[1:]))
}
