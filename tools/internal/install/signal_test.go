package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

func signalArgs() []string {
	for n, a := range os.Args {
		if a == "--signal-helper" {
			return os.Args[n+1:]
		}
	}
	return nil
}
func waitFile(p string) error {
	until := time.Now().Add(5 * time.Second)
	for time.Now().Before(until) {
		if _, e := os.Stat(p); e == nil {
			return nil
		}
		time.Sleep(5 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %s", p)
}

// A real subprocess tree stands in for pacstrap. It needs time after TERM to
// release nested resources, and the installer must reap it before unmounting.
func TestSignalHelper(t *testing.T) {
	a := signalArgs()
	if len(a) == 0 {
		return
	}
	mode, dir := a[0], a[1]
	if mode == "package" || mode == "descendant" {
		signals := make(chan os.Signal, 4)
		signal.Notify(signals, syscall.SIGTERM)
		var child *exec.Cmd
		if mode == "package" {
			child = exec.Command(os.Args[0], "-test.run=^TestSignalHelper$", "--", "--signal-helper", "descendant", dir)
			if e := child.Start(); e != nil {
				os.Exit(3)
			}
			if e := waitFile(dir + "/descendant-ready"); e != nil {
				os.Exit(4)
			}
		}
		_ = os.WriteFile(dir+"/"+mode+"-ready", []byte(strconv.Itoa(os.Getpid())), 0600)
		<-signals
		signal.Ignore(syscall.SIGTERM)
		time.Sleep(200 * time.Millisecond)
		if child != nil {
			if e := child.Wait(); e != nil {
				os.Exit(5)
			}
		}
		_ = os.WriteFile(dir+"/"+mode+"-cleaned", []byte("yes"), 0600)
		os.Exit(0)
	}
	if mode != "installer" {
		t.Fatal(mode)
	}
	x := newFixture(t, "")
	s := run.WatchSignals()
	defer s.Stop()
	x.i.BeforeCleanup = s.Ignore
	x.packageHook = func(ctx context.Context) error {
		_, e := (&run.Real{}).Run(ctx, run.C(os.Args[0], "-test.run=^TestSignalHelper$", "--", "--signal-helper", "package", dir))
		return e
	}
	original := x.r.Handle
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		if c.Name == "umount" {
			if _, e := os.Stat(dir + "/package-cleaned"); e != nil {
				return "", fmt.Errorf("cleanup ran before package process released resources")
			}
		}
		return original(ctx, c)
	}
	e := x.i.Full(s.Context)
	if !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	if e = x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	x.i.Close()
	if len(x.mounts) != 0 {
		t.Fatal(x.mounts)
	}
	expectedCode, _ := strconv.Atoi(a[2])
	if s.Code() != expectedCode {
		t.Fatal("signal exit code", s.Code())
	}
	if !strings.Contains(x.i.Message(), "Installing packages") || !strings.Contains(x.i.Message(), "partially installed") {
		t.Fatal(x.i.Message())
	}
	unmounts := 0
	for _, c := range x.r.Calls {
		if c.Name == "umount" {
			unmounts++
		}
	}
	if unmounts != 2 {
		t.Fatal("cleanup repeated", unmounts)
	}
	fmt.Println(x.i.Message())
}
func TestDoubleSignalDuringPackage(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT} {
		t.Run(sig.String(), func(t *testing.T) {
			f := testkit.FS(t)
			cmd := exec.Command(os.Args[0], "-test.run=^TestSignalHelper$", "--", "--signal-helper", "installer", f.Root, strconv.Itoa(128+int(sig)))
			var output strings.Builder
			cmd.Stdout = &output
			cmd.Stderr = &output
			if e := cmd.Start(); e != nil {
				t.Fatal(e)
			}
			finished := false
			defer func() {
				if !finished {
					_ = cmd.Process.Kill()
					_ = cmd.Wait()
				}
			}()
			if e := waitFile(f.Path("/package-ready")); e != nil {
				t.Fatal(e)
			}
			if e := cmd.Process.Signal(sig); e != nil {
				t.Fatal(e)
			}
			time.Sleep(50 * time.Millisecond)
			if e := cmd.Process.Signal(sig); e != nil {
				t.Fatal(e)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case e := <-done:
				finished = true
				if e != nil {
					t.Fatal(e, output.String())
				}
			case <-time.After(15 * time.Second):
				t.Fatal("signal cleanup timed out")
			}
			for _, kind := range []string{"package", "descendant"} {
				b, e := os.ReadFile(f.Path("/" + kind + "-ready"))
				if e != nil {
					t.Fatal(e)
				}
				pid, _ := strconv.Atoi(string(b))
				if syscall.Kill(pid, 0) != syscall.ESRCH {
					t.Fatal("surviving child", pid)
				}
				if !f.Exists("/" + kind + "-cleaned") {
					t.Fatal("child not given cleanup grace", kind)
				}
			}
			if !strings.Contains(output.String(), "partially installed") {
				t.Fatal(output.String())
			}
		})
	}
}
