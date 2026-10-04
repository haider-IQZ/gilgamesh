package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/install"
	"github.com/haider-IQZ/gilgamesh/tools/internal/ui"
)

func main() { os.Exit(mainCode()) }
func mainCode() (rc int) {
	var i *install.Installer
	var s *run.Signals
	var u *ui.UI
	var terminal *os.File
	var e error
	defer func() {
		if p := recover(); p != nil {
			e = fmt.Errorf("installer panicked: %v", p)
		}
		if terminal != nil {
			defer terminal.Close() // after the failure screen has measured it
		}
		if s != nil {
			s.Ignore()
			defer s.Stop()
		}
		var cleanupErr error
		if i != nil {
			defer i.Close()
			cleanupErr = i.Cleanup()
		}
		if e != nil {
			rc = run.Code(e)
			if errors.Is(e, ui.ErrAborted) {
				rc = 130
			}
			var tail []string
			if i != nil && i.Log != nil {
				if b, err := i.FS.Read(install.LogPath); err == nil {
					lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
					tail = lines[max(0, len(lines)-25):]
				}
			}
			switch {
			case u != nil && errors.Is(e, ui.ErrAborted):
				// Omarchy's abort(): a plain line, since nothing has been touched.
				fmt.Fprintln(os.Stdout, "\033[0m\033[?25h\nAborted installation")
			case u != nil:
				footer := "Run gilgamesh-install to try again."
				if i != nil && i.Log != nil {
					footer = "Log: " + install.LogPath
				}
				u.Failure(e.Error(), tail, footer)
			default:
				fmt.Fprintln(os.Stderr, e)
				fmt.Fprintln(os.Stderr, strings.Join(tail, "\n"))
			}
		}
		if s != nil && s.Code() != 0 {
			rc = s.Code()
			if i != nil {
				fmt.Fprintln(os.Stderr, "Interrupted at step:", i.Current)
			}
		}
		if cleanupErr != nil {
			fmt.Fprintln(os.Stderr, cleanupErr)
			rc = 1
		}
		if i != nil {
			fmt.Fprintln(os.Stdout, i.Message())
		}
	}()
	flags := flag.NewFlagSet("gilgamesh-install", flag.ContinueOnError)
	dry := flags.Bool("dry-run", false, "ask questions and preview; write nothing")
	src := flags.String("source", install.FindSource(), "local Gilgamesh checkout")
	exe, _ := os.Executable()
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dns := flags.String("dns-binary", filepath.Join(filepath.Dir(exe), "gilgamesh-dns"), "built Go DNS binary")
	if e := flags.Parse(os.Args[1:]); e != nil {
		if errors.Is(e, flag.ErrHelp) {
			return 0
		}
		return 1
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return 1
	}
	s = run.WatchSignals()
	terminal, e = os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if e != nil {
		e = fmt.Errorf("installer needs an interactive terminal: %w", e)
		return 1
	}
	tty, _ := os.Readlink("/proc/self/fd/0")
	console := strings.HasPrefix(tty, "/dev/tty") && len(tty) > 8 && tty[8] >= '0' && tty[8] <= '9'
	u = &ui.UI{In: terminal, Out: os.Stdout, Dry: *dry}
	u.WaitStable(s.Context)
	i = &install.Installer{Runner: &run.Real{}, UI: u, Src: filepath.Clean(*src), DNSBinary: *dns, Dry: *dry, UID: os.Geteuid(), Console: console, Out: os.Stdout, Kernel: os.Getenv("KERNEL"), BeforeCleanup: s.Ignore}
	e = i.Full(s.Context)
	return 0
}
