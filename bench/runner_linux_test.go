package main

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestCommandHelper(t *testing.T) {
	if os.Getenv("BENCH_COMMAND_HELPER") != "1" {
		return
	}
	if os.Getenv("BENCH_COMMAND_SLEEP") == "1" {
		time.Sleep(10 * time.Second)
	}
	os.Stdout.WriteString("retained output\n")
	os.Exit(7)
}

func TestCommandFailureAndCancellation(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	env := []string{"BENCH_COMMAND_HELPER=1"}
	c := command(context.Background(), time.Second, "", env, exe, "-test.run=^TestCommandHelper$")
	if c.ExitCode != 7 || c.Error == "" || !strings.Contains(c.Output, "retained output") {
		t.Fatalf("lost failure details: %+v", c)
	}
	c = command(context.Background(), 30*time.Millisecond, "", append(env, "BENCH_COMMAND_SLEEP=1"), exe, "-test.run=^TestCommandHelper$")
	if c.Error == "" || c.Elapsed > 3 {
		t.Fatalf("timeout did not stop child: %+v", c)
	}
}

func TestTimerAffinityAndCancellation(t *testing.T) {
	mask, err := affinity()
	if err != nil {
		t.Skipf("affinity unavailable: %v", err)
	}
	cpus := maskCPUs(mask)
	if len(cpus) == 0 {
		t.Skip("no allowed CPUs")
	}
	if got := maskCPUs(singleCPU(mask, cpus[0])); !slices.Equal(got, cpus[:1]) {
		t.Fatalf("single CPU mask: %v", got)
	}
	cfg := Config{CPU: cpus[0], Duration: 5 * time.Millisecond, Interval: time.Millisecond}
	v, err := timerSample(context.Background(), cfg)
	if err != nil {
		t.Fatalf("pinned timer: %v", err)
	}
	if v["cycles"] < 1 || v["p99_us"] < 0 || v["max_us"] < v["p99_us"] {
		t.Fatalf("invalid timer endpoints: %v", v)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := timerSample(ctx, cfg); err == nil {
		t.Fatal("timer ignored cancellation")
	}
}

func TestRepeatStopsAtFailure(t *testing.T) {
	s := &Suite{Status: "ok", Metrics: map[string]Metric{}}
	calls := 0
	repeat(context.Background(), Config{Repeats: 5, Warmups: 1}, s, func(warmup bool) error {
		calls++
		if calls == 1 && !warmup {
			t.Fatal("first repetition was not marked warmup")
		}
		if calls == 3 {
			return context.Canceled
		}
		return nil
	})
	if s.Status != "failed" || calls != 3 {
		t.Fatalf("continued after failure: %d %s", calls, s.Status)
	}
}
