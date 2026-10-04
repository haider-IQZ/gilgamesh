package main

import "time"

type Config struct {
	Label       string        `json:"label"`
	Block       string        `json:"block,omitempty"`
	Suites      string        `json:"suites"`
	Repeats     int           `json:"repeats"`
	Warmups     int           `json:"warmups"`
	Settle      time.Duration `json:"settle_ns"`
	Cooldown    time.Duration `json:"cooldown_ns"`
	Duration    time.Duration `json:"duration_ns"`
	Interval    time.Duration `json:"interval_ns"`
	CPU         int           `json:"cpu"`
	IODir       string        `json:"io_dir,omitempty"`
	IOSizeMiB   int           `json:"io_size_mib"`
	IORamp      time.Duration `json:"io_ramp_ns"`
	ModuleDir   string        `json:"module_dir"`
	MemoryScope string        `json:"memory_scope"`
}

type Metric struct {
	Unit    string    `json:"unit"`
	Samples []float64 `json:"samples"`
	Summary Summary   `json:"summary"`
}

type Command struct {
	Args      []string `json:"args"`
	Elapsed   float64  `json:"elapsed_s"`
	Output    string   `json:"output"`
	Error     string   `json:"error,omitempty"`
	ExitCode  int      `json:"exit_code"`
	Warmup    bool     `json:"warmup"`
	Truncated bool     `json:"truncated,omitempty"`
}

type Suite struct {
	Status   string            `json:"status"`
	Reason   string            `json:"reason,omitempty"`
	Method   string            `json:"method"`
	Workload string            `json:"workload"`
	Notes    []string          `json:"notes,omitempty"`
	Metrics  map[string]Metric `json:"metrics"`
	Commands []Command         `json:"commands,omitempty"`
}

func (s *Suite) add(name, unit string, value float64) {
	m := s.Metrics[name]
	m.Unit = unit
	m.Samples = append(m.Samples, value)
	m.Summary = summarize(m.Samples)
	s.Metrics[name] = m
}

type Result struct {
	Version int               `json:"schema_version"`
	Started time.Time         `json:"started"`
	Config  Config            `json:"config"`
	System  map[string]string `json:"system"`
	Suites  map[string]*Suite `json:"suites"`
}
