package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func fixture(boot, block string, values ...float64) Result {
	return Result{Version: 1, Config: Config{Label: "fixture", Block: block}, System: map[string]string{"boot_id": boot}, Suites: map[string]*Suite{
		"sched": {Status: "ok", Method: "fixture", Workload: "fixed", Metrics: map[string]Metric{
			"p99_us": {Unit: "us", Samples: values},
		}},
	}}
}

func TestCollectCollapsesBoots(t *testing.T) {
	a := arm{directory: true, runs: []Result{fixture("one", "1", 1, 2, 3), fixture("one", "1", 5), fixture("two", "2", 9)}}
	s, err := collect(a, "sched", "p99_us", true)
	if err != nil || !reflect.DeepEqual(s.values, []float64{3.5, 9}) {
		t.Fatalf("%+v %v", s, err)
	}
	a.runs[1].Config.Block = "different"
	if _, err := collect(a, "sched", "p99_us", true); err == nil {
		t.Fatal("accepted reused boot across blocks")
	}
}

func TestCollectRejectsFailedAndMixed(t *testing.T) {
	for _, change := range []func(*Result){
		func(r *Result) { r.Suites["sched"].Status = "failed" },
		func(r *Result) { r.Suites["sched"].Method = "different" },
		func(r *Result) { r.Suites["sched"].Workload = "different" },
		func(r *Result) { delete(r.Suites["sched"].Metrics, "p99_us") },
		func(r *Result) { delete(r.System, "boot_id") },
	} {
		a := arm{runs: []Result{fixture("one", "1", 1), fixture("two", "2", 2)}}
		change(&a.runs[1])
		if _, err := collect(a, "sched", "p99_us", true); err == nil {
			t.Fatal("accepted incompatible sample")
		}
	}
}

func TestPairSeries(t *testing.T) {
	a := series{values: []float64{1, 2}, blocks: []string{"a", "b"}}
	b := series{values: []float64{20, 10}, blocks: []string{"b", "a"}}
	x, y, err := pairSeries(a, b)
	if err != nil || !reflect.DeepEqual(x, []float64{1, 2}) || !reflect.DeepEqual(y, []float64{10, 20}) {
		t.Fatalf("%v %v %v", x, y, err)
	}
	for _, blocks := range [][]string{{"a", "a"}, {"a", "c"}, {"a", ""}} {
		b.blocks = blocks
		if _, _, err := pairSeries(a, b); err == nil {
			t.Fatal("accepted invalid pairs")
		}
	}
}

func TestLoadArmValidation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.json")
	r := fixture("boot", "block", 1, 2, 3)
	b, _ := json.Marshal(r)
	if err := os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	if a, err := loadArm(dir); err != nil || len(a.runs) != 1 || !a.directory {
		t.Fatalf("%+v %v", a, err)
	}
	for _, bad := range []string{`{}`, string(b) + "{}", `{"schema_version":99}`, `{"schema_version":1,"config":{"label":"x"},"suites":{"sched":null}}`} {
		if err := os.WriteFile(path, []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadArm(path); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}

func TestComparePairedCLI(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "A"), filepath.Join(dir, "B")
	for _, name := range []string{a, b} {
		if err := os.Mkdir(name, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, block := range []string{"1", "2", "3"} {
		for i, arm := range []string{a, b} {
			r := fixture(filepath.Base(arm)+block, block, 10+float64(i), 10+float64(i), 10+float64(i))
			r.Config.Label = filepath.Base(arm)
			data, err := json.Marshal(r)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(arm, block+".json"), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	rd, wr, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = wr
	err = compareCLI([]string{"--paired", a, b})
	os.Stdout = stdout
	_ = wr.Close()
	output, readErr := io.ReadAll(rd)
	_ = rd.Close()
	if err != nil || readErr != nil || !strings.Contains(string(output), "delta +1 (+10.00%); CI [+1, +1]; beyond noise: yes") {
		t.Fatalf("paired CLI: %v %v\n%s", err, readErr, output)
	}
	if err := compareCLI([]string{a, a}); err == nil || !strings.Contains(err.Error(), "share a boot") {
		t.Fatalf("accepted same-boot independent arms: %v", err)
	}
}
