package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

type arm struct {
	runs      []Result
	directory bool
}

func loadArm(path string) (arm, error) {
	var a arm
	fi, err := os.Stat(path)
	if err != nil {
		return a, err
	}
	paths := []string{path}
	a.directory = fi.IsDir()
	if a.directory {
		paths, err = filepath.Glob(filepath.Join(path, "*.json"))
		if err != nil || len(paths) == 0 {
			return a, fmt.Errorf("no result JSON files in %s", path)
		}
	}
	label := ""
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			return a, err
		}
		var r Result
		dec := json.NewDecoder(io.LimitReader(f, 64*1024*1024))
		err = dec.Decode(&r)
		var trailing any
		if err == nil && dec.Decode(&trailing) != io.EOF {
			err = fmt.Errorf("trailing JSON data")
		}
		_ = f.Close()
		if err != nil {
			return a, fmt.Errorf("%s: %w", p, err)
		}
		if r.Version != 1 || len(r.Suites) == 0 || r.Config.Label == "" {
			return a, fmt.Errorf("%s: unsupported or empty result", p)
		}
		if label != "" && r.Config.Label != label {
			return a, fmt.Errorf("each directory must contain only one condition label")
		}
		label = r.Config.Label
		for name, s := range r.Suites {
			if s == nil || (s.Status != "ok" && s.Status != "skipped" && s.Status != "failed") {
				return a, fmt.Errorf("%s: invalid suite %s", p, name)
			}
			for key, m := range s.Metrics {
				if len(m.Samples) == 0 || m.Unit == "" {
					return a, fmt.Errorf("%s: empty metric %s", p, key)
				}
				for _, v := range m.Samples {
					if v < 0 || math.IsNaN(v) || math.IsInf(v, 0) {
						return a, fmt.Errorf("%s: invalid sample %s", p, key)
					}
				}
			}
		}
		a.runs = append(a.runs, r)
	}
	return a, nil
}

type series struct {
	values                 []float64
	blocks                 []string
	unit, method, workload string
}

func collect(a arm, suiteName, metricName string, independent bool) (series, error) {
	var out series
	groups := map[string][]float64{}
	blocks := map[string]string{}
	for _, r := range a.runs {
		s, ok := r.Suites[suiteName]
		if !ok {
			return out, fmt.Errorf("suite missing in an input")
		}
		if s.Status != "ok" {
			return out, fmt.Errorf("suite %s: %s", s.Status, s.Reason)
		}
		m, ok := s.Metrics[metricName]
		if !ok {
			return out, fmt.Errorf("metric missing in an input")
		}
		if out.unit != "" && (out.unit != m.Unit || out.method != s.Method || out.workload != s.Workload) {
			return out, fmt.Errorf("mixed methods, units, or workload settings within an arm")
		}
		out.unit, out.method, out.workload = m.Unit, s.Method, s.Workload
		if !independent {
			out.values = append(out.values, m.Samples...)
			continue
		}
		boot := r.System["boot_id"]
		if boot == "" || strings.HasPrefix(boot, "unavailable:") {
			return out, fmt.Errorf("independent comparison requires recorded boot IDs")
		}
		if prev, ok := blocks[boot]; ok && prev != r.Config.Block {
			return out, fmt.Errorf("one boot was assigned multiple block IDs")
		}
		blocks[boot] = r.Config.Block
		groups[boot] = append(groups[boot], quantile(m.Samples, .5))
	}
	if independent {
		keys := sortedKeys(groups)
		for _, key := range keys {
			out.values = append(out.values, quantile(groups[key], .5))
			out.blocks = append(out.blocks, blocks[key])
		}
	}
	return out, nil
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func pairSeries(a, b series) ([]float64, []float64, error) {
	index := func(s series) (map[string]float64, error) {
		m := map[string]float64{}
		for i, block := range s.blocks {
			if _, ok := m[block]; ok || block == "" {
				return nil, fmt.Errorf("paired mode needs one independent boot per nonempty block ID in each arm")
			}
			m[block] = s.values[i]
		}
		return m, nil
	}
	x, err := index(a)
	if err != nil {
		return nil, nil, err
	}
	y, err := index(b)
	if err != nil {
		return nil, nil, err
	}
	if len(x) != len(y) {
		return nil, nil, fmt.Errorf("block IDs must match across arms")
	}
	var av, bv []float64
	for _, key := range sortedKeys(x) {
		v, ok := y[key]
		if !ok {
			return nil, nil, fmt.Errorf("block IDs must match across arms")
		}
		av, bv = append(av, x[key]), append(bv, v)
	}
	return av, bv, nil
}

func compareCLI(args []string) error {
	f := flag.NewFlagSet("compare", flag.ContinueOnError)
	paired := f.Bool("paired", false, "resample matched --block IDs across independent boots (directory inputs)")
	if err := f.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if f.NArg() != 2 {
		return fmt.Errorf("usage: compare [--paired] A.json B.json (or two directories)")
	}
	a, err := loadArm(f.Arg(0))
	if err != nil {
		return err
	}
	b, err := loadArm(f.Arg(1))
	if err != nil {
		return err
	}
	independent := a.directory || b.directory
	if a.directory != b.directory || (*paired && !independent) {
		return fmt.Errorf("use two files or two directories; paired mode requires directories")
	}
	if independent {
		boots := map[string]bool{}
		for _, r := range a.runs {
			boots[r.System["boot_id"]] = true
		}
		for _, r := range b.runs {
			if boots[r.System["boot_id"]] {
				return fmt.Errorf("arms share a boot ID; directory comparisons require separate boots per condition visit")
			}
		}
		fmt.Println("Experimental unit: median per boot; repeated invocations within a boot are collapsed.")
	} else {
		fmt.Println("Exploratory within-run comparison: samples share a boot/runtime. CI only describes repeat noise, not independent A/B evidence.")
	}
	fmt.Println("A and B: median ± sample stddev (n). Delta and percent are B − A; negative means lower. CI: deterministic 95% percentile bootstrap, 20,000 resamples.")
	if *paired {
		fmt.Println("Paired delta/CI: median of matched block differences; percent: median of per-block percentage changes.")
	}
	fmt.Println("Beyond noise means CI excludes zero; it is not a keep/revert verdict or a correction for multiple metrics. Fewer than 3 units: insufficient data.")
	keys := map[string]bool{}
	for _, r := range append(slices.Clone(a.runs), b.runs...) {
		for key := range r.Suites {
			keys[key] = true
		}
	}
	compared := 0
	for _, name := range sortedKeys(keys) {
		metrics := map[string]bool{}
		for _, r := range append(slices.Clone(a.runs), b.runs...) {
			if s := r.Suites[name]; s != nil {
				for key := range s.Metrics {
					metrics[key] = true
				}
				if s.Status != "ok" {
					fmt.Printf("%s [%s]: %s — %s\n", name, r.Config.Label, s.Status, s.Reason)
				}
			}
		}
		for _, metric := range sortedKeys(metrics) {
			x, xerr := collect(a, name, metric, independent)
			y, yerr := collect(b, name, metric, independent)
			if xerr != nil || yerr != nil {
				fmt.Printf("%s.%s: not comparable (A: %v; B: %v)\n", name, metric, xerr, yerr)
				continue
			}
			if x.unit != y.unit || x.method != y.method || x.workload != y.workload {
				fmt.Printf("%s.%s: not comparable (different methods, units, or workload settings)\n", name, metric)
				continue
			}
			if *paired {
				x.values, y.values, err = pairSeries(x, y)
				if err != nil {
					return err
				}
			}
			sx, sy := summarize(x.values), summarize(y.values)
			delta := sy.Median - sx.Median
			pct := "n/a (zero baseline)"
			if sx.Median != 0 {
				pct = fmt.Sprintf("%+.2f%%", 100*delta/sx.Median)
			}
			if *paired {
				d, p := make([]float64, len(x.values)), []float64{}
				for i, v := range x.values {
					d[i] = y.values[i] - v
					if v != 0 {
						p = append(p, 100*d[i]/v)
					}
				}
				delta = quantile(d, .5)
				pct = "n/a (zero baseline in a block)"
				if len(p) == len(d) {
					pct = fmt.Sprintf("%+.2f%%", quantile(p, .5))
				}
			}
			verdict := "insufficient data"
			if sx.N >= 3 && sy.N >= 3 && (independent || name != "boot") {
				lo, hi := bootstrap(x.values, y.values, *paired)
				noise := "no"
				if lo > 0 || hi < 0 {
					noise = "yes"
				}
				verdict = fmt.Sprintf("CI [%+.6g, %+.6g]; beyond noise: %s", lo, hi, noise)
			}
			fmt.Printf("%s.%s [%s]: A %.6g ± %.6g (n=%d); B %.6g ± %.6g (n=%d); delta %+.6g (%s); %s\n", name, metric, x.unit, sx.Median, sx.Stddev, sx.N, sy.Median, sy.Stddev, sy.N, delta, pct, verdict)
			compared++
		}
	}
	if compared == 0 {
		return fmt.Errorf("no comparable successful metrics")
	}
	return nil
}
