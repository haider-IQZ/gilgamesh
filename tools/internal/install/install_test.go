package install

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/haider-IQZ/gilgamesh/tools/internal/disk"
	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
	"github.com/haider-IQZ/gilgamesh/tools/internal/ui"
)

// Account names, passwords and hostnames below are synthetic test inputs.
type fakeUI struct {
	mode                             string
	users, selections, drains, steps int
	messages, screens, planned       []string
	defaults                         []bool
	confirmations                    []string
}

func (u *fakeUI) Welcome(context.Context) error { return nil }
func (u *fakeUI) Screen(title, _ string)        { u.screens = append(u.screens, title) }
func (u *fakeUI) Choose(_ context.Context, title string, opts []string, value string) (string, error) {
	if u.mode == "question-signal" {
		return "", context.Canceled
	}
	if title == "Select install disk" {
		u.selections++
		if u.selections == 1 && (u.mode == "retry-validation" || u.mode == "retry-identity") {
			return opts[1], nil
		}
	}
	return opts[0], nil
}
func (u *fakeUI) Filter(_ context.Context, _ string, opts []string) (string, error) {
	return opts[0], nil
}
func (u *fakeUI) Input(_ context.Context, prompt, _ string, secret bool) (string, error) {
	if secret {
		return "pa ss$w0rd", nil
	}
	if prompt == "Username> " {
		u.users++
		if u.users > 1 {
			return "newuser", nil
		}
		return "enkidu", nil
	}
	return "vmtest", nil
}
func (u *fakeUI) Confirm(_ context.Context, title, _, _ string, value bool) (bool, error) {
	u.confirmations = append(u.confirmations, title)
	u.defaults = append(u.defaults, value)
	return true, nil
}
func (u *fakeUI) Finished(_ context.Context, duration string) (bool, error) {
	u.confirmations = append(u.confirmations, "Reboot now?")
	u.defaults = append(u.defaults, true)
	u.messages = append(u.messages, "Installed Gilgamesh in "+duration)
	if u.mode == "final-cancel" {
		return false, context.Canceled
	}
	return u.mode == "reboot", nil
}
func (u *fakeUI) Notice(_ context.Context, s string) error {
	u.messages = append(u.messages, s)
	return nil
}
func (u *fakeUI) Spin(ctx context.Context, title string, fn func(context.Context) error) error {
	u.messages = append(u.messages, title)
	return fn(ctx)
}
func (u *fakeUI) Summary(ctx context.Context, rows [][2]string) (bool, error) {
	for _, r := range rows {
		u.messages = append(u.messages, r[0]+": "+r[1])
	}
	return u.Confirm(ctx, "Does this look right?", "Yes", "No, change it", true)
}
func (u *fakeUI) Drain() error          { u.drains++; return nil }
func (u *fakeUI) Begin(titles []string) { u.planned = titles }
func (u *fakeUI) Step(ctx context.Context, title string, fn func(context.Context) error) error {
	u.steps++
	if u.mode == "spinner-failure" && strings.HasPrefix(title, "Installing packages") {
		ctx, cancel := context.WithCancel(ctx)
		cancel()
		_ = fn(ctx)
		return run.ExitError{Code: 42}
	}
	return fn(ctx)
}

type fixture struct {
	i                        *Installer
	r                        *run.Fake
	u                        *fakeUI
	mounts                   map[string]Mount
	mode                     string
	identities, rootUnmounts int
	packageHook              func(context.Context) error
	password                 string
	rebooted                 bool
}

func newFixture(t *testing.T, mode string) *fixture {
	t.Helper()
	f := testkit.FS(t)
	u := &fakeUI{mode: mode}
	x := &fixture{u: u, mounts: map[string]Mount{}, mode: mode}
	r := &run.Fake{}
	x.r = r
	i := &Installer{FS: f, Runner: r, UI: u, Src: "/src", DNSBinary: "/src/tools/bin/gilgamesh-dns", UID: 0, Out: io.Discard, Sleep: func(context.Context, time.Duration) error { return nil }}
	i.HTTPClient = httpClientFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("offline fixture") })
	x.i = i
	for _, d := range []string{"/tmp", "/mnt", "/sys/firmware/efi", "/sys/block/vda/holders", "/sys/block/vdb/holders", "/sys/class/block/vda1/holders", "/sys/class/block/vda2/holders", "/src/quickshell"} {
		testkit.Dir(t, f, d)
	}
	for p, s := range map[string]string{"/etc/pacman.conf": "#[multilib]\n#Include = mirrorlist\n", "/proc/cmdline": "quiet", "/proc/swaps": "Filename Type Size Used Priority\n", "/proc/cpuinfo": "vendor_id : AuthenticAMD\n", "/sys/block/vda/diskseq": "7\n", "/sys/block/vdb/diskseq": "9\n", "/src/installer/packages": "base\ndosfstools\n", "/src/installer/packages-nvidia": "nvidia-open-dkms\nnvidia-utils\n", "/src/tools/bin/gilgamesh-dns": "fake executable; never run", "/src/etc/sudoers.d/gilgamesh-dns": "%wheel ALL=(root) NOPASSWD: /usr/bin/gilgamesh-dns DHCP\n", "/src/hypr/hyprland.lua": "-- fixture\n", "/src/fish/colors.fish": "# fixture\n", "/src/fish/prompt.fish": "# fixture\n", "/src/fish/greeting.fish": "# fixture\n", "/src/fish/starship.toml": "# fixture\n"} {
		testkit.Write(t, f, p, s)
	}
	// Read the real overlay, including the /dev/null symlink, without altering it.
	if e := CopyTree("../../../system", f.Path("/src/system"), false); e != nil {
		t.Fatal(e)
	}
	if mode == "no-diskseq" {
		if e := os.Remove(f.Path("/sys/block/vda/diskseq")); e != nil {
			t.Fatal(e)
		}
	}
	if mode == "glob" {
		testkit.Write(t, f, "/proc/cmdline", "archisolabel=LIVE*\n")
	}
	if mode == "retry-validation" {
		testkit.Write(t, f, "/sys/block/vdb/holders/dm-0", "")
	}
	r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		a := c.Args
		switch c.Name {
		case "lsblk":
			if a[0] == "-J" {
				size := uint64(60e9)
				serial, wwn := "", ""
				if x.identities >= 2 {
					switch mode {
					case "size-swap":
						size++
					case "serial-swap":
						serial = "new"
					case "wwn-swap":
						wwn = "new"
					}
				}
				nodes := []map[string]any{}
				for _, v := range []struct {
					name, typ, parent string
					size              uint64
				}{{"/dev/sr0", "rom", "", 1e9}, {"/dev/vda", "disk", "", size}, {"/dev/vda1", "part", "/dev/vda", 1e9}, {"/dev/vda2", "part", "/dev/vda", 59e9}, {"/dev/vdb", "disk", "", 60e9}} {
					nodes = append(nodes, map[string]any{"name": v.name, "type": v.typ, "pkname": v.parent, "size": v.size, "model": "Virtio", "serial": serial, "wwn": wwn, "mountpoints": []any{nil}, "ro": false})
				}
				b, _ := json.Marshal(map[string]any{"blockdevices": nodes})
				return string(b), nil
			}
			x.identities++
			if mode == "retry-identity" && a[len(a)-1] == "/dev/vdb" {
				return "invalid", nil
			}
			if mode == "sequence-swap" && x.identities == 3 {
				testkit.Write(t, f, "/sys/block/vda/diskseq", "8")
			}
			return "253:0", nil
		case "findmnt":
			if reflect.DeepEqual(a, []string{"-rn", "-o", "TARGET"}) {
				v := []string{"/", "/run/archiso/bootmnt"}
				for p := range x.mounts {
					v = append(v, p)
				}
				return strings.Join(v, "\n"), nil
			}
			if a[2] == "/run/archiso/bootmnt" {
				return "/dev/sr0", nil
			}
			if a[2] == "/run/archiso/img_dev" {
				return "", run.ExitError{Code: 1}
			}
			m, ok := x.mounts[a[2]]
			if !ok {
				return "", run.ExitError{Code: 1}
			}
			if a[4] == "ID" {
				return m.ID, nil
			}
			return m.Source + " " + m.ID, nil
		case "findfs":
			if !reflect.DeepEqual(a, []string{"LABEL=LIVE*"}) {
				return "", fmt.Errorf("glob changed %v", a)
			}
			return "/dev/sr0", nil
		case "getent":
			return "", run.ExitError{Code: 2}
		case "timedatectl":
			return "Etc/UTC\n", nil
		case "lspci":
			return "", nil
		case "mount":
			dst, src := a[len(a)-1], a[len(a)-2]
			x.mounts[dst] = Mount{dst, src, fmt.Sprint(len(x.mounts) + 10)}
		case "umount":
			if a[0] == "/mnt" {
				x.rootUnmounts++
				if mode == "busy" || mode == "busy-retry" && x.rootUnmounts < 3 {
					return "", run.ExitError{Code: 32}
				}
				if f.Exists("/mnt/etc/pacman.d/gnupg/active") {
					return "", fmt.Errorf("gpg-agent still active")
				}
			}
			delete(x.mounts, a[0])
		case "gpgconf":
			if e := f.Remove("/mnt/etc/pacman.d/gnupg/active"); e != nil {
				return "", e
			}
		case "pacstrap":
			if x.packageHook != nil {
				if e := x.packageHook(ctx); e != nil {
					return "", e
				}
			}
			for p, s := range map[string]string{"pacman.conf": "#[multilib]\n#Include = mirrorlist\n", "passwd": "root:x:0:0::/root:/bin/bash\n", "group": "root:x:0:\nwheel:x:998:\n", "locale.gen": "#en_US.UTF-8 UTF-8\n", "default/grub": "GRUB_TIMEOUT=5\n", "ufw/ufw.conf": "ENABLED=no\n", "pacman.d/gnupg/active": "active"} {
				testkit.Write(t, f, "/mnt/etc/"+p, s)
			}
			testkit.Write(t, f, "/mnt/boot/vmlinuz-"+i.Plan.Kernel, "fake kernel")
			if i.Bootstrap {
				// Model a bootstrap config copied by pacstrap, and package-owned files.
				b, e := f.Read(a[2])
				if e != nil {
					return "", e
				}
				testkit.Write(t, f, "/mnt/etc/pacman.conf", string(b))
				for _, p := range []string{"/etc/mkinitcpio.conf.d/gilgamesh.conf", "/usr/bin/gilgamesh-dns", "/etc/sudoers.d/gilgamesh-dns", "/usr/share/fish/vendor_conf.d/gilgamesh.fish"} {
					testkit.Write(t, f, "/mnt"+p, "package-owned fixture\n")
				}
			}
			if mode == "username-keys" {
				testkit.Write(t, f, "/mnt/etc/passwd", "root:x:0:\nenkidu:x:970:\n")
			}
		case "blkid":
			if a[len(a)-1] == "/dev/vda1" {
				return "esp-uuid", nil
			}
			return "root-uuid", nil
		case "genfstab":
			return "# generated\nUUID=root-uuid / xfs noatime 0 1\nUUID=esp-uuid /boot/efi vfat defaults 0 2\n/dev/vdb3 none swap defaults 0 0\n", nil
		case "arch-chroot":
			if a[1] == "mkinitcpio" {
				if !reflect.DeepEqual(a[2:], []string{"-p", i.Plan.Kernel}) {
					return "", fmt.Errorf("wrong kernel preset: %v", a)
				}
				testkit.Write(t, f, "/mnt/boot/initramfs-"+a[3]+".img", "fake initramfs")
			}
			if a[1] == "chpasswd" {
				if !c.Secret {
					t.Error("chpasswd not marked secret")
				}
				b, e := io.ReadAll(c.Stdin)
				if e != nil {
					return "", e
				}
				x.password = string(b)
			}
			if a[1] == "starship" {
				return "# starship init\n", nil
			}
		case "mkdir":
			for _, p := range a[1:] {
				testkit.Dir(t, f, p)
			}
		case "ln":
			dest := f.Path(a[len(a)-1])
			_ = os.Remove(dest)
			if e := os.MkdirAll(filepath.Dir(dest), 0755); e != nil {
				return "", e
			}
			if e := os.Symlink(a[len(a)-2], dest); e != nil {
				return "", e
			}
		case "install":
			b, e := f.Read(a[1])
			if e != nil {
				return "", e
			}
			m := os.FileMode(0755)
			if a[0] == "-Dm440" {
				m = 0440
			}
			if e = f.Write(a[2], b, m); e != nil {
				return "", e
			}
		case "cp": // Verify argv in the golden test; no subprocess escapes the fixture.
		case "reboot":
			if len(x.mounts) != 0 {
				return "", fmt.Errorf("reboot while mounts remain")
			}
			x.rebooted = true
		case "curl", "pacman", "wipefs", "sgdisk", "partprobe", "udevadm", "mkfs.fat", "mkfs.xfs", "loadkeys", "sync":
		default:
			return "", fmt.Errorf("unexpected fake command %s", run.Show(c))
		}
		return "", nil
	}
	return x
}
func commandList(calls []run.Command) [][]string {
	a := make([][]string, len(calls))
	for n, c := range calls {
		a[n] = append([]string{c.Name}, c.Args...)
	}
	return a
}
func TestVirtioFlowExactCommands(t *testing.T) {
	for _, bootstrap := range []bool{false, true} {
		t.Run(fmt.Sprint(bootstrap), func(t *testing.T) { testVirtioFlow(t, bootstrap) })
	}
}
func testVirtioFlow(t *testing.T, bootstrap bool) {
	x := newFixture(t, "virtio")
	if bootstrap {
		testkit.Write(t, x.i.FS, bootstrapDB, "fake database")
	}
	if e := x.i.Full(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	x.i.Close()
	if x.i.Phase != "installed" || x.u.steps != 14 || len(x.u.planned) != 14 || len(x.mounts) != 0 {
		t.Fatal(x.i.Message(), x.u.steps, x.u.planned, x.mounts)
	}
	if !reflect.DeepEqual(x.u.defaults, []bool{true, false, true}) || x.u.drains != 1 {
		t.Fatal("prompt defaults/drain", x.u.defaults, x.u.drains)
	}
	// Omarchy's order: machine, account, review, then the disk and its warning.
	if !reflect.DeepEqual(x.u.screens, []string{"Let's setup your machine...", "Let's setup your user account...", "Let's select where to install Gilgamesh...", "Everything will be overwritten. There is no recovery possible."}) {
		t.Fatal("screen order", x.u.screens)
	}
	if !strings.Contains(strings.Join(x.u.messages, "\n"), "Keyboard: English (US)\n") || !strings.HasPrefix(x.u.messages[len(x.u.messages)-1], "Installed Gilgamesh in ") {
		t.Fatal(x.u.messages)
	}
	golden := "testdata/virtio-commands.json"
	if bootstrap {
		golden = "testdata/virtio-bootstrap-commands.json"
	}
	b, e := os.ReadFile(golden)
	if e != nil {
		t.Fatal(e)
	}
	var want [][]string
	if e = json.Unmarshal(b, &want); e != nil {
		t.Fatal(e)
	}
	got := commandList(x.r.Calls)
	for _, c := range got {
		if c[0] == "pacstrap" && bootstrap {
			if !strings.HasPrefix(c[3], "/tmp/gilgamesh-pacman-") || !strings.HasSuffix(c[3], ".conf") {
				t.Fatal("unexpected temporary config", c)
			}
			c[3] = "/tmp/gilgamesh-pacman-TEMP.conf"
		}
	}
	if !reflect.DeepEqual(got, want) {
		for n := 0; n < max(len(got), len(want)); n++ {
			var g, w []string
			if n < len(got) {
				g = got[n]
			}
			if n < len(want) {
				w = want[n]
			}
			if !reflect.DeepEqual(g, w) {
				t.Errorf("command %d: got %q want %q", n, g, w)
			}
		}
	}
	for _, c := range x.r.Calls {
		switch c.Name {
		case "wipefs", "sgdisk", "partprobe", "mkfs.fat", "mkfs.xfs":
			p := c.Args[len(c.Args)-1]
			if p != "/dev/vda" && p != "/dev/vda1" && p != "/dev/vda2" {
				t.Errorf("write to unrelated device %s", p)
			}
		}
		if strings.Contains(run.Show(c), "pa ss$w0rd") {
			t.Fatal("password in argv")
		}
	}
	if x.password != "enkidu:pa ss$w0rd\n" {
		t.Fatal("password not sent via stdin")
	}
	checks := map[string]string{"/mnt/etc/fstab": "UUID=root-uuid / xfs noatime", "/mnt/etc/default/grub": "GRUB_TIMEOUT_STYLE=hidden", "/mnt/etc/ufw/ufw.conf": "ENABLED=yes", "/mnt/home/enkidu/.config/hypr/local.lua": `kb_layout = "us"`}
	if bootstrap {
		checks["/mnt/home/enkidu/.config/hypr/hyprland.lua"] = `dofile("/usr/share/gilgamesh/hypr/hyprland.lua")`
	} else {
		checks["/mnt/etc/fish/conf.d/starship.fish"] = "# starship init"
	}
	for p, w := range checks {
		b, e := x.i.FS.Read(p)
		if e != nil || !strings.Contains(string(b), w) {
			t.Error(p, string(b), e)
		}
	}
	links := map[string]string{"/mnt/etc/resolv.conf": "../run/systemd/resolve/stub-resolv.conf"}
	if !bootstrap {
		links["/mnt/etc/systemd/user/localsearch-3.service"] = "/dev/null"
	}
	for p, w := range links {
		s, e := os.Readlink(x.i.FS.Path(p))
		if e != nil || s != w {
			t.Error(p, s, e)
		}
	}
	log, e := x.i.FS.Read(LogPath)
	if e != nil || strings.Contains(string(log), "pa ss$w0rd") || strings.Count(string(log), "==> ") != 14 {
		t.Fatal("invalid log", e)
	}
}
func TestHarnessScenarios(t *testing.T) {
	for _, mode := range []string{"no-diskseq", "size-swap", "serial-swap", "wwn-swap", "sequence-swap", "question-signal", "username-keys", "retry-validation", "retry-identity", "glob", "busy-retry", "busy", "reboot", "spinner-failure", "final-cancel"} {
		t.Run(mode, func(t *testing.T) {
			x := newFixture(t, mode)
			e := x.i.Full(context.Background())
			ce := x.i.Cleanup()
			x.i.Close()
			bad := strings.HasSuffix(mode, "-swap") || mode == "question-signal" || mode == "spinner-failure" || mode == "final-cancel"
			if (e != nil) != bad {
				t.Fatalf("flow error %v", e)
			}
			if (ce != nil) != (mode == "busy") {
				t.Fatalf("cleanup error %v", ce)
			}
			if mode != "busy" && len(x.mounts) != 0 {
				t.Fatal("mounts left", x.mounts)
			}
			if strings.HasSuffix(mode, "-swap") {
				if !strings.Contains(e.Error(), "refusing to wipe") {
					t.Fatal(e)
				}
				for _, c := range x.r.Calls {
					if c.Name == "wipefs" || strings.HasPrefix(c.Name, "mkfs.") {
						t.Fatal("wrote after identity change")
					}
				}
				if x.i.Phase != "live" {
					t.Fatal(x.i.Message())
				}
			}
			if mode == "question-signal" && x.i.FS.Exists(LogPath) {
				t.Fatal("log before questions completed")
			}
			if mode == "username-keys" && (x.u.drains != 2 || x.i.Plan.Answers.Username != "newuser") {
				t.Fatal("username correction/drain", x.u.drains)
			}
			if strings.HasPrefix(mode, "retry-") && x.u.selections != 2 {
				t.Fatal("selection not retried")
			}
			if mode == "busy-retry" && x.rootUnmounts != 3 {
				t.Fatal(x.rootUnmounts)
			}
			if mode == "busy" && (x.rootUnmounts != 4 || !strings.Contains(ce.Error(), "Run: umount -R /mnt")) {
				t.Fatal(ce)
			}
			if mode == "reboot" && !x.rebooted {
				t.Fatal("not rebooted")
			}
			if mode == "final-cancel" && x.i.Phase != "installed" {
				t.Fatal(x.i.Message())
			}
			if mode == "spinner-failure" && run.Code(e) != 42 {
				t.Fatal(e)
			}
		})
	}
}
func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	m := map[string]string{}
	e := filepath.WalkDir(root, func(p string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if d.IsDir() {
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			s, e := os.Readlink(p)
			m[p] = "link:" + s
			return e
		}
		b, e := os.ReadFile(p)
		m[p] = string(b)
		return e
	})
	if e != nil {
		t.Fatal(e)
	}
	return m
}
func TestDryRunWritesNothing(t *testing.T) {
	x := newFixture(t, "dry-run")
	x.i.Dry = true
	before := snapshot(t, x.i.FS.Root)
	if e := x.i.Full(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	after := snapshot(t, x.i.FS.Root)
	if !reflect.DeepEqual(before, after) {
		t.Fatal("dry run changed fixture filesystem")
	}
	for _, c := range x.r.Calls {
		switch c.Name {
		case "lsblk", "findmnt", "lspci", "getent", "timedatectl":
		default:
			t.Fatal("mutating command in dry-run", c)
		}
	}
	if x.i.Message() != "Dry run complete. Nothing was changed." {
		t.Fatal(x.i.Message())
	}
}
func TestChangedMountRefused(t *testing.T) {
	x := newFixture(t, "")
	x.i.Init()
	x.i.Mounts = []Mount{{"/mnt", "/dev/vda2", "10"}}
	x.mounts["/mnt"] = Mount{"/mnt", "/dev/vdb1", "11"}
	if e := x.i.Cleanup(); e == nil || !strings.Contains(e.Error(), "changed mount") {
		t.Fatal(e)
	}
	for _, c := range x.r.Calls {
		if c.Name == "umount" {
			t.Fatal("unmounted somebody else's mount")
		}
	}
}
func TestTargetNameRace(t *testing.T) {
	x := newFixture(t, "")
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Questions(context.Background()); e != nil {
		t.Fatal(e)
	}
	testkit.Write(t, x.i.FS, "/mnt/etc/passwd", "enkidu:x:1:\n")
	testkit.Write(t, x.i.FS, "/mnt/etc/group", "root:x:0:\n")
	if e := x.i.CreateUser(context.Background()); e == nil {
		t.Fatal("target user collision accepted")
	}
	for _, c := range x.r.Calls {
		if c.Name == "arch-chroot" && c.Args[1] == "useradd" {
			t.Fatal("useradd after collision")
		}
	}
}
func TestCancelPackage(t *testing.T) {
	x := newFixture(t, "")
	ctx, cancel := context.WithCancel(context.Background())
	cleaned := false
	x.packageHook = func(ctx context.Context) error { cancel(); <-ctx.Done(); cleaned = true; return ctx.Err() }
	e := x.i.Full(ctx)
	if !errors.Is(e, context.Canceled) || !cleaned {
		t.Fatal(e)
	}
	if e = x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	x.i.Close()
	if len(x.mounts) != 0 || !strings.Contains(x.i.Message(), "Installing packages") || !strings.Contains(x.i.Message(), "partially installed") {
		t.Fatal(x.i.Message(), x.mounts)
	}
}
func TestOverlayMetadata(t *testing.T) {
	f := testkit.FS(t)
	testkit.Dir(t, f, "/src/etc")
	testkit.Write(t, f, "/src/etc/config", "test\n")
	testkit.Dir(t, f, "/dst/etc")
	if e := os.Chmod(f.Path("/dst/etc"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink("/dev/null", f.Path("/src/etc/masked")); e != nil {
		t.Fatal(e)
	}
	if e := CopyTree(f.Path("/src"), f.Path("/dst"), false); e != nil {
		t.Fatal(e)
	}
	st, e := os.Stat(f.Path("/dst/etc"))
	if e != nil || st.Mode().Perm() != 0700 {
		t.Fatal("changed existing directory mode")
	}
	v, e := os.Readlink(f.Path("/dst/etc/masked"))
	if e != nil || v != "/dev/null" {
		t.Fatal(v, e)
	}
}
func TestWipeVerification(t *testing.T) {
	x := newFixture(t, "")
	x.i.Init()
	_, _, id, e := x.i.Validate(context.Background(), "/dev/vda")
	if e != nil {
		t.Fatal(e)
	}
	if id.Serial != "" || id.WWN != "" || id.DiskSeq != "7" || id.Size != 60e9 {
		t.Fatal(id)
	}
	if _, _, _, e = x.i.Validate(context.Background(), "/dev/sr0"); e == nil {
		t.Fatal("live medium accepted")
	}
	_ = disk.MinBytes
}

func TestMountIntentSurvivesCancellation(t *testing.T) {
	x := newFixture(t, "")
	x.i.Init()
	ctx, cancel := context.WithCancel(context.Background())
	old := x.r.Handle
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		s, e := old(ctx, c)
		if c.Name == "mount" {
			cancel()
			return "", ctx.Err()
		}
		return s, e
	}
	if e := x.i.MountOwned(ctx, "/dev/vda2", "/mnt", "-o", "noatime"); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	if len(x.i.Mounts) != 1 || x.i.Mounts[0].ID != "pending" {
		t.Fatal("lost mount intent")
	}
	if e := x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	if len(x.mounts) != 0 {
		t.Fatal("mount leaked")
	}
}
func TestKeyboardRetry(t *testing.T) {
	x := newFixture(t, "")
	x.i.Console = true
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	old := x.r.Handle
	loads := 0
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		if c.Name == "loadkeys" {
			loads++
			if loads == 1 {
				return "", run.ExitError{Code: 1}
			}
		}
		return old(ctx, c)
	}
	if e := x.i.Questions(context.Background()); e != nil {
		t.Fatal(e)
	}
	if loads != 2 {
		t.Fatal("loadkeys not retried", loads)
	}
}
func TestTimezoneFallback(t *testing.T) {
	x := newFixture(t, "")
	// Etc/Test is a synthetic alias used to exercise link parsing and sorting.
	testkit.Write(t, x.i.FS, "/usr/share/zoneinfo/tzdata.zi", "Z Etc/UTC 0 - UTC\nL Etc/UTC Etc/Test\n")
	old := x.r.Handle
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		if c.Name == "timedatectl" {
			return "", run.ExitError{Code: 1}
		}
		return old(ctx, c)
	}
	v, e := x.i.Timezones(context.Background())
	if e != nil || !reflect.DeepEqual(v, []string{"Etc/Test", "Etc/UTC"}) {
		t.Fatal(v, e)
	}
}
func TestNvidiaEnvironment(t *testing.T) {
	x := newFixture(t, "")
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	x.i.PCI = "VGA [0300]: NVIDIA [10de:2206]" // Synthetic GPU fixture.
	if e := x.i.Questions(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Run(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	x.i.Close()
	b, e := x.i.FS.Read("/mnt/etc/environment")
	if e != nil || !strings.Contains(string(b), "__GL_SHADER_DISK_CACHE_SIZE=12000000000\n__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1") {
		t.Fatal(string(b), e)
	}
	found := false
	for _, c := range x.r.Calls {
		if c.Name == "pacstrap" {
			found = strings.Contains(strings.Join(c.Args, " "), "nvidia-open-dkms nvidia-utils")
		}
	}
	if !found {
		t.Fatal("missing NVIDIA packages")
	}
}
func TestPreflightRefusals(t *testing.T) {
	for _, mode := range []string{"not root", "no UEFI", "empty packages", "unreadable packages", "failed graphics", "failed getent", "mounted target", "unidentified ISO"} {
		t.Run(mode, func(t *testing.T) {
			x := newFixture(t, "")
			old := x.r.Handle
			switch mode {
			case "not root":
				x.i.UID = 1000
			case "no UEFI":
				if e := os.Remove(x.i.FS.Path("/sys/firmware/efi")); e != nil {
					t.Fatal(e)
				}
			case "empty packages":
				testkit.Write(t, x.i.FS, "/src/installer/packages", "# empty\n")
			case "unreadable packages":
				if e := os.Remove(x.i.FS.Path("/src/installer/packages")); e != nil {
					t.Fatal(e)
				}
			}
			x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
				if mode == "failed graphics" && c.Name == "lspci" || mode == "failed getent" && c.Name == "getent" {
					return "", run.ExitError{Code: 3}
				}
				if mode == "mounted target" && c.Name == "findmnt" && reflect.DeepEqual(c.Args, []string{"-rn", "-o", "TARGET"}) {
					return "/mnt/other", nil
				}
				if mode == "unidentified ISO" && c.Name == "findmnt" && len(c.Args) > 2 && strings.HasPrefix(c.Args[2], "/run/archiso/") {
					return "", run.ExitError{Code: 1}
				}
				return old(ctx, c)
			}
			if e := x.i.Full(context.Background()); e == nil {
				t.Fatal("unsafe preflight accepted")
			}
			for _, c := range x.r.Calls {
				if c.Name == "wipefs" {
					t.Fatal("wrote after failed preflight")
				}
			}
		})
	}
}
func TestDownloadedCheckout(t *testing.T) {
	x := newFixture(t, "")
	x.i.Src = "/missing"
	old := x.r.Handle
	downloaded := false
	x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
		if c.Name == "curl" && c.Args[0] == "-fsSL" {
			downloaded = true
			return "", nil
		}
		if c.Name == "tar" {
			return "", CopyTree(x.i.FS.Path("/src"), x.i.FS.Path(c.Args[3]), false)
		}
		return old(ctx, c)
	}
	if e := x.i.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	if !downloaded || !strings.HasPrefix(x.i.Src, "/tmp/gilgamesh.") {
		t.Fatal(x.i.Src)
	}
}
func TestDryRunMissingCheckout(t *testing.T) {
	x := newFixture(t, "")
	x.i.Src = "/missing"
	x.i.Dry = true
	before := snapshot(t, x.i.FS.Root)
	if e := x.i.Prepare(context.Background()); e == nil {
		t.Fatal("dry-run downloaded checkout")
	}
	if !reflect.DeepEqual(before, snapshot(t, x.i.FS.Root)) || len(x.r.Calls) != 0 {
		t.Fatal("dry-run wrote or executed commands")
	}
}

type stepUI struct {
	*fakeUI
	progress *ui.UI
}

func (u *stepUI) Step(ctx context.Context, title string, fn func(context.Context) error) error {
	return u.progress.Step(ctx, title, fn)
}
func TestStepPanicCleanup(t *testing.T) {
	x := newFixture(t, "")
	in, e := os.Open(os.DevNull)
	if e != nil {
		t.Fatal(e)
	}
	defer in.Close()
	x.i.UI = &stepUI{x.u, &ui.UI{In: in, Out: io.Discard}}
	x.packageHook = func(context.Context) error { panic("synthetic package failure") }
	e = x.i.Full(context.Background())
	if e == nil || !strings.Contains(e.Error(), "synthetic package failure") || len(x.mounts) != 2 {
		t.Fatal(e, x.mounts)
	}
	cleaned := false
	x.i.BeforeCleanup = func() { cleaned = true }
	if e = x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	x.i.Close()
	var unmounts []string
	for _, c := range x.r.Calls {
		if c.Name == "umount" {
			unmounts = append(unmounts, c.Args[0])
		}
	}
	if !cleaned || len(x.mounts) != 0 || !reflect.DeepEqual(unmounts, []string{"/mnt/boot/efi", "/mnt"}) {
		t.Fatal("panic cleanup failed", cleaned, x.mounts, unmounts)
	}
}

func TestConfirmationDiskLabels(t *testing.T) {
	for _, identifiers := range []bool{false, true} {
		x := newFixture(t, "")
		old := x.r.Handle
		x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
			s, e := old(ctx, c)
			if identifiers && c.Name == "lsblk" && c.Args[0] == "-J" {
				s = strings.ReplaceAll(s, `"serial":""`, `"serial":"TEST-SERIAL"`)
				s = strings.ReplaceAll(s, `"wwn":""`, `"wwn":"TEST-WWN"`)
			}
			return s, e
		}
		if e := x.i.Prepare(context.Background()); e != nil {
			t.Fatal(e)
		}
		if e := x.i.Questions(context.Background()); e != nil {
			t.Fatal(e)
		}
		want := "/dev/vda  60.0 GB  Virtio"
		if identifiers {
			want += "  Serial: TEST-SERIAL  WWN: TEST-WWN"
		}
		if x.u.confirmations[1] != "Erase everything on "+want+"? This cannot be undone." || x.u.defaults[1] {
			t.Fatal(x.u.confirmations, x.u.defaults)
		}
	}
}

func TestFindSource(t *testing.T) {
	f := testkit.FS(t)
	for _, root := range []string{"/checkout", "/cwd-checkout"} {
		testkit.Write(t, f, root+"/installer/packages", "test-package\n")
		testkit.Dir(t, f, root+"/tools/bin")
	}
	testkit.Write(t, f, "/checkout/tools/bin/gilgamesh-install", "")
	testkit.Write(t, f, "/standalone/gilgamesh-install", "")
	testkit.Dir(t, f, "/unrelated")
	if e := os.Symlink(f.Path("/checkout/tools/bin/gilgamesh-install"), f.Path("/unrelated/installer")); e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct{ exe, cwd, want string }{
		{"/checkout/tools/bin/gilgamesh-install", "/unrelated", "/checkout"},
		{"/checkout/tools/bin/gilgamesh-install", "/cwd-checkout", "/checkout"},
		{"/unrelated/installer", "/unrelated", "/checkout"},
		{"/standalone/gilgamesh-install", "/cwd-checkout", "/cwd-checkout"},
		{"/standalone/gilgamesh-install", "/cwd-checkout/tools", "/cwd-checkout"},
		{"/missing", "/cwd-checkout/tools/bin", "/cwd-checkout"},
		{"/missing", "/unrelated", "/unrelated"},
	} {
		if got := findSource(f.Path(tc.exe), f.Path(tc.cwd)); got != f.Path(tc.want) {
			t.Errorf("%+v: got %s", tc, got)
		}
	}
}
