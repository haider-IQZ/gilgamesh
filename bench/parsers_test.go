package main

import (
	"math"
	"testing"
)

func TestBootParsers(t *testing.T) {
	values, err := parseBootTime("Startup finished in 2.100s (firmware) + 10ms (loader) + 1.200s (kernel) + 500ms (initrd) + 1min 2.300s (userspace) = 1min 6.110s\ngraphical.target reached after 2.2s in userspace.")
	if err != nil || math.Abs(values["total_s"]-66.11) > 1e-9 || values["userspace_s"] != 62.3 {
		t.Fatalf("%v: %v", values, err)
	}
	v, err := parseBootTime("Startup finished in 1s (kernel) + 2s (userspace) = 3s")
	if err != nil || v["total_s"] != 3 || len(v) != 3 {
		t.Fatalf("minimal boot: %v %v", v, err)
	}
	values, err = parseBlame(" 1min 2.5s example.service\n  125ms other.service\n  25us tiny.service\n")
	if err != nil || values["example.service"] != 62.5 || values["other.service"] != .125 || values["tiny.service"] != .000025 {
		t.Fatalf("%v: %v", values, err)
	}
	values, err = parseChain("The time when unit became active or started is printed after the \"@\" character.\ngraphical.target @3.250s\n└─example.service @1min 2s +1.5s\n  └─other.target @1.200s\n")
	if err != nil || values["example.service.at_s"] != 62 || values["example.service.duration_s"] != 1.5 || values["graphical.target.at_s"] != 3.25 {
		t.Fatalf("%v: %v", values, err)
	}
	for _, parse := range []func(string) (map[string]float64, error){parseBootTime, parseBlame, parseChain} {
		if _, err := parse("not timings"); err == nil {
			t.Fatal("accepted unrecognized output")
		}
	}
}

func TestElapsed(t *testing.T) {
	for _, s := range []string{"Time: 1.234\n", "# Running 'sched/messaging' benchmark:\n Total time: 1.234 [sec]\n"} {
		v, err := parseElapsed(s)
		if err != nil || v != 1.234 {
			t.Fatalf("%g %v", v, err)
		}
	}
	if _, err := parseElapsed("benchmark failed"); err == nil {
		t.Fatal("accepted absent timing")
	}
}

func TestCyclic(t *testing.T) {
	data := `{"thread":{"0":{"histogram":{"1":500,"2":490,"50":10},"cycles":1000,"min":1,"max":50,"avg":1.98}}}`
	v, err := parseCyclic(data)
	if err != nil || v["p50_us"] != 1 || v["p99_us"] != 2 || v["p999_us"] != 50 || v["overflow"] != 0 {
		t.Fatalf("%v: %v", v, err)
	}
	for _, s := range []string{
		`{}`, `{"thread":{"0":{"cycles":100}}}`,
		`{"thread":{"0":{"cycles":1000,"histogram":{"1":990}}}}`,
		`{"thread":{"0":{"cycles":1,"histogram":{"1":2}}}}`,
		`{"thread":{"0":{"cycles":1,"histogram":{"NaN":1}}}}`,
	} {
		if _, err := parseCyclic(s); err == nil {
			t.Fatalf("accepted incomplete histogram: %s", s)
		}
	}
	v, err = parseCyclic(`{"thread":{"0":{"cycles":10000,"histogram":{"2":9999}}}}`)
	if err != nil || v["overflow"] != 1 || v["p999_us"] != 2 {
		t.Fatalf("small overflow should be recorded: %v %v", v, err)
	}
}

func TestFIO(t *testing.T) {
	v, err := parseFIO(`{"jobs":[{"error":0,"read":{"io_bytes":409600,"iops":200,"lat_ns":{"mean":2000,"percentile":{"50.000000":1000,"99.000000":9000,"99.900000":15000}}}}]}`)
	if err != nil || v["p99_us"] != 9 || v["p999_us"] != 15 || v["mean_us"] != 2 || v["iops"] != 200 {
		t.Fatalf("%v: %v", v, err)
	}
	for _, s := range []string{`{}`, `{"jobs":[{"error":1}]}`, `{"jobs":[{"read":{"io_bytes":4096,"clat_ns":{"mean":2}}}]}`} {
		if _, err := parseFIO(s); err == nil {
			t.Fatalf("accepted invalid or missing total latency: %s", s)
		}
	}
}

func TestProcParsers(t *testing.T) {
	id, err := parseProcStat("123 (command ) with spaces) S 1 123 456 0 -1 0")
	if err != nil || id != 456 {
		t.Fatalf("%d %v", id, err)
	}
	if _, err := parseProcStat("123 no parentheses"); err == nil {
		t.Fatal("accepted malformed proc stat")
	}
	if v, ok := parseKB("Name:\tfixture\nVmRSS:\t42 kB\n", "VmRSS"); !ok || v != 43008 {
		t.Fatalf("%g %t", v, ok)
	}
	if _, ok := parseKB("VmRSS: unknown kB", "VmRSS"); ok {
		t.Fatal("accepted malformed RSS")
	}
	v, err := parseZram("4096 1024 8192 0 8192 0 0 0 0")
	if err != nil || v["original_bytes"] != 4096 || v["compressed_bytes"] != 1024 || v["used_bytes"] != 8192 {
		t.Fatalf("%v %v", v, err)
	}
	for _, s := range []string{"1 2", "1 -2 3", "1 text 3"} {
		if _, err := parseZram(s); err == nil {
			t.Fatal("accepted invalid zram data")
		}
	}
}
