package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/haider-IQZ/gilgamesh/tools/internal/disk"
	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/plan"
	"github.com/haider-IQZ/gilgamesh/tools/internal/ui"
)

func (i *Installer) Prepare(ctx context.Context) error {
	i.Init()
	if !i.FS.Exists(i.Src + "/system") {
		if i.Dry {
			return fmt.Errorf("--dry-run requires a local checkout; downloading would write temporary files")
		}
		if i.UID != 0 {
			return fmt.Errorf("run the installer as root from the Arch ISO")
		}
		i.Phase = "live"
		tmp, e := os.MkdirTemp(i.FS.Path("/tmp"), "gilgamesh.")
		if e != nil {
			return e
		}
		if i.FS.Root != "" && i.FS.Root != "/" {
			rel, e := filepath.Rel(i.FS.Root, tmp)
			if e != nil {
				return e
			}
			tmp = "/" + rel
		}
		i.Src = tmp
		archive := tmp + "/checkout.tar.gz"
		if e = i.x(ctx, "curl", "-fsSL", "https://github.com/haider-IQZ/gilgamesh/archive/refs/heads/main.tar.gz", "-o", archive); e != nil {
			return e
		}
		if e = i.x(ctx, "tar", "-xzf", archive, "-C", tmp, "--strip-components=1"); e != nil {
			return e
		}
		if e = i.FS.Remove(archive); e != nil {
			return e
		}
	}
	for _, p := range []string{"installer/packages", "installer/packages-nvidia", "system", "hypr/hyprland.lua", "quickshell", "fish/colors.fish", "fish/prompt.fish", "fish/greeting.fish", "fish/starship.toml", "etc/sudoers.d/gilgamesh-dns"} {
		if !i.FS.Exists(i.Src + "/" + p) {
			return fmt.Errorf("missing %s in local checkout %s", p, i.Src)
		}
	}
	i.Bootstrap = i.FS.Exists(bootstrapDB)
	if !i.Bootstrap && !i.FS.Exists(i.DNSBinary) {
		return fmt.Errorf("missing Go DNS binary %s; build both tools first", i.DNSBinary)
	}
	var e error
	b, e := i.FS.Read(i.Src + "/installer/packages")
	if e != nil {
		return e
	}
	i.Base, e = plan.ReadList(string(b))
	if e != nil {
		return e
	}
	b, e = i.FS.Read(i.Src + "/installer/packages-nvidia")
	if e != nil {
		return e
	}
	i.NVIDIAPackages, e = plan.ReadList(string(b))
	if e != nil {
		return e
	}
	if i.Bootstrap {
		i.Kernel = "linux-tkg"
		i.Base = append(i.Base, "gilgamesh-settings", "gilgamesh-shell")
		for n, pkg := range i.NVIDIAPackages {
			if pkg == "nvidia-open-dkms" {
				i.NVIDIAPackages[n] = "nvidia-open-tkg"
			}
		}
	}
	// Every layout xkeyboard-config ships, paired with systemd's console keymaps;
	// the built-in list only covers a live system without X keyboard rules.
	i.Keyboards = plan.Keyboards
	if rules, e := i.FS.Read(plan.XKBRules); e == nil {
		keymaps, _ := i.FS.Read(plan.KbdModelMap)
		if parsed := plan.ParseKeyboards(string(rules), string(keymaps)); len(parsed) > 0 {
			i.Keyboards = parsed
		}
	}
	if !i.Dry {
		if i.UID != 0 {
			return fmt.Errorf("run the installer as root from the Arch ISO")
		}
		if !i.FS.Exists("/sys/firmware/efi") {
			return fmt.Errorf("Gilgamesh needs UEFI; boot the ISO in UEFI mode")
		}
		if e = i.x(ctx, "curl", "-fsS", "--max-time", "10", "-o", "/dev/null", "https://archlinux.org/"); e != nil {
			return fmt.Errorf("no internet connection: %w", e)
		}
		i.detectedTimezone = i.DetectTimezone(ctx)
		i.Phase = "live"
		if e = i.modify("/etc/pacman.conf", plan.Multilib); e != nil {
			return e
		}
		if e = i.UI.Spin(ctx, "Preparing the live system...", func(ctx context.Context) error {
			return i.x(ctx, "pacman", "-Sy", "--noconfirm", "--needed", "archlinux-keyring")
		}); e != nil {
			return e
		}
	}
	i.PCI, e = i.read(ctx, "lspci", "-nn")
	if e != nil {
		return e
	}
	b, e = i.FS.Read("/proc/cpuinfo")
	if e != nil {
		return e
	}
	i.CPU = string(b)
	return nil
}
func (i *Installer) LiveNameInUse(ctx context.Context, name string) (bool, error) {
	for _, db := range []string{"passwd", "group"} {
		_, e := i.read(ctx, "getent", db, name)
		if e == nil {
			return true, nil
		}
		if run.Code(e) != 2 {
			return false, fmt.Errorf("cannot check live %s names: %w", db, e)
		}
	}
	return false, nil
}

// AskUsername is Omarchy's username prompt with the live-system check kept.
func (i *Installer) AskUsername(ctx context.Context) (string, error) {
	for {
		name, e := i.UI.Input(ctx, "Username> ", "Alphanumeric without spaces (like enkidu)", false)
		if e != nil {
			return "", e
		}
		if e = plan.Username(name); e != nil {
			if strings.Contains(e.Error(), "reserved") {
				e = errors.New("Username is reserved for system")
			}
			if e = i.UI.Notice(ctx, e.Error()); e != nil {
				return "", e
			}
			continue
		}
		used, e := i.LiveNameInUse(ctx, name)
		if e != nil {
			return "", e
		}
		if used {
			if e = i.UI.Notice(ctx, "That username already exists on this machine"); e != nil {
				return "", e
			}
			continue
		}
		return name, nil
	}
}
func (i *Installer) askPassword(ctx context.Context) (string, error) {
	for {
		first, e := i.UI.Input(ctx, "Password> ", "Used for your user and sudo; root stays locked", true)
		if e != nil {
			return "", e
		}
		second, e := i.UI.Input(ctx, "Confirm> ", "Must match the password you just typed", true)
		if e != nil {
			return "", e
		}
		switch {
		case first == "":
			e = i.UI.Notice(ctx, "Your password can't be blank!")
		case plan.Password(first) != nil:
			e = i.UI.Notice(ctx, plan.Password(first).Error())
		case first != second:
			e = i.UI.Notice(ctx, "Passwords didn't match!")
		default:
			return first, nil
		}
		if e != nil {
			return "", e
		}
	}
}
func (i *Installer) askHostname(ctx context.Context) (string, error) {
	for {
		name, e := i.UI.Input(ctx, "Hostname> ", "Letters, digits, and dashes (or return for 'gilgamesh')", false)
		if e != nil {
			return "", e
		}
		if name == "" {
			return "gilgamesh", nil
		}
		name = strings.ToLower(name)
		if e = plan.Hostname(name); e != nil {
			if e = i.UI.Notice(ctx, e.Error()); e != nil {
				return "", e
			}
			continue
		}
		return name, nil
	}
}
func (i *Installer) Timezones(ctx context.Context) ([]string, error) {
	s, e := i.read(ctx, "timedatectl", "list-timezones")
	if e != nil {
		b, err := i.FS.Read("/usr/share/zoneinfo/tzdata.zi")
		if err != nil {
			return nil, err
		}
		var zones []string
		for _, l := range strings.Split(string(b), "\n") {
			v := strings.Fields(l)
			if len(v) >= 2 && v[0] == "Z" {
				zones = append(zones, v[1])
			} else if len(v) >= 3 && v[0] == "L" {
				zones = append(zones, v[2])
			}
		}
		sort.Strings(zones)
		s = strings.Join(zones, "\n")
	}
	if s == "" {
		return nil, fmt.Errorf("timezone list is empty")
	}
	return strings.Split(s, "\n"), nil
}

// askTimezone offers a detected zone first in a plain list; without a guess the
// list is filterable, as in Omarchy's setup form.
func (i *Installer) askTimezone(ctx context.Context, guess string) (string, error) {
	zones, e := i.Timezones(ctx)
	if e != nil {
		return "", e
	}
	var zone string
	if slices.Contains(zones, guess) {
		ordered := append([]string{guess}, slices.DeleteFunc(slices.Clone(zones), func(z string) bool { return z == guess })...)
		zone, e = i.UI.Choose(ctx, "Timezone", ordered, guess)
	} else {
		zone, e = i.UI.Filter(ctx, "Timezone", zones)
	}
	if e != nil {
		return "", e
	}
	if !slices.Contains(zones, zone) {
		return "", fmt.Errorf("invalid timezone selection")
	}
	return zone, nil
}
func diskLabel(n disk.Node) string {
	label := strings.TrimSpace(fmt.Sprintf("%s  %.1f GB  %s", n.Name, float64(n.Size)/1e9, n.Model))
	if n.Serial != "" {
		label += "  Serial: " + n.Serial
	}
	if n.WWN != "" {
		label += "  WWN: " + n.WWN
	}
	return label
}
func (i *Installer) AskDisk(ctx context.Context, value string) (string, disk.Identity, error) {
	for {
		inv, e := disk.Read(ctx, i.Runner)
		if e != nil {
			return "", disk.Identity{}, e
		}
		protected, e := i.Live.Detect(ctx, inv, !i.Dry || i.FS.Exists("/run/archiso"))
		if e != nil {
			return "", disk.Identity{}, e
		}
		if e = i.targetClear(ctx); e != nil {
			return "", disk.Identity{}, e
		}
		var choices []string
		labels := map[string]string{}
		selected := ""
		for _, n := range inv {
			if n.Type != "disk" || n.ReadOnly || protected[n.Name] || strings.HasPrefix(n.Name, "/dev/zram") {
				continue
			}
			label := diskLabel(n)
			if n.Name == value {
				selected = label
			}
			if _, ok := labels[label]; !ok {
				choices = append(choices, label)
				labels[label] = n.Name
			}
		}
		if len(choices) == 0 {
			return "", disk.Identity{}, fmt.Errorf("no disk found to install on")
		}
		i.UI.Screen("Let's select where to install Gilgamesh...", "")
		choice, e := i.UI.Choose(ctx, "Select install disk", choices, selected)
		if errors.Is(e, ui.ErrBack) {
			e = ui.ErrAborted // Nothing precedes the disk step to go back to.
		}
		if e != nil {
			return "", disk.Identity{}, e
		}
		name, ok := labels[choice]
		if !ok {
			return "", disk.Identity{}, fmt.Errorf("invalid disk selection")
		}
		validated, _, id, e := i.Validate(ctx, name)
		if e != nil {
			if e = i.UI.Notice(ctx, e.Error()); e != nil {
				return "", disk.Identity{}, e
			}
			continue
		}
		n, _ := validated.Get(name)
		i.diskLabel = diskLabel(n)
		return name, id, nil
	}
}

// keyboardForm is the first screen; Esc has nothing to go back to and asks again.
func (i *Installer) keyboardForm(ctx context.Context, a *plan.Answers) error {
	labels := make([]string, len(i.Keyboards))
	for n, k := range i.Keyboards {
		labels[n] = k.Label
	}
	for {
		i.UI.Screen("Let's setup your machine...", "")
		choice, e := i.UI.Choose(ctx, "Select keyboard layout", labels, a.Keyboard.Label)
		if errors.Is(e, ui.ErrBack) {
			continue
		}
		if e != nil {
			return e
		}
		n := slices.Index(labels, choice)
		if n < 0 {
			return fmt.Errorf("unknown keyboard layout")
		}
		a.Keyboard = i.Keyboards[n]
		// Only a Linux console loads keymaps; a failed one is re-asked before the
		// password is typed under it.
		if !i.Dry && i.Console {
			i.Phase = "live"
			if e = i.x(ctx, "loadkeys", a.Keyboard.Keymap); e != nil {
				if e = i.UI.Notice(ctx, "Could not apply keymap. Choose a working layout before entering your password."); e != nil {
					return e
				}
				continue
			}
		}
		return nil
	}
}

// userForm asks the account questions on one screen; Esc anywhere unwinds to
// the keyboard screen through ui.ErrBack.
func (i *Installer) userForm(ctx context.Context, a *plan.Answers) error {
	i.UI.Screen("Let's setup your user account...", "")
	var e error
	if a.Username, e = i.AskUsername(ctx); e != nil {
		return e
	}
	if a.Password, e = i.askPassword(ctx); e != nil {
		return e
	}
	if a.Hostname, e = i.askHostname(ctx); e != nil {
		return e
	}
	guess := a.Timezone // Editing the answers keeps the zone already chosen.
	if guess == "" {
		guess = i.detectedTimezone
	}
	a.Timezone, e = i.askTimezone(ctx, guess)
	return e
}
func (i *Installer) Questions(ctx context.Context) error {
	a := plan.Answers{Keyboard: i.Keyboards[0]}
	if e := i.keyboardForm(ctx, &a); e != nil {
		return e
	}
	for {
		e := i.userForm(ctx, &a)
		if errors.Is(e, ui.ErrBack) {
			if e = i.keyboardForm(ctx, &a); e != nil {
				return e
			}
			continue
		}
		if e != nil {
			return e
		}
		graphics := "no NVIDIA GPU found"
		switch supported, old := plan.Graphics(i.PCI); {
		case old:
			graphics = "Older NVIDIA: kernel nouveau; no NVIDIA packages (open drivers require Turing+)"
		case supported:
			graphics = "NVIDIA Turing+ (open drivers included)"
		}
		ok, e := i.UI.Summary(ctx, [][2]string{{"Username", a.Username}, {"Password", strings.Repeat("*", len(a.Password))}, {"Hostname", a.Hostname}, {"Timezone", a.Timezone}, {"Keyboard", a.Keyboard.Label}, {"Graphics", graphics}, {"Kernel", i.Kernel}})
		if e != nil {
			return e
		}
		if ok {
			break
		}
		if e = i.keyboardForm(ctx, &a); e != nil {
			return e
		}
	}
	for {
		var e error
		a.Disk, i.Confirmed, e = i.AskDisk(ctx, a.Disk)
		if e != nil {
			return e
		}
		i.Plan = plan.Build(a, i.Kernel, i.Base, i.NVIDIAPackages, i.PCI, i.CPU)
		// The disk is checked again right before the question that commits to it.
		_, _, id, e := i.Validate(ctx, a.Disk)
		if e != nil {
			return e
		}
		if e = disk.Verify(i.Confirmed, id); e != nil {
			return e
		}
		i.UI.Screen("Everything will be overwritten. There is no recovery possible.", "")
		ok, e := i.UI.Confirm(ctx, "Erase everything on "+i.diskLabel+"? This cannot be undone.", "Yes, install", "No, change it", false)
		if e != nil {
			return e
		}
		if ok {
			return nil
		}
	}
}
func (i *Installer) Full(ctx context.Context) error {
	if e := i.UI.Welcome(ctx); e != nil {
		return e
	}
	if e := i.Prepare(ctx); e != nil {
		return e
	}
	if e := i.Questions(ctx); e != nil {
		return e
	}
	i.Started = time.Now()
	if e := i.Run(ctx); e != nil {
		return e
	}
	if i.Dry {
		return nil
	}
	i.Current = "Reboot prompt"
	if e := i.UI.Drain(); e != nil {
		return e
	}
	yes, e := i.UI.Finished(ctx, ui.Duration(time.Since(i.Started)))
	if e != nil {
		return e
	}
	if yes {
		if e = i.x(ctx, "sync"); e != nil {
			return e
		}
		if e = i.Cleanup(); e != nil {
			return e
		}
		return i.x(context.Background(), "reboot")
	}
	return nil
}

// FindSource prefers the executable's checkout, then the working directory.
func FindSource() string {
	exe, _ := os.Executable()
	wd, _ := os.Getwd()
	return findSource(exe, wd)
}
func findSource(exe, wd string) string {
	var roots []string
	if resolved, e := filepath.EvalSymlinks(exe); e == nil {
		roots = append(roots, filepath.Dir(resolved))
	}
	roots = append(roots, wd)
	for _, root := range roots {
		for _, rel := range []string{".", "..", "../.."} {
			p := filepath.Join(root, rel)
			if _, e := os.Stat(filepath.Join(p, "installer/packages")); e == nil {
				return p
			}
		}
	}
	return wd
}
