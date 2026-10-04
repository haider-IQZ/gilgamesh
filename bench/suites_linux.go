package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func bootSuite(ctx context.Context, cfg Config, s *Suite) {
	s.Method, s.Workload = "systemd-analyze", "time, blame, critical-chain graphical.target; one sample per boot"
	if _, err := exec.LookPath("systemd-analyze"); err != nil {
		skipped(s, "systemd-analyze is not installed")
		return
	}
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		skipped(s, "systemd is not running as the system manager")
		return
	}
	s.Notes = append(s.Notes, "Boot timings are read once; repeats do not create independent boots. Unit timings overlap and must not be summed. This does not measure visible desktop readiness.")
	for _, task := range []struct {
		args   []string
		prefix string
		parse  func(string) (map[string]float64, error)
	}{
		{[]string{"time"}, "", parseBootTime},
		{[]string{"blame"}, "blame.", parseBlame},
		{[]string{"critical-chain", "graphical.target"}, "chain.", parseChain},
	} {
		c := command(ctx, 30*time.Second, "", nil, append([]string{"systemd-analyze", "--no-pager"}, task.args...)...)
		if err := record(s, c, false); err != nil {
			failed(s, err)
			return
		}
		values, err := task.parse(c.Output)
		if err != nil {
			failed(s, err)
			return
		}
		for name, v := range values {
			s.add(task.prefix+name, "s", v)
		}
	}
}

func timerSample(ctx context.Context, cfg Config) (map[string]float64, error) {
	type response struct {
		values map[string]float64
		err    error
	}
	done := make(chan response, 1)
	go func() {
		runtime.LockOSThread()
		mask, err := affinity()
		if err != nil {
			runtime.UnlockOSThread()
			done <- response{err: err}
			return
		}
		if err := setAffinity(singleCPU(mask, cfg.CPU)); err != nil {
			runtime.UnlockOSThread()
			done <- response{err: err}
			return
		}
		values, sampleErr := measureTimer(ctx, cfg.Duration, cfg.Interval)
		if err := setAffinity(mask); err != nil {
			// Exiting while locked retires this thread instead of leaking its affinity.
			done <- response{err: fmt.Errorf("restore thread affinity: %w", err)}
			return
		}
		runtime.UnlockOSThread()
		done <- response{values, sampleErr}
	}()
	r := <-done
	return r.values, r.err
}

func measureTimer(ctx context.Context, duration, interval time.Duration) (map[string]float64, error) {
	values := make([]float64, 0, min(int(duration/interval), 1000000))
	end := time.Now().Add(duration)
	for time.Now().Before(end) {
		deadline := time.Now().Add(interval)
		if err := pause(ctx, time.Until(deadline)); err != nil {
			return nil, err
		}
		values = append(values, math.Max(0, float64(time.Since(deadline))/1000))
	}
	if len(values) == 0 {
		return nil, fmt.Errorf("no timer samples")
	}
	return map[string]float64{
		"p50_us": quantile(values, .5), "p99_us": quantile(values, .99),
		"p999_us": quantile(values, .999), "max_us": slices.Max(values), "cycles": float64(len(values)),
	}, nil
}

func schedSuite(ctx context.Context, cfg Config, s *Suite) {
	s.Workload = fmt.Sprintf("cpu=%d interval=%s duration=%s policy=other threads=1", cfg.CPU, cfg.Interval, cfg.Duration)
	if _, err := exec.LookPath("cyclictest"); err != nil {
		s.Method = "go-timer-approximate"
		s.Notes = append(s.Notes, "cyclictest missing: approximate Go timer wakeup lateness on an OS thread pinned to one allowed CPU. Includes Go runtime, GC and timer overhead; relative sleeps omit missed periods. Not equivalent to cyclictest or a realtime guarantee.")
		repeat(ctx, cfg, s, func(warmup bool) error {
			values, err := timerSample(ctx, cfg)
			if err == nil && !warmup {
				addMetrics(s, values)
			}
			return err
		})
		return
	}
	s.Method = "cyclictest-other"
	repeat(ctx, cfg, s, func(warmup bool) error {
		dir, err := os.MkdirTemp("results", ".cyclic-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		path := filepath.Join(dir, "sample.json")
		c := command(ctx, cfg.Duration+30*time.Second, "", nil,
			"cyclictest", "--default-system", "--policy=other", "--priority=0", "--threads=1",
			"--affinity="+strconv.Itoa(cfg.CPU), "--interval="+strconv.FormatInt(cfg.Interval.Microseconds(), 10),
			"--distance=0", "--duration="+strconv.FormatInt(int64(math.Ceil(cfg.Duration.Seconds())), 10)+"s",
			"--histogram=100000", "--quiet", "--json="+path)
		if err := record(s, c, warmup); err != nil {
			return err
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		s.Commands[len(s.Commands)-1].Output += "\n" + string(b)
		values, err := parseCyclic(string(b))
		if err == nil && !warmup {
			addMetrics(s, values)
		}
		return err
	})
}

func messagingSuite(ctx context.Context, cfg Config, s *Suite) {
	var args []string
	if _, err := exec.LookPath("hackbench"); err == nil {
		s.Method = "hackbench"
		args = []string{"hackbench", "-P", "-g", "2", "-f", "10", "-l", "10000", "-s", "256"}
	} else if _, err := exec.LookPath("perf"); err == nil {
		s.Method = "perf-bench-sched-messaging"
		s.Notes = append(s.Notes, "hackbench missing; using perf bench sched messaging")
		args = []string{"perf", "bench", "sched", "messaging", "-g", "2", "-l", "10000"}
	} else {
		skipped(s, "neither hackbench nor perf is installed")
		return
	}
	s.Workload = strings.Join(args, " ")
	repeat(ctx, cfg, s, func(warmup bool) error {
		c := command(ctx, 10*time.Minute, "", nil, args...)
		if err := record(s, c, warmup); err != nil {
			return err
		}
		v, err := parseElapsed(c.Output)
		if err == nil && !warmup {
			s.add("elapsed_s", "s", v)
		}
		return err
	})
}

func memorySuite(ctx context.Context, cfg Config, s *Suite) {
	s.Method, s.Workload = "procfs-rss", "scope="+cfg.MemoryScope+"; excludes harness; summed RSS double-counts shared pages"
	s.Notes = append(s.Notes, "Snapshot only: the caller must arrange an idle session. POSIX session scope may omit applications launched by a user service manager; uid scope includes other logins. zram counters are cumulative snapshots, not rates.")
	self, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		skipped(s, "procfs unavailable: "+err.Error())
		return
	}
	sid, err := parseProcStat(string(self))
	if err != nil {
		failed(s, err)
		return
	}
	repeat(ctx, cfg, s, func(warmup bool) error {
		entries, err := os.ReadDir("/proc")
		if err != nil {
			return err
		}
		var rss, count, unreadable float64
		for _, entry := range entries {
			pid, err := strconv.Atoi(entry.Name())
			if err != nil || pid == os.Getpid() {
				continue
			}
			base := filepath.Join("/proc", entry.Name())
			fi, err := os.Stat(base)
			if err != nil || fi.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
				continue
			}
			if cfg.MemoryScope == "session" {
				b, err := os.ReadFile(filepath.Join(base, "stat"))
				if err != nil {
					unreadable++
					continue
				}
				id, err := parseProcStat(string(b))
				if err != nil || id != sid {
					continue
				}
			}
			b, err := os.ReadFile(filepath.Join(base, "status"))
			v, ok := parseKB(string(b), "VmRSS")
			if err != nil || !ok {
				unreadable++
				continue
			}
			rss += v
			count++
		}
		if count == 0 {
			return fmt.Errorf("no readable processes in selected memory scope")
		}
		if warmup {
			return nil
		}
		s.add("session_rss_bytes", "bytes", rss)
		s.add("processes", "count", count)
		s.add("unreadable_processes", "count", unreadable)
		mem := readText("/proc/meminfo")
		for _, key := range []string{"MemAvailable", "SwapFree", "SwapTotal"} {
			if v, ok := parseKB(mem, key); ok {
				s.add(key+"_bytes", "bytes", v)
			}
		}
		paths, _ := filepath.Glob("/sys/block/zram*/mm_stat")
		if len(paths) == 0 && len(s.Metrics["session_rss_bytes"].Samples) == 1 {
			s.Notes = append(s.Notes, "zram statistics skipped: no zram devices")
		}
		for _, p := range paths {
			values, err := parseZram(readText(p))
			if err != nil {
				return fmt.Errorf("%s: %w", p, err)
			}
			for name, v := range values {
				s.add(filepath.Base(filepath.Dir(p))+"."+name, "bytes", v)
			}
		}
		return nil
	})
}

func ioSuite(ctx context.Context, cfg Config, s *Suite) {
	s.Method = "fio-psync-direct"
	s.Workload = fmt.Sprintf("randread bs=4096 qd=1 size=%dMiB duration=%s ramp=%s seed=42 total-latency", cfg.IOSizeMiB, cfg.Duration, cfg.IORamp)
	if cfg.IODir == "" {
		skipped(s, "requires --io-dir pointing to a scratch directory on the filesystem to measure")
		return
	}
	if _, err := exec.LookPath("fio"); err != nil {
		skipped(s, "fio is not installed")
		return
	}
	version := command(ctx, 10*time.Second, "", nil, "fio", "--version")
	if err := record(s, version, true); err != nil {
		failed(s, err)
		return
	}
	if !strings.HasPrefix(strings.TrimSpace(version.Output), "fio-") {
		skipped(s, "fio executable is not the Flexible I/O Tester")
		return
	}
	dir, err := os.MkdirTemp(cfg.IODir, ".gilgamesh-bench-")
	if err != nil {
		failed(s, err)
		return
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, "data")
	f, err := os.OpenFile(file, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		failed(s, err)
		return
	}
	// Fill every block before measuring; sparse holes are not storage reads.
	buf := make([]byte, 1024*1024)
	rng := rand.NewChaCha8([32]byte{42})
	for i := 0; i < cfg.IOSizeMiB && err == nil; i++ {
		err = ctx.Err()
		if err == nil {
			_, _ = rng.Read(buf)
			_, err = f.Write(buf)
		}
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		failed(s, err)
		return
	}
	s.Notes = append(s.Notes, "Pre-filled and fsynced private temporary file; direct reads bypass guest page cache, not device/host caches. No cache dropping. This isolated read workload does not model allocation interference.")
	repeat(ctx, cfg, s, func(warmup bool) error {
		c := command(ctx, cfg.Duration+cfg.IORamp+30*time.Second, "", nil,
			"fio", "--name=randread", "--filename="+file, "--allow_file_create=0", "--readonly",
			"--rw=randread", "--bs=4k", "--iodepth=1", "--numjobs=1", "--ioengine=psync", "--direct=1",
			"--size="+strconv.Itoa(cfg.IOSizeMiB)+"m", "--time_based=1",
			"--runtime="+strconv.FormatInt(int64(math.Ceil(cfg.Duration.Seconds())), 10),
			"--ramp_time="+strconv.FormatInt(int64(math.Ceil(cfg.IORamp.Seconds())), 10),
			"--randseed=42", "--lat_percentiles=1", "--percentile_list=50:99:99.9", "--output-format=json")
		if err := record(s, c, warmup); err != nil {
			return err
		}
		values, err := parseFIO(c.Output)
		if err == nil && !warmup {
			addMetrics(s, values)
		}
		return err
	})
}

var offlineGoEnv = []string{
	"GOTOOLCHAIN=local", "GOPROXY=off", "GOSUMDB=off", "GOWORK=off", "GOTELEMETRY=off",
	"GOENV=off", "GOFLAGS=", "GO111MODULE=on", "CGO_ENABLED=0", "GOCACHEPROG=",
	"GOOS=" + runtime.GOOS, "GOARCH=" + runtime.GOARCH,
}

func moduleHash(dir string) (string, error) {
	mod, err := os.ReadFile(filepath.Join(dir, "go.mod"))
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(string(mod)) != "module github.com/haider-IQZ/gilgamesh/bench\n\ngo 1.26.0" {
		return "", fmt.Errorf("--module-dir must contain this bench module's unmodified go.mod")
	}
	paths, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil || len(paths) == 0 {
		return "", fmt.Errorf("no Go sources in module directory")
	}
	h := sha256.New()
	_, _ = h.Write(mod)
	for _, p := range paths {
		if strings.HasSuffix(p, "_test.go") {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return "", err
		}
		_, _ = fmt.Fprintf(h, "\x00%s\x00", filepath.Base(p))
		_, _ = h.Write(b)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func compileSuite(ctx context.Context, cfg Config, s *Suite) {
	s.Method = "go-build-cold-cache"
	if _, err := exec.LookPath("go"); err != nil {
		skipped(s, "go is not installed")
		return
	}
	hash, err := moduleHash(cfg.ModuleDir)
	if err != nil {
		failed(s, err)
		return
	}
	c := command(ctx, 10*time.Second, cfg.ModuleDir, offlineGoEnv, "go", "version")
	if err := record(s, c, true); err != nil {
		failed(s, err)
		return
	}
	s.Workload = "source=" + hash + " toolchain=" + strings.TrimSpace(c.Output) + " cgo=0 -trimpath -buildvcs=false"
	s.Notes = append(s.Notes, "Each build uses its own empty GOCACHE including standard-library compilation. Filesystem caches remain warm; no global cache is cleared. Network/toolchain downloads are disabled.")
	repeat(ctx, cfg, s, func(warmup bool) error {
		dir, err := os.MkdirTemp("results", ".build-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		dir, err = filepath.Abs(dir)
		if err != nil {
			return err
		}
		env := append(slices.Clone(offlineGoEnv), "GOCACHE="+filepath.Join(dir, "cache"), "GOTMPDIR="+dir)
		c := command(ctx, 15*time.Minute, cfg.ModuleDir, env, "go", "build", "-trimpath", "-buildvcs=false", "-o", filepath.Join(dir, "bench"), ".")
		if err := record(s, c, warmup); err != nil {
			return err
		}
		if !warmup {
			s.add("elapsed_s", "s", c.Elapsed)
		}
		return nil
	})
	if after, err := moduleHash(cfg.ModuleDir); err != nil || after != hash {
		failed(s, fmt.Errorf("module source changed during measurement"))
	}
}
