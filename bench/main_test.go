package main

import (
	"testing"
	"time"
)

func TestValidateConfig(t *testing.T) {
	valid := Config{Label: "baseline-1", Suites: "memory,sched", Repeats: 5, Warmups: 1,
		Duration: time.Second, Interval: time.Millisecond, CPU: -1, IOSizeMiB: 256, MemoryScope: "session"}
	if err := validateConfig(valid); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*Config){
		func(c *Config) { c.Label = "../escape" },
		func(c *Config) { c.Suites = "memory,memory" },
		func(c *Config) { c.Suites = "unknown" },
		func(c *Config) { c.Repeats = 0 },
		func(c *Config) { c.Warmups = -1 },
		func(c *Config) { c.Cooldown = -time.Second },
		func(c *Config) { c.Duration = 1500 * time.Millisecond },
		func(c *Config) { c.Interval = time.Nanosecond },
		func(c *Config) { c.MemoryScope = "all" },
	} {
		cfg := valid
		change(&cfg)
		if err := validateConfig(cfg); err == nil {
			t.Fatalf("accepted invalid config: %+v", cfg)
		}
	}
}
