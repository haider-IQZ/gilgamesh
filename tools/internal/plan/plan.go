// Package plan contains deterministic install decisions, with no side effects.
package plan

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/haider-IQZ/gilgamesh/tools/internal/disk"
)

type Keyboard struct{ Label, Layout, Variant, Options, Keymap string }
type Answers struct {
	Keyboard                                     Keyboard
	Username, Password, Hostname, Timezone, Disk string
}
type Partition struct{ Device, Size, Type, Label string }
type Format struct {
	Program string
	Args    []string
}
type Plan struct {
	Partitions        []Partition
	PartitionArgs     []string
	Formats           []Format
	RootMountOptions  []string
	Answers           Answers
	ESP, Root         string
	Packages          []string
	NVIDIA, OldNVIDIA bool
	Kernel            string
}

func ReadList(s string) ([]string, error) {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		f := strings.Fields(strings.SplitN(l, "#", 2)[0])
		if len(f) > 0 {
			if !regexp.MustCompile(`^[a-zA-Z0-9@._+-]+$`).MatchString(f[0]) {
				return nil, fmt.Errorf("invalid package %q", f[0])
			}
			out = append(out, f[0])
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("package lists must not be empty")
	}
	return out, nil
}

var gpu = regexp.MustCompile(`\[10de:([0-9a-f]{4})\]`)

func Graphics(pci string) (supported, old bool) {
	for _, l := range strings.Split(strings.ToLower(pci), "\n") {
		if !strings.Contains(l, "[0300]") && !strings.Contains(l, "[0302]") {
			continue
		}
		m := gpu.FindStringSubmatch(l)
		if len(m) == 2 {
			n, _ := strconv.ParseUint(m[1], 16, 16)
			if n >= 0x1e00 {
				supported = true
			} else {
				old = true
			}
		}
	}
	return supported && !old, old
}
func Microcode(cpu string) string {
	for _, l := range strings.Split(cpu, "\n") {
		k, v, ok := strings.Cut(l, ":")
		if ok && strings.TrimSpace(k) == "vendor_id" {
			switch strings.TrimSpace(v) {
			case "AuthenticAMD":
				return "amd-ucode"
			case "GenuineIntel":
				return "intel-ucode"
			}
			return ""
		}
	}
	return ""
}
func Build(a Answers, kernel string, base, nvidia []string, pci, cpu string) Plan {
	p := Plan{Answers: a, ESP: disk.Part(a.Disk, 1), Root: disk.Part(a.Disk, 2), Kernel: kernel}
	p.Partitions = []Partition{{p.ESP, "1 GiB", "ef00", "EFI"}, {p.Root, "remaining", "8304", "gilgamesh"}}
	p.PartitionArgs = []string{"-o", "-n", "1:0:+1G", "-t", "1:ef00", "-c", "1:EFI", "-n", "2:0:0", "-t", "2:8304", "-c", "2:gilgamesh", a.Disk}
	p.Formats = []Format{{"mkfs.fat", []string{"-F32", "-n", "GIL_EFI", p.ESP}}, {"mkfs.xfs", []string{"-f", "-L", "gilgamesh", "-m", "rmapbt=0", "-n", "parent=0", p.Root}}}
	p.RootMountOptions = []string{"-o", "noatime"}
	p.NVIDIA, p.OldNVIDIA = Graphics(pci)
	p.Packages = append([]string{kernel, kernel + "-headers"}, base...)
	if m := Microcode(cpu); m != "" {
		p.Packages = append(p.Packages, m)
	}
	if p.NVIDIA {
		p.Packages = append(p.Packages, nvidia...)
	}
	return p
}

var username = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
var hostname = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

const reserved = "wheel audio video input disk storage optical render kvm adm log sys network power users root bin daemon mail ftp http nobody dbus uuidd polkitd rtkit git avahi colord alpm tss geoclue usbmux nvidia-persistenced"

func Username(s string) error {
	if !username.MatchString(s) {
		return fmt.Errorf("start with lowercase letter or _, then a-z 0-9 _ - (max 32)")
	}
	if strings.HasPrefix(s, "systemd-") || strings.Contains(" "+reserved+" ", " "+s+" ") {
		return fmt.Errorf("%q is a reserved account/group name", s)
	}
	return nil
}
func NameInUse(name string, databases ...string) bool {
	for _, db := range databases {
		for _, l := range strings.Split(db, "\n") {
			if strings.SplitN(l, ":", 2)[0] == name {
				return true
			}
		}
	}
	return false
}
func Hostname(s string) error {
	if !hostname.MatchString(s) {
		return fmt.Errorf("hostname: letters, digits and internal hyphens only (max 63)")
	}
	return nil
}
func Password(s string) error {
	if s == "" || strings.ContainsAny(s, "\n\r\x00") {
		return fmt.Errorf("password must be nonempty and contain no line breaks or NUL")
	}
	return nil
}
func FilterFstab(s, root, esp string) (string, error) {
	if root == "" || esp == "" || root == esp || strings.ContainsAny(root+esp, " \n\t") {
		return "", fmt.Errorf("invalid new filesystem UUIDs")
	}
	roots, esps := 0, 0
	var lines []string
	for _, l := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		f := strings.Fields(l)
		if len(f) == 0 || strings.HasPrefix(f[0], "#") {
			lines = append(lines, l)
			continue
		}
		if len(f) >= 3 && f[2] == "swap" {
			continue
		}
		if len(f) != 6 {
			return "", fmt.Errorf("refusing malformed fstab")
		}
		switch {
		case f[0] == "UUID="+root && f[1] == "/" && f[2] == "xfs":
			roots++
		case f[0] == "UUID="+esp && f[1] == "/boot/efi" && f[2] == "vfat":
			esps++
		default:
			return "", fmt.Errorf("refusing fstab: unrelated filesystem")
		}
		lines = append(lines, l)
	}
	if roots != 1 || esps != 1 {
		return "", fmt.Errorf("refusing fstab: expected exactly new root and ESP UUIDs")
	}
	return strings.Join(lines, "\n") + "\n", nil
}
func SetConf(s, key, value string) string {
	r := regexp.MustCompile(`^#?\s*` + regexp.QuoteMeta(key) + `=`)
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	found := false
	for i, l := range lines {
		if r.MatchString(l) {
			lines[i] = key + "=" + value
			found = true
		}
	}
	if !found {
		lines = append(lines, key+"="+value)
	}
	return strings.Join(lines, "\n") + "\n"
}
func Multilib(s string) string {
	lines := strings.Split(s, "\n")
	active := false
	for i, l := range lines {
		if l == "#[multilib]" {
			active = true
		}
		if active {
			lines[i] = strings.TrimPrefix(l, "#")
			if strings.HasPrefix(l, "#Include") {
				active = false
			}
		}
	}
	return strings.Join(lines, "\n")
}
func HyprLocal(k Keyboard) string {
	s := "-- Written by the Gilgamesh installer (your keyboard layout). Your own changes go here too.\nhl.config({\n    input = {\n        kb_layout = \"" + k.Layout + "\",\n"
	if k.Variant != "" {
		s += "        kb_variant = \"" + k.Variant + "\",\n"
	}
	if k.Options != "" {
		s += "        kb_options = \"" + k.Options + "\",\n"
	}
	return s + "    },\n})\n"
}
