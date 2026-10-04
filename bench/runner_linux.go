package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type limitedBuffer struct {
	bytes.Buffer
	truncated bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	remaining := 4*1024*1024 - b.Len()
	if len(p) > remaining {
		p = p[:remaining]
		b.truncated = true
	}
	_, _ = b.Buffer.Write(p)
	return n, nil
}

func command(ctx context.Context, timeout time.Duration, dir string, env []string, args ...string) Command {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	c := exec.CommandContext(ctx, args[0], args[1:]...)
	c.Dir = dir
	c.Env = append(os.Environ(), "LC_ALL=C", "LANG=C", "SYSTEMD_PAGER=cat", "SYSTEMD_COLORS=0")
	c.Env = append(c.Env, env...)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.Cancel = func() error { return syscall.Kill(-c.Process.Pid, syscall.SIGKILL) }
	c.WaitDelay = 2 * time.Second
	var output limitedBuffer
	c.Stdout, c.Stderr = &output, &output
	start := time.Now()
	err := c.Run()
	r := Command{Args: args, Elapsed: time.Since(start).Seconds(), Output: output.String()}
	r.Truncated = output.truncated
	if err != nil {
		r.Error = err.Error()
		if ctx.Err() != nil {
			r.Error = ctx.Err().Error() + ": " + r.Error
		}
		r.ExitCode = -1
		if c.ProcessState != nil {
			r.ExitCode = c.ProcessState.ExitCode()
		}
	}
	return r
}

func pause(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func skipped(s *Suite, reason string) {
	s.Status, s.Reason = "skipped", reason
}

func failed(s *Suite, err error) {
	s.Status, s.Reason = "failed", err.Error()
}

func record(s *Suite, c Command, warmup bool) error {
	c.Warmup = warmup
	s.Commands = append(s.Commands, c)
	if c.Error != "" {
		return fmt.Errorf("%s: %s (see retained command output)", c.Args[0], c.Error)
	}
	if c.Truncated {
		return fmt.Errorf("command output exceeded 4 MiB; refusing partial metrics")
	}
	return nil
}

func repeat(ctx context.Context, cfg Config, s *Suite, run func(bool) error) {
	for i := -cfg.Warmups; i < cfg.Repeats; i++ {
		if err := ctx.Err(); err != nil {
			failed(s, err)
			return
		}
		kind := "sample"
		if i < 0 {
			kind = "warmup"
		}
		fmt.Fprintf(os.Stderr, "  %s %d\n", kind, i+cfg.Warmups+1)
		if err := run(i < 0); err != nil {
			failed(s, err)
			return
		}
		if i < cfg.Repeats-1 {
			if err := pause(ctx, cfg.Cooldown); err != nil {
				failed(s, err)
				return
			}
		}
	}
}

func addMetrics(s *Suite, values map[string]float64) {
	for name, v := range values {
		unit := "count"
		switch {
		case strings.HasSuffix(name, "_us"):
			unit = "us"
		case strings.HasSuffix(name, "_s"):
			unit = "s"
		case strings.HasSuffix(name, "_bytes"):
			unit = "bytes"
		case name == "iops":
			unit = "IOPS"
		}
		s.add(name, unit, v)
	}
}
