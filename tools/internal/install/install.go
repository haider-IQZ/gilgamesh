// Package install orchestrates the real flow against injectable command and
// filesystem boundaries. Tests execute these methods, not copies of the flow.
package install

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/haider-IQZ/gilgamesh/tools/internal/disk"
	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/fsys"
	"github.com/haider-IQZ/gilgamesh/tools/internal/live"
	"github.com/haider-IQZ/gilgamesh/tools/internal/plan"
)

const LogPath = "/tmp/gilgamesh-install.log"

// UI is the configurator's vocabulary: Omarchy's screens, each one gum command.
type UI interface {
	Welcome(context.Context) error                                    // greeter: logo, tagline, Return to start
	Screen(title, hint string)                                        // step(): logo and a title the next prompts sit under
	Choose(context.Context, string, []string, string) (string, error) // gum choose --header --selected
	Filter(context.Context, string, []string) (string, error)         // gum filter --header
	Input(ctx context.Context, prompt, placeholder string, secret bool) (string, error)
	Confirm(ctx context.Context, prompt, affirmative, negative string, yes bool) (bool, error)
	Summary(context.Context, [][2]string) (bool, error)              // gum table, then "Does this look right?"
	Notice(context.Context, string) error                            // a one-second spinner with a validation message
	Spin(context.Context, string, func(context.Context) error) error // gum spin around a command
	Drain() error
	Begin([]string) // the install steps, for the progress view
	Step(context.Context, string, func(context.Context) error) error
	Finished(ctx context.Context, duration string) (bool, error) // "Installed Gilgamesh in ..." and Reboot Now
}
type Mount struct{ Target, Source, ID string }
type Installer struct {
	Runner                         run.Runner
	FS                             fsys.FS
	UI                             UI
	Src, Target, Kernel, DNSBinary string
	Dry                            bool
	Bootstrap                      bool
	UID                            int
	Console                        bool
	Out                            io.Writer
	Log                            io.Writer
	Phase, Current                 string
	Plan                           plan.Plan
	Confirmed                      disk.Identity
	diskLabel                      string
	Live                           live.Detector
	Mounts                         []Mount
	Base, NVIDIAPackages           []string
	PCI, CPU                       string
	RootUUID, ESPUUID              string
	Sleep                          func(context.Context, time.Duration) error
	BeforeCleanup                  func()
	HTTPClient                     HTTPClient
	Keyboards                      []plan.Keyboard
	Started                        time.Time
	detectedTimezone               string
	logFile                        *os.File
}

func (i *Installer) Init() {
	if i.Target == "" {
		i.Target = "/mnt"
	}
	if i.Kernel == "" {
		i.Kernel = "linux"
	}
	if i.Phase == "" {
		i.Phase = "untouched"
	}
	if i.Current == "" {
		i.Current = "questions"
	}
	if i.Out == nil {
		i.Out = io.Discard
	}
	i.FS.Dry = i.Dry
	i.FS.Preview = func(s string) { fmt.Fprintln(i.Out, s) }
	i.Live.Runner = i.Runner
	i.Live.FS = i.FS
	if i.Sleep == nil {
		i.Sleep = func(ctx context.Context, d time.Duration) error {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(d):
				return nil
			}
		}
	}
}
func (i *Installer) read(ctx context.Context, n string, args ...string) (string, error) {
	s, e := i.Runner.Run(ctx, run.C(n, args...))
	return strings.TrimSpace(s), e
}
func (i *Installer) x(ctx context.Context, n string, args ...string) error {
	if e := ctx.Err(); e != nil {
		return e
	}
	c := run.C(n, args...)
	if i.Dry {
		fmt.Fprintln(i.Out, run.Show(c))
		return nil
	}
	_, e := i.Runner.Run(ctx, c)
	return e
}
func (i *Installer) chroot(ctx context.Context, n string, args ...string) error {
	return i.x(ctx, "arch-chroot", append([]string{i.Target, n}, args...)...)
}
func (i *Installer) write(p, s string, mode os.FileMode) error {
	if i.Log != nil {
		fmt.Fprintln(i.Log, "$ write "+p)
	}
	return i.FS.Write(p, []byte(s), mode)
}
func (i *Installer) modify(p string, fn func(string) string) error {
	if i.Dry {
		return i.write(p, "(transform existing configuration)\n", 0644)
	}
	b, e := i.FS.Read(p)
	if e != nil {
		return e
	}
	return i.write(p, fn(string(b)), 0644)
}
func (i *Installer) set(p, k, v string) error {
	if i.Dry {
		return i.write(p, k+"="+v+"\n", 0644)
	}
	return i.modify(p, func(s string) string { return plan.SetConf(s, k, v) })
}
func (i *Installer) targetClear(ctx context.Context) error {
	s, e := i.read(ctx, "findmnt", "-rn", "-o", "TARGET")
	if e != nil {
		return e
	}
	return disk.TargetClear(i.Target, strings.Split(s, "\n"))
}
func (i *Installer) Validate(ctx context.Context, name string) (disk.Inventory, []string, disk.Identity, error) {
	inv, e := disk.Read(ctx, i.Runner)
	if e != nil {
		return nil, nil, disk.Identity{}, e
	}
	protected, e := i.Live.Detect(ctx, inv, !i.Dry || i.FS.Exists("/run/archiso"))
	if e != nil {
		return nil, nil, disk.Identity{}, e
	}
	if e = i.targetClear(ctx); e != nil {
		return nil, nil, disk.Identity{}, e
	}
	state, e := disk.Inspect(i.FS, inv, name)
	if e != nil {
		return nil, nil, disk.Identity{}, e
	}
	state.Protected = protected
	targets, e := disk.Select(inv, name, state)
	if e != nil {
		return nil, nil, disk.Identity{}, e
	}
	node, _ := inv.Get(name)
	id, e := disk.ReadIdentity(ctx, i.Runner, i.FS, node)
	return inv, targets, id, e
}
func (i *Installer) Message() string {
	switch i.Phase {
	case "dry-done":
		return "Dry run complete. Nothing was changed."
	case "live":
		return "Installer stopped; live environment prepared. No disk writes started."
	case "installing":
		return fmt.Sprintf("Install stopped at step: %s\nLog: %s\nThe disk may be partially installed.", i.Current, LogPath)
	case "installed":
		return "Installed successfully; reboot when ready. Log: " + LogPath
	default:
		return "Installer stopped. Nothing was changed."
	}
}
func (i *Installer) startLog() error {
	if i.Dry {
		return nil
	}
	f, e := os.OpenFile(i.FS.Path(LogPath), os.O_CREATE|os.O_TRUNC|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	if e = f.Chmod(0600); e != nil {
		_ = f.Close()
		return e
	}
	i.logFile = f
	i.Log = f
	if r, ok := i.Runner.(*run.Real); ok {
		r.Log = f
	}
	fmt.Fprintf(f, "Gilgamesh install, %s\ndisk=%s user=%s host=%s kernel=%s\n", time.Now().Format(time.RFC3339), i.Plan.Answers.Disk, i.Plan.Answers.Username, i.Plan.Answers.Hostname, i.Kernel)
	return nil
}
func (i *Installer) Close() {
	if i.logFile != nil {
		_ = i.logFile.Close()
	}
}
func (i *Installer) Run(ctx context.Context) error {
	i.Init()
	if e := i.startLog(); e != nil {
		return e
	}
	steps := []struct {
		name string
		fn   func(context.Context) error
	}{
		{"Partitioning " + i.Plan.Answers.Disk, i.PartitionDisk}, {"Creating filesystems", i.MakeFilesystems}, {"Mounting", i.MountTarget}, {"Installing packages (takes a while)", i.InstallPackages}, {"pacman and fstab", i.BaseConfig}, {"System files", i.CopyOverlay}, {"Timezone, locale, keyboard, hostname", i.SystemConfig}, {"User " + i.Plan.Answers.Username, i.CreateUser}, {"Hyprland priority, fish prompt", i.TuneSystem}, {"Initramfs", i.BuildInitramfs}, {"Bootloader", i.InstallBootloader}, {"Services and firewall", i.EnableServices}, {"Desktop config", i.UserConfig}, {"DNS", i.LinkResolvConf}}
	if i.UI != nil {
		names := make([]string, len(steps))
		for n, s := range steps {
			names[n] = s.name
		}
		i.UI.Begin(names)
	}
	for _, s := range steps {
		if s.name == "User "+i.Plan.Answers.Username {
			i.Current = "Checking target username"
			if e := i.CheckTargetUsername(ctx); e != nil {
				return e
			}
			s.name = "User " + i.Plan.Answers.Username
		}
		i.Current = s.name
		if i.Log != nil {
			fmt.Fprintln(i.Log, "\n==> "+s.name)
		}
		f := func(stepCtx context.Context) error {
			if e := stepCtx.Err(); e != nil {
				return e
			}
			return s.fn(stepCtx)
		}
		var e error
		if i.UI != nil {
			e = i.UI.Step(ctx, s.name, f)
		} else {
			e = f(ctx)
		}
		if e != nil {
			return fmt.Errorf("step %s: %w", s.name, e)
		}
	}
	i.Plan.Answers.Password = ""
	if i.Dry {
		i.Phase = "dry-done"
	} else {
		i.Phase = "installed"
	}
	return nil
}
func (i *Installer) PartitionDisk(ctx context.Context) error {
	_, targets, id, e := i.Validate(ctx, i.Plan.Answers.Disk)
	if e != nil {
		return e
	}
	if e = disk.Verify(i.Confirmed, id); e != nil {
		return e
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	if !i.Dry {
		i.Phase = "installing"
	}
	for _, p := range targets {
		if e = i.x(ctx, "wipefs", "-a", p); e != nil {
			return e
		}
	}
	if e = i.x(ctx, "sgdisk", i.Plan.PartitionArgs...); e != nil {
		return e
	}
	if e = i.x(ctx, "partprobe", i.Plan.Answers.Disk); e != nil {
		return e
	}
	if i.Dry {
		return nil
	}
	if e = i.x(ctx, "udevadm", "settle"); e != nil {
		return e
	}
	// Re-inventory instead of stat so fake tests need no fake device nodes/LD_PRELOAD.
	for attempt := 0; attempt < 50; attempt++ {
		inv, e := disk.Read(ctx, i.Runner)
		if e != nil {
			return e
		}
		a, ok := inv.Get(i.Plan.ESP)
		b, ok2 := inv.Get(i.Plan.Root)
		if ok && ok2 && a.Type == "part" && b.Type == "part" && a.Parent == i.Plan.Answers.Disk && b.Parent == i.Plan.Answers.Disk {
			return nil
		}
		if e = i.Sleep(ctx, 200*time.Millisecond); e != nil {
			return e
		}
	}
	return fmt.Errorf("partitions never showed up")
}
func (i *Installer) MakeFilesystems(ctx context.Context) error {
	for _, f := range i.Plan.Formats {
		if e := i.x(ctx, f.Program, f.Args...); e != nil {
			return e
		}
	}
	if i.Dry {
		return nil
	}
	var e error
	i.RootUUID, e = i.read(ctx, "blkid", "-s", "UUID", "-o", "value", i.Plan.Root)
	if e != nil {
		return e
	}
	i.ESPUUID, e = i.read(ctx, "blkid", "-s", "UUID", "-o", "value", i.Plan.ESP)
	if e != nil {
		return e
	}
	if i.RootUUID == "" || i.ESPUUID == "" || i.RootUUID == i.ESPUUID {
		return fmt.Errorf("invalid new filesystem UUIDs")
	}
	return nil
}
func (i *Installer) MountOwned(ctx context.Context, src, dst string, args ...string) error {
	idx := len(i.Mounts)
	if !i.Dry {
		i.Mounts = append(i.Mounts, Mount{dst, src, "pending"})
	}
	if e := i.x(ctx, "mount", append(args, src, dst)...); e != nil {
		return e
	}
	if i.Dry {
		return nil
	}
	id, e := i.read(ctx, "findmnt", "-rn", "-M", dst, "-o", "ID")
	if e != nil {
		return e
	}
	if !digits(id) {
		return fmt.Errorf("invalid mount ID")
	}
	i.Mounts[idx].ID = id
	return nil
}
func digits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
func (i *Installer) MountTarget(ctx context.Context) error {
	if e := i.targetClear(ctx); e != nil {
		return e
	}
	if e := i.MountOwned(ctx, i.Plan.Root, i.Target, i.Plan.RootMountOptions...); e != nil {
		return e
	}
	if e := i.x(ctx, "mkdir", "-p", i.Target+"/boot/efi"); e != nil {
		return e
	}
	return i.MountOwned(ctx, i.Plan.ESP, i.Target+"/boot/efi")
}
func (i *Installer) BaseConfig(ctx context.Context) error {
	if e := i.ConfigureRepository(ctx); e != nil {
		return e
	}
	if i.Dry {
		return i.write(i.Target+"/etc/fstab", "genfstab -U (drop swap; verify only new root and ESP UUIDs)\n", 0644)
	}
	s, e := i.read(ctx, "genfstab", "-U", i.Target)
	if e != nil {
		return e
	}
	s, e = plan.FilterFstab(s, i.RootUUID, i.ESPUUID)
	if e != nil {
		return e
	}
	return i.write(i.Target+"/etc/fstab", s, 0644)
}
func (i *Installer) Cleanup() error {
	if i.BeforeCleanup != nil {
		i.BeforeCleanup()
	}
	if i.Dry {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	var errs []error
	for n := len(i.Mounts) - 1; n >= 0; n-- {
		m := &i.Mounts[n]
		if m.ID == "done" {
			continue
		}
		for attempt := 0; attempt < 4; attempt++ {
			s, e := i.read(ctx, "findmnt", "-rn", "-M", m.Target, "-o", "SOURCE,ID")
			if run.Code(e) == 1 && s == "" {
				m.ID = "done"
				break
			}
			if e != nil {
				errs = append(errs, e)
				break
			}
			v := strings.Fields(s)
			if len(v) != 2 || v[0] != m.Source || (m.ID != "pending" && v[1] != m.ID) {
				errs = append(errs, fmt.Errorf("refusing to unmount changed mount %s at %s", s, m.Target))
				break
			}
			if m.Target == i.Target && attempt == 0 && i.FS.Exists(i.Target+"/etc/pacman.d/gnupg") {
				if e = i.x(ctx, "gpgconf", "--homedir", i.Target+"/etc/pacman.d/gnupg", "--kill", "all"); e != nil {
					fmt.Fprintln(i.Out, "Could not stop target keyring daemons:", e)
				}
			}
			if e = i.x(ctx, "umount", m.Target); e == nil {
				m.ID = "done"
				break
			}
			if attempt == 3 {
				errs = append(errs, fmt.Errorf("could not unmount %s. Run: umount -R %s before retrying the installer", m.Target, i.Target))
			} else if e = i.Sleep(ctx, time.Second); e != nil {
				errs = append(errs, e)
				break
			}
		}
	}
	return errors.Join(errs...)
}
func (i *Installer) targetNames() (bool, error) {
	var db []string
	for _, f := range []string{"passwd", "group"} {
		b, e := i.FS.Read(filepath.Join(i.Target, "etc", f))
		if e != nil {
			return false, e
		}
		db = append(db, string(b))
	}
	return plan.NameInUse(i.Plan.Answers.Username, db...), nil
}
