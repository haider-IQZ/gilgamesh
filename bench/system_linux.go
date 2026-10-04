package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

var tunedSysctls = []string{
	"vm.swappiness", "vm.page-cluster", "vm.watermark_boost_factor",
	"vm.watermark_scale_factor", "vm.vfs_cache_pressure", "vm.dirty_bytes",
	"vm.dirty_background_bytes", "vm.dirty_writeback_centisecs",
	"kernel.nmi_watchdog", "kernel.printk",
}

func readText(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return "unavailable: " + err.Error()
	}
	return strings.TrimSpace(string(b))
}

func systemInfo() map[string]string {
	info := map[string]string{"go": runtime.Version(), "arch": runtime.GOARCH}
	info["num_cpu"] = strconv.Itoa(runtime.NumCPU())
	info["gomaxprocs"] = strconv.Itoa(runtime.GOMAXPROCS(0))
	for _, key := range []string{"GOMAXPROCS", "GOGC", "GOMEMLIMIT", "GOEXPERIMENT", "GOAMD64", "GOARM64", "GOARM", "GO386"} {
		info["env."+key] = os.Getenv(key)
	}
	paths := map[string]string{
		"kernel": "/proc/sys/kernel/osrelease", "cmdline": "/proc/cmdline",
		"boot_id": "/proc/sys/kernel/random/boot_id", "uptime": "/proc/uptime",
		"thp":        "/sys/kernel/mm/transparent_hugepage/enabled",
		"thp_defrag": "/sys/kernel/mm/transparent_hugepage/defrag",
		"mglru":      "/sys/kernel/mm/lru_gen/enabled", "mglru_min_ttl_ms": "/sys/kernel/mm/lru_gen/min_ttl_ms",
		"bore": "/proc/sys/kernel/sched_bore", "sched_ext": "/sys/kernel/sched_ext/state",
		"sched_ext_ops": "/sys/kernel/sched_ext/root/ops",
		"cpuidle":       "/sys/devices/system/cpu/cpuidle/current_driver",
		"clocksource":   "/sys/devices/system/clocksource/clocksource0/current_clocksource",
		"zswap":         "/sys/module/zswap/parameters/enabled", "swaps": "/proc/swaps",
		"memory": "/proc/meminfo", "pressure_cpu": "/proc/pressure/cpu",
		"pressure_memory": "/proc/pressure/memory", "pressure_io": "/proc/pressure/io",
		"nohz_full":          "/sys/devices/system/cpu/nohz_full",
		"halt_poll_ns":       "/sys/module/kvm/parameters/halt_poll_ns",
		"guest_halt_poll_ns": "/sys/module/haltpoll/parameters/guest_halt_poll_ns",
		"avic":               "/sys/module/kvm_amd/parameters/avic",
		"preempt":            "/sys/kernel/debug/sched/preempt",
		"audio_power_save":   "/sys/module/snd_hda_intel/parameters/power_save",
		"audio_msi":          "/sys/module/snd_hda_intel/parameters/enable_msi",
	}
	for k, p := range paths {
		info[k] = readText(p)
	}
	for _, key := range tunedSysctls {
		info["sysctl."+key] = readText("/proc/sys/" + strings.ReplaceAll(key, ".", "/"))
	}
	for _, line := range strings.Split(readText("/proc/cpuinfo"), "\n") {
		key, val, ok := strings.Cut(line, ":")
		if ok && strings.TrimSpace(key) == "model name" {
			info["cpu_model"] = strings.TrimSpace(val)
			break
		}
	}
	for _, pattern := range []string{
		"/sys/devices/system/cpu/cpufreq/policy*/scaling_governor",
		"/sys/block/*/queue/scheduler", "/sys/block/zram*/mm_stat",
		"/sys/block/zram*/disksize", "/sys/block/zram*/comp_algorithm",
	} {
		paths, _ := filepath.Glob(pattern)
		if len(paths) == 0 {
			info[pattern] = "unavailable: no matching interfaces"
		}
		for _, p := range paths {
			info[p] = readText(p)
		}
	}
	info["scheduler"] = "unknown (kernel release alone does not identify the CPU scheduler)"
	if info["sched_ext"] == "enabled" {
		info["scheduler"] = "sched_ext: " + info["sched_ext_ops"]
	} else if info["bore"] == "1" {
		info["scheduler"] = "BORE enabled (kernel.sched_bore=1)"
	} else if info["bore"] == "0" {
		info["scheduler"] = "BORE disabled (kernel.sched_bore=0)"
	}
	if mask, err := affinity(); err == nil {
		info["allowed_cpus"] = fmt.Sprint(maskCPUs(mask))
	}
	return info
}

func affinity() ([]byte, error) {
	for size := 128; size <= 8192; size *= 2 {
		mask := make([]byte, size)
		_, _, errno := syscall.RawSyscall(syscall.SYS_SCHED_GETAFFINITY, 0, uintptr(size), uintptr(unsafe.Pointer(&mask[0])))
		if errno == 0 {
			return mask, nil
		}
		if errno != syscall.EINVAL {
			return nil, errno
		}
	}
	return nil, fmt.Errorf("CPU affinity mask exceeds supported size")
}

func setAffinity(mask []byte) error {
	_, _, errno := syscall.RawSyscall(syscall.SYS_SCHED_SETAFFINITY, 0, uintptr(len(mask)), uintptr(unsafe.Pointer(&mask[0])))
	if errno != 0 {
		return errno
	}
	return nil
}

func maskCPUs(mask []byte) []int {
	var cpus []int
	wordBytes := int(unsafe.Sizeof(uintptr(0)))
	for offset := 0; offset+wordBytes <= len(mask); offset += wordBytes {
		var word uint64
		if wordBytes == 8 {
			word = binary.NativeEndian.Uint64(mask[offset:])
		} else {
			word = uint64(binary.NativeEndian.Uint32(mask[offset:]))
		}
		for bit := 0; bit < wordBytes*8; bit++ {
			if word&(1<<bit) != 0 {
				cpus = append(cpus, offset*8+bit)
			}
		}
	}
	return cpus
}

func singleCPU(mask []byte, cpu int) []byte {
	result := make([]byte, len(mask))
	wordBytes := int(unsafe.Sizeof(uintptr(0)))
	offset := (cpu / (wordBytes * 8)) * wordBytes
	word := uint64(1) << (cpu % (wordBytes * 8))
	if wordBytes == 8 {
		binary.NativeEndian.PutUint64(result[offset:], word)
	} else {
		binary.NativeEndian.PutUint32(result[offset:], uint32(word))
	}
	return result
}
