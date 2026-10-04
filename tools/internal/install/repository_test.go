package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/plan"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

const livePacman = "[options]\nSigLevel = Required DatabaseOptional\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n"

func TestPackagePaths(t *testing.T) {
	for _, bootstrap := range []bool{false, true} {
		for _, gpu := range []string{"none", "nvidia", "old", "mixed"} {
			t.Run(fmt.Sprintf("bootstrap=%t/%s", bootstrap, gpu), func(t *testing.T) {
				x := newFixture(t, "")
				if bootstrap {
					testkit.Write(t, x.i.FS, bootstrapDB, "fake database")
					// The packaged DNS helper must not require a companion Go binary.
					if e := x.i.FS.Remove(x.i.DNSBinary); e != nil {
						t.Fatal(e)
					}
				}
				conf := livePacman
				if bootstrap {
					conf += plan.BootstrapRepository
				}
				testkit.Write(t, x.i.FS, "/etc/pacman.conf", conf)
				old := x.r.Handle
				var temporary string
				x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
					if c.Name == "lspci" {
						switch gpu {
						case "nvidia":
							return "VGA [0300]: NVIDIA [10de:2206]", nil
						case "old":
							return "VGA [0300]: NVIDIA [10de:1000]", nil
						case "mixed":
							return "VGA [0300]: NVIDIA [10de:2206]\n3D [0302]: NVIDIA [10de:1000]", nil
						}
					}
					if c.Name == "pacstrap" && bootstrap {
						temporary = c.Args[2]
						b, e := x.i.FS.Read(temporary)
						if e != nil {
							t.Fatal(e)
						}
						s := string(b)
						if strings.Count(s, "[gilgamesh]") != 1 || !strings.Contains(s, strings.TrimSpace(plan.BootstrapRepository)) || strings.Index(s, "[gilgamesh]") > strings.Index(s, "[core]") || !strings.Contains(s, "SigLevel = Required DatabaseOptional") {
							t.Fatal("invalid bootstrap configuration", s)
						}
					}
					return old(ctx, c)
				}
				if e := x.i.Full(context.Background()); e != nil {
					t.Fatal(e)
				}
				if e := x.i.Cleanup(); e != nil {
					t.Fatal(e)
				}
				x.i.Close()
				kernel, driver := "linux", "nvidia-open-dkms"
				if bootstrap {
					kernel, driver = "linux-tkg", "nvidia-open-tkg"
					if x.i.FS.Exists(temporary) {
						t.Fatal("temporary pacman configuration leaked")
					}
				}
				if x.i.Plan.Kernel != kernel {
					t.Fatal(x.i.Plan.Kernel)
				}
				var installed []string
				for _, c := range x.r.Calls {
					if c.Name == "pacstrap" {
						start := 2
						if bootstrap {
							start = 4
						}
						installed = c.Args[start:]
					}
				}
				for _, pkg := range []string{"linux", "linux-headers", "linux-tkg", "linux-tkg-headers", "nvidia-open-tkg", "nvidia-open-dkms", "nvidia-utils", "gilgamesh-settings", "gilgamesh-shell"} {
					want := pkg == kernel || pkg == kernel+"-headers" || gpu == "nvidia" && (pkg == driver || pkg == "nvidia-utils") || bootstrap && (pkg == "gilgamesh-settings" || pkg == "gilgamesh-shell")
					if slices.Contains(installed, pkg) != want {
						t.Fatalf("package %s: %v", pkg, installed)
					}
				}
				b, e := x.i.FS.Read("/mnt/etc/pacman.conf")
				if e != nil || strings.Contains(string(b), "gilgamesh") || strings.Contains(string(b), "Never") || strings.Contains(string(b), "/opt/") {
					t.Fatal("unsafe target pacman config", string(b), e)
				}
				b, e = x.i.FS.Read(LogPath)
				pathNote := "checkout fallback"
				if bootstrap {
					pathNote = "Using local Gilgamesh bootstrap repository"
				}
				if e != nil || !strings.Contains(string(b), pathNote) || !strings.Contains(string(b), "No keys/gilgamesh.asc") {
					t.Fatal("missing repository notes", string(b), e)
				}
			})
		}
	}
}

func TestPackagedFilesNotOverwritten(t *testing.T) {
	x := newFixture(t, "")
	testkit.Write(t, x.i.FS, bootstrapDB, "fake database")
	testkit.Write(t, x.i.FS, "/src/system/etc/unpackaged.conf", "keep this\n")
	if e := x.i.Full(context.Background()); e != nil {
		t.Fatal(e)
	}
	defer x.i.Close()
	if e := x.i.Cleanup(); e != nil {
		t.Fatal(e)
	}
	for _, p := range []string{"/etc/mkinitcpio.conf.d/gilgamesh.conf", "/usr/bin/gilgamesh-dns", "/etc/sudoers.d/gilgamesh-dns", "/usr/share/fish/vendor_conf.d/gilgamesh.fish"} {
		b, e := x.i.FS.Read("/mnt" + p)
		if e != nil || string(b) != "package-owned fixture\n" {
			t.Fatal("package file overwritten", p, string(b), e)
		}
	}
	// Every current overlay source is mapped by the settings PKGBUILD. In
	// particular, no /etc override or localsearch mask may shadow vendor files.
	e := filepath.WalkDir("../../../system", func(p string, d os.DirEntry, e error) error {
		if e != nil || d.IsDir() {
			return e
		}
		rel, e := filepath.Rel("../../../system", p)
		if e != nil {
			return e
		}
		if !plan.SettingsOwns(filepath.ToSlash(rel)) {
			t.Errorf("update PKGBUILD mapping for %s", rel)
		}
		if rel != "etc/mkinitcpio.conf.d/gilgamesh.conf" {
			if _, e := os.Lstat(x.i.FS.Path("/mnt/" + rel)); !os.IsNotExist(e) {
				t.Errorf("raw overlay copy: %s (%v)", rel, e)
			}
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
	for _, p := range []string{"/mnt/etc/fish/conf.d/starship.fish", "/mnt/home/enkidu/.config/starship.toml", "/mnt/home/enkidu/.config/quickshell"} {
		if x.i.FS.Exists(p) {
			t.Fatal("shadowing packaged defaults", p)
		}
	}
	for _, c := range x.r.Calls {
		if c.Name == "cp" || c.Name == "install" || c.Name == "arch-chroot" && (c.Args[1] == "starship" || c.Args[1] == "setcap") {
			t.Fatal("redundant package-owned setup", c)
		}
	}
	for _, p := range []string{"/etc/unpackaged.conf", "/home/enkidu/.config/hypr/local.lua", "/home/enkidu/.config/foot/foot.ini", "/home/enkidu/.config/mpv/mpv.conf"} {
		if !x.i.FS.Exists("/mnt" + p) {
			t.Fatal("missing unowned config", p)
		}
	}
}

// Synthetic public fingerprint and colon output; no real key material or GPG.
const testFingerprint = "0123456789ABCDEF0123456789ABCDEF01234567"
const testPublicKey = "pub:-:4096:1:0123456789ABCDEF:0:0::-:::sc:\nfpr:::::::::" + testFingerprint + ":\nsub:-:4096:1:0000000000000000:0:0::::e:\nfpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n"

func TestPublishedRepository(t *testing.T) {
	for _, failure := range []string{"", "inspect", "invalid", "import", "sign"} {
		t.Run(failure, func(t *testing.T) {
			x := newFixture(t, "")
			x.i.Init()
			testkit.Write(t, x.i.FS, "/mnt/etc/pacman.conf", livePacman+plan.BootstrapRepository)
			testkit.Write(t, x.i.FS, "/src/keys/gilgamesh.asc", "synthetic public certificate fixture")
			var key string
			x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
				if c.Name != "arch-chroot" || c.Args[0] != "/mnt" {
					t.Fatal(c)
				}
				a := c.Args[1:]
				switch a[0] {
				case "gpg":
					key = a[len(a)-1]
					if !strings.HasPrefix(key, "/etc/pacman.d/gilgamesh-key-") {
						t.Fatal("key could be hidden by arch-chroot mounts", key)
					}
					if !x.i.FS.Exists("/mnt" + key) {
						t.Fatal("key was not staged in target")
					}
					if failure == "inspect" {
						return "", run.ExitError{Code: 2}
					}
					if failure == "invalid" {
						return "pub:::::::::\n", nil
					}
					return testPublicKey, nil
				case "pacman-key":
					if a[1] == "--add" {
						if !reflect.DeepEqual(a, []string{"pacman-key", "--add", key}) {
							t.Fatal(a)
						}
						if failure == "import" {
							return "", run.ExitError{Code: 2}
						}
					} else if !reflect.DeepEqual(a, []string{"pacman-key", "--lsign-key", testFingerprint}) {
						t.Fatal(a)
					} else if failure == "sign" {
						return "", run.ExitError{Code: 2}
					}
				default:
					t.Fatal(c)
				}
				return "", nil
			}
			e := x.i.ConfigureRepository(context.Background())
			if (e != nil) != (failure != "") {
				t.Fatal(e)
			}
			b, e := x.i.FS.Read("/mnt/etc/pacman.conf")
			if e != nil || strings.Contains(string(b), "Never") || strings.Contains(string(b), "/opt/") {
				t.Fatal(string(b), e)
			}
			if failure == "" {
				if !strings.Contains(string(b), strings.TrimSpace(plan.PublishedRepository)) || len(x.r.Calls) != 3 || strings.Index(string(b), "[gilgamesh]") > strings.Index(string(b), "[core]") {
					t.Fatal(string(b), x.r.Calls)
				}
			} else if strings.Contains(string(b), "[gilgamesh]") {
				t.Fatal("repository enabled before trust succeeded", string(b))
			}
			if x.i.FS.Exists("/mnt" + key) {
				t.Fatal("temporary key leaked")
			}
		})
	}
}

func TestBootstrapTempCleanupOnFailure(t *testing.T) {
	for _, cancel := range []bool{false, true} {
		x := newFixture(t, "")
		x.i.Init()
		x.i.Bootstrap = true
		var p string
		x.r.Handle = func(ctx context.Context, c run.Command) (string, error) {
			p = c.Args[2]
			if cancel {
				return "", context.Canceled
			}
			return "", run.ExitError{Code: 42}
		}
		e := x.i.InstallPackages(context.Background())
		if cancel && !errors.Is(e, context.Canceled) || !cancel && run.Code(e) != 42 || x.i.FS.Exists(p) {
			t.Fatal(e, p)
		}
	}
}

func TestBootstrapDryRunWritesNothing(t *testing.T) {
	x := newFixture(t, "")
	testkit.Write(t, x.i.FS, bootstrapDB, "fake database")
	testkit.Write(t, x.i.FS, "/src/keys/gilgamesh.asc", "synthetic certificate fixture")
	x.i.Dry = true
	before := snapshot(t, x.i.FS.Root)
	if e := x.i.Full(context.Background()); e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(before, snapshot(t, x.i.FS.Root)) {
		t.Fatal("bootstrap dry run wrote files")
	}
	for _, c := range x.r.Calls {
		switch c.Name {
		case "lsblk", "findmnt", "lspci", "getent", "timedatectl":
		default:
			t.Fatal("mutating dry-run command", c)
		}
	}
}

func TestBootloaderRequiresSelectedKernel(t *testing.T) {
	for _, missing := range []string{"vmlinuz-linux-tkg", "initramfs-linux-tkg.img"} {
		x := newFixture(t, "")
		x.i.Init()
		x.i.Plan.Kernel = "linux-tkg"
		for _, p := range []string{"vmlinuz-linux", "initramfs-linux.img", "vmlinuz-linux-tkg", "initramfs-linux-tkg.img"} {
			if p != missing {
				testkit.Write(t, x.i.FS, "/mnt/boot/"+p, "fake image")
			}
		}
		if e := x.i.InstallBootloader(context.Background()); e == nil || !strings.Contains(e.Error(), missing) || len(x.r.Calls) != 0 {
			t.Fatal(e, x.r.Calls)
		}
	}
}

func TestPublicFingerprints(t *testing.T) {
	got, e := publicFingerprints(testPublicKey)
	if e != nil || !reflect.DeepEqual(got, []string{testFingerprint}) {
		t.Fatal(got, e)
	}
	for _, s := range []string{"", "pub:::::::::\n", "pub:::::::::\nfpr:::::::::short:", "sec:::::::::\n" + testPublicKey, "ssb:::::::::\n" + testPublicKey} {
		if _, e := publicFingerprints(s); e == nil {
			t.Fatal("invalid public certificate accepted", s)
		}
	}
}
