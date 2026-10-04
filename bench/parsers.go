package main

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

var durationPattern = regexp.MustCompile(`(?:[0-9]+(?:\.[0-9]+)?\s*(?:min|ms|us|µs|μs|s|h)\s*)+`)

func seconds(s string) (float64, error) {
	s = strings.ReplaceAll(strings.TrimSpace(s), "min", "m")
	s = strings.ReplaceAll(s, " ", "")
	d, err := time.ParseDuration(s)
	if err != nil || d < 0 {
		return 0, fmt.Errorf("invalid duration %q", s)
	}
	return d.Seconds(), nil
}

func parseBootTime(s string) (map[string]float64, error) {
	result := map[string]float64{}
	re := regexp.MustCompile(`(` + durationPattern.String() + `)\((firmware|loader|kernel|initrd|userspace)\)`)
	for _, m := range re.FindAllStringSubmatch(s, -1) {
		v, err := seconds(m[1])
		if err != nil {
			return nil, err
		}
		result[m[2]+"_s"] = v
	}
	line, _, _ := strings.Cut(s, "\n")
	_, total, ok := strings.Cut(line, "=")
	if !ok || len(result) == 0 {
		return nil, fmt.Errorf("unrecognized systemd-analyze time output")
	}
	v, err := seconds(durationPattern.FindString(total))
	if err != nil {
		return nil, err
	}
	result["total_s"] = v
	return result, nil
}

func parseBlame(s string) (map[string]float64, error) {
	result := map[string]float64{}
	for _, line := range strings.Split(strings.TrimSpace(s), "\n") {
		line = strings.TrimSpace(line)
		loc := durationPattern.FindStringIndex(line)
		if loc == nil || loc[0] != 0 {
			continue
		}
		v, err := seconds(line[:loc[1]])
		unit := strings.TrimSpace(line[loc[1]:])
		if err != nil || unit == "" {
			return nil, fmt.Errorf("invalid blame line %q", line)
		}
		result[unit] = v
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("no blame timings available")
	}
	return result, nil
}

func parseChain(s string) (map[string]float64, error) {
	result := map[string]float64{}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimLeft(line, " \t│└─├")
		unit, rest, ok := strings.Cut(line, " @")
		if !ok || strings.ContainsAny(unit, " ()") || unit == "" {
			continue
		}
		at, took, hasDuration := strings.Cut(rest, " +")
		v, err := seconds(at)
		if err != nil {
			return nil, err
		}
		result[unit+".at_s"] = v
		if hasDuration {
			v, err = seconds(took)
			if err != nil {
				return nil, err
			}
			result[unit+".duration_s"] = v
		}
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("no critical-chain timings available")
	}
	return result, nil
}

func parseElapsed(s string) (float64, error) {
	re := regexp.MustCompile(`(?mi)(?:Time:\s*|Total time:\s*)([0-9]+(?:\.[0-9]+)?)`)
	m := re.FindStringSubmatch(s)
	if m == nil {
		return 0, fmt.Errorf("no tool-native elapsed time found")
	}
	return strconv.ParseFloat(m[1], 64)
}

func parseCyclic(s string) (map[string]float64, error) {
	var doc struct {
		Threads map[string]struct {
			Histogram map[string]uint64 `json:"histogram"`
			Cycles    uint64            `json:"cycles"`
			Min       float64           `json:"min"`
			Max       float64           `json:"max"`
			Avg       float64           `json:"avg"`
		} `json:"thread"`
	}
	if err := json.Unmarshal([]byte(s), &doc); err != nil {
		return nil, err
	}
	if len(doc.Threads) != 1 {
		return nil, fmt.Errorf("expected one cyclictest thread")
	}
	for _, t := range doc.Threads {
		bins := map[float64]uint64{}
		var count uint64
		for k, n := range t.Histogram {
			v, err := strconv.ParseFloat(k, 64)
			if err != nil || v < 0 || math.IsNaN(v) || math.IsInf(v, 0) {
				return nil, fmt.Errorf("invalid histogram bin %q", k)
			}
			bins[v] += n
			count += n
		}
		if count == 0 || t.Cycles < count {
			return nil, fmt.Errorf("missing or inconsistent cyclictest histogram")
		}
		result := map[string]float64{"min_us": t.Min, "mean_us": t.Avg, "max_us": t.Max, "cycles": float64(t.Cycles), "overflow": float64(t.Cycles - count)}
		keys := make([]float64, 0, len(bins))
		for v := range bins {
			keys = append(keys, v)
		}
		slices.Sort(keys)
		for name, p := range map[string]float64{"p50_us": .5, "p99_us": .99, "p999_us": .999} {
			target := uint64(math.Ceil(float64(t.Cycles) * p))
			if target > count {
				return result, fmt.Errorf("%s lies beyond histogram; increase histogram range", name)
			}
			var sum uint64
			for _, v := range keys {
				sum += bins[v]
				if sum >= target {
					result[name] = v
					break
				}
			}
		}
		return result, nil
	}
	return nil, fmt.Errorf("empty cyclictest result")
}

func parseFIO(s string) (map[string]float64, error) {
	var doc struct {
		Jobs []struct {
			Error int `json:"error"`
			Read  struct {
				IOPS    float64 `json:"iops"`
				Bytes   uint64  `json:"io_bytes"`
				Latency struct {
					Mean       float64            `json:"mean"`
					Percentile map[string]float64 `json:"percentile"`
				} `json:"lat_ns"`
			} `json:"read"`
		} `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(s), &doc); err != nil {
		return nil, err
	}
	if len(doc.Jobs) != 1 || doc.Jobs[0].Error != 0 || doc.Jobs[0].Read.Bytes == 0 {
		return nil, fmt.Errorf("fio did not complete one successful read job")
	}
	r := doc.Jobs[0].Read
	result := map[string]float64{"iops": r.IOPS, "mean_us": r.Latency.Mean / 1000}
	for _, p := range []float64{50, 99, 99.9} {
		found := false
		for k, v := range r.Latency.Percentile {
			n, err := strconv.ParseFloat(k, 64)
			if err == nil && n == p {
				result[fmt.Sprintf("p%s_us", strings.ReplaceAll(fmt.Sprint(p), ".", ""))] = v / 1000
				found = true
			}
		}
		if !found {
			return nil, fmt.Errorf("fio total latency percentile %g missing", p)
		}
	}
	return result, nil
}

func parseProcStat(s string) (int, error) {
	end := strings.LastIndex(s, ")")
	if end < 0 {
		return 0, fmt.Errorf("invalid proc stat")
	}
	f := strings.Fields(s[end+1:])
	if len(f) < 4 {
		return 0, fmt.Errorf("short proc stat")
	}
	return strconv.Atoi(f[3]) // Field 6 is the POSIX session ID.
}

func parseKB(s, key string) (float64, bool) {
	for _, line := range strings.Split(s, "\n") {
		f := strings.Fields(line)
		if len(f) == 3 && f[0] == key+":" && f[2] == "kB" {
			v, err := strconv.ParseFloat(f[1], 64)
			return v * 1024, err == nil && v >= 0
		}
	}
	return 0, false
}

func parseZram(s string) (map[string]float64, error) {
	f := strings.Fields(s)
	if len(f) < 3 {
		return nil, fmt.Errorf("short zram mm_stat")
	}
	result := map[string]float64{}
	for i, name := range []string{"original_bytes", "compressed_bytes", "used_bytes"} {
		v, err := strconv.ParseUint(f[i], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid zram mm_stat: %w", err)
		}
		result[name] = float64(v)
	}
	return result, nil
}
