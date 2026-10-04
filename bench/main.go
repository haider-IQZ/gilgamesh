package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"time"
)

var suiteNames = []string{"boot", "sched", "messaging", "memory", "io", "compile"}

func main() {
	if err := cli(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "gilgamesh-bench:", err)
		os.Exit(1)
	}
}

func cli(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: gilgamesh-bench run --label NAME [flags] | compare [--paired] A.json B.json (or two directories)")
	}
	switch args[0] {
	case "run":
		return runCLI(args[1:])
	case "compare":
		return compareCLI(args[1:])
	case "help", "--help", "-h":
		fmt.Println("gilgamesh-bench run --label NAME [--suites boot,sched,messaging,memory,io,compile]\ngilgamesh-bench compare [--paired] A.json B.json\nInputs to compare may also be directories of results. Use run --help for workload flags.")
		return nil
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func runCLI(args []string) error {
	var cfg Config
	f := flag.NewFlagSet("run", flag.ContinueOnError)
	f.StringVar(&cfg.Label, "label", "", "condition name (letters, digits, dot, underscore, dash)")
	f.StringVar(&cfg.Block, "block", "", "paired experiment block ID (optional)")
	f.StringVar(&cfg.Suites, "suites", strings.Join(suiteNames, ","), "comma-separated suites")
	f.IntVar(&cfg.Repeats, "repeats", 5, "measured runs per suite (boot is read once)")
	f.IntVar(&cfg.Warmups, "warmups", 1, "discarded runs per suite (none for boot)")
	f.DurationVar(&cfg.Settle, "settle", 10*time.Second, "idle settling before all suites")
	f.DurationVar(&cfg.Cooldown, "cooldown", time.Second, "pause between runs")
	f.DurationVar(&cfg.Duration, "duration", 10*time.Second, "duration of each sched/io run, whole seconds")
	f.DurationVar(&cfg.Interval, "interval", time.Millisecond, "sched timer interval, whole microseconds")
	f.IntVar(&cfg.CPU, "cpu", -1, "sched CPU (-1 selects first allowed CPU)")
	f.StringVar(&cfg.IODir, "io-dir", "", "existing scratch directory for the temporary fio file")
	f.IntVar(&cfg.IOSizeMiB, "io-size-mib", 256, "scratch file size in MiB")
	f.DurationVar(&cfg.IORamp, "io-ramp", 5*time.Second, "fio ramp time, whole seconds")
	f.StringVar(&cfg.ModuleDir, "module-dir", ".", "path to this bench module for the compile suite")
	f.StringVar(&cfg.MemoryScope, "memory-scope", "session", "RSS scope: session (POSIX session ID) or uid (all current user's processes)")
	if err := f.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if f.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if err := validateConfig(cfg); err != nil {
		return err
	}
	selected := strings.Split(cfg.Suites, ",")
	if slices.Contains(selected, "sched") {
		mask, err := affinity()
		if err != nil {
			return fmt.Errorf("read CPU affinity: %w", err)
		}
		cpus := maskCPUs(mask)
		if len(cpus) == 0 {
			return fmt.Errorf("no allowed CPUs")
		}
		if cfg.CPU == -1 {
			cfg.CPU = cpus[0]
		}
		if !slices.Contains(cpus, cfg.CPU) {
			return fmt.Errorf("CPU %d is outside allowed affinity", cfg.CPU)
		}
	}
	var err error
	cfg.ModuleDir, err = filepath.Abs(cfg.ModuleDir)
	if err != nil {
		return err
	}
	if cfg.IODir != "" {
		cfg.IODir, err = filepath.Abs(cfg.IODir)
		if err != nil {
			return err
		}
	}
	if err := os.MkdirAll("results", 0700); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	r := Result{Version: 1, Started: time.Now().UTC(), Config: cfg, System: systemInfo(), Suites: map[string]*Suite{}}
	fmt.Fprintf(os.Stderr, "Settling for %s; %d measured repeats per workload\n", cfg.Settle, cfg.Repeats)
	settleErr := pause(ctx, cfg.Settle)
	hasFailure := settleErr != nil
	for _, name := range selected {
		s := &Suite{Status: "ok", Metrics: map[string]Metric{}}
		r.Suites[name] = s
		fmt.Fprintln(os.Stderr, name+":")
		if settleErr != nil || ctx.Err() != nil {
			failed(s, ctx.Err())
		} else {
			switch name {
			case "boot":
				bootSuite(ctx, cfg, s)
			case "sched":
				schedSuite(ctx, cfg, s)
			case "messaging":
				messagingSuite(ctx, cfg, s)
			case "memory":
				memorySuite(ctx, cfg, s)
			case "io":
				ioSuite(ctx, cfg, s)
			case "compile":
				compileSuite(ctx, cfg, s)
			}
		}
		fmt.Fprintf(os.Stderr, "  %s %s\n", s.Status, s.Reason)
		for _, note := range s.Notes {
			fmt.Fprintln(os.Stderr, "  "+note)
		}
		hasFailure = hasFailure || s.Status == "failed"
	}
	path, err := saveResult(r)
	if err != nil {
		return err
	}
	fmt.Println(path)
	if hasFailure {
		return fmt.Errorf("one or more suites failed; partial results and command output saved")
	}
	return nil
}

func validateConfig(c Config) error {
	if !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$`).MatchString(c.Label) {
		return fmt.Errorf("--label must be 1–80 filename-safe characters starting with a letter or digit")
	}
	seen := map[string]bool{}
	for _, name := range strings.Split(c.Suites, ",") {
		if !slices.Contains(suiteNames, name) || seen[name] {
			return fmt.Errorf("unknown or duplicate suite %q (choose %s)", name, strings.Join(suiteNames, ","))
		}
		seen[name] = true
	}
	if c.Repeats < 1 || c.Repeats > 1000 || c.Warmups < 0 || c.Warmups > 100 {
		return fmt.Errorf("--repeats must be 1..1000 and --warmups 0..100")
	}
	if c.Settle < 0 || c.Cooldown < 0 || c.Duration < time.Second || c.Duration > time.Hour || c.Duration%time.Second != 0 || c.IORamp < 0 || c.IORamp > time.Hour || c.IORamp%time.Second != 0 {
		return fmt.Errorf("settle/cooldown must be nonnegative; duration must be 1s..1h and io-ramp 0s..1h, both whole seconds")
	}
	if c.Interval < time.Microsecond || c.Interval > c.Duration || c.Interval%time.Microsecond != 0 || c.CPU < -1 {
		return fmt.Errorf("interval must be whole microseconds between 1us and duration; cpu must be >= -1")
	}
	if c.IOSizeMiB < 1 || c.IOSizeMiB > 1048576 {
		return fmt.Errorf("io-size-mib must be 1..1048576")
	}
	if c.MemoryScope != "session" && c.MemoryScope != "uid" {
		return fmt.Errorf("memory-scope must be session or uid")
	}
	return nil
}

func saveResult(r Result) (string, error) {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	path := filepath.Join("results", r.Config.Label+"-"+r.Started.Format("20060102T150405.000000000Z")+".json")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return "", err
	}
	_, err = f.Write(append(b, '\n'))
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	return path, err
}
