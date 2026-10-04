package install

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/plan"
)

// CopyTree preserves symlinks and existing directory modes/owners. New overlay
// entries are root-owned; source checkout ownership is never inherited.
func CopyTree(src, dst string, rootOwned bool) error {
	return copyTree(src, dst, rootOwned, nil)
}
func copyTree(src, dst string, rootOwned bool, skip func(string) bool) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if !d.IsDir() && skip != nil && skip(filepath.ToSlash(rel)) {
			return nil
		}
		dest := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			if v, e := os.Lstat(dest); e == nil {
				if !v.IsDir() {
					return fmt.Errorf("overlay directory is not a directory: %s", dest)
				}
				return nil
			}
			if err = os.Mkdir(dest, 0755); err != nil {
				return err
			}
		} else if d.Type()&os.ModeSymlink != 0 {
			link, e := os.Readlink(path)
			if e != nil {
				return e
			}
			if e = os.Remove(dest); e != nil && !os.IsNotExist(e) {
				return e
			}
			if e = os.Symlink(link, dest); e != nil {
				return e
			}
		} else if info.Mode().IsRegular() {
			if v, e := os.Lstat(dest); e == nil && v.Mode()&os.ModeSymlink != 0 {
				if e = os.Remove(dest); e != nil {
					return e
				}
			}
			in, e := os.Open(path)
			if e != nil {
				return e
			}
			defer in.Close()
			mode := os.FileMode(0644)
			if info.Mode()&0111 != 0 {
				mode = 0755
			}
			out, e := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
			if e != nil {
				return e
			}
			_, e = io.Copy(out, in)
			ce := out.Close()
			if e != nil {
				return e
			}
			if ce != nil {
				return ce
			}
			if e = os.Chmod(dest, mode); e != nil {
				return e
			}
		} else {
			return fmt.Errorf("unsupported overlay entry: %s", path)
		}
		if rootOwned {
			return os.Lchown(dest, 0, 0)
		}
		return nil
	})
}
func (i *Installer) CopyOverlay(ctx context.Context) error {
	if e := ctx.Err(); e != nil {
		return e
	}
	var skip func(string) bool
	if i.Bootstrap {
		skip = plan.SettingsOwns
		i.note("Copying only system overlay files not supplied by gilgamesh-settings.")
	}
	if i.Log != nil {
		fmt.Fprintln(i.Log, "$ copy "+i.Src+"/system onto "+i.Target)
	}
	if i.Dry {
		fmt.Fprintln(i.Out, "copy system overlay (root-owned; preserve symlinks and existing directories)")
	} else if e := copyTree(i.FS.Path(i.Src+"/system"), i.FS.Path(i.Target), i.FS.Root == "" || i.FS.Root == "/", skip); e != nil {
		return e
	}
	if i.Plan.NVIDIA {
		p := i.Target + "/etc/environment"
		s := ""
		if !i.Dry {
			b, e := i.FS.Read(p)
			if e != nil && !os.IsNotExist(e) {
				return e
			}
			s = string(b)
		}
		if e := i.write(p, s+"__GL_SHADER_DISK_CACHE_SIZE=12000000000\n__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1\n", 0644); e != nil {
			return e
		}
	}
	if !i.Bootstrap {
		if e := i.x(ctx, "install", "-Dm755", i.DNSBinary, i.Target+"/usr/bin/gilgamesh-dns"); e != nil {
			return e
		}
		if e := i.x(ctx, "install", "-Dm440", i.Src+"/etc/sudoers.d/gilgamesh-dns", i.Target+"/etc/sudoers.d/gilgamesh-dns"); e != nil {
			return e
		}
	}
	return i.chroot(ctx, "visudo", "-cf", "/etc/sudoers.d/gilgamesh-dns")
}
func (i *Installer) SystemConfig(ctx context.Context) error {
	a := i.Plan.Answers
	if e := i.x(ctx, "ln", "-sf", "/usr/share/zoneinfo/"+a.Timezone, i.Target+"/etc/localtime"); e != nil {
		return e
	}
	if e := i.chroot(ctx, "hwclock", "--systohc"); e != nil {
		return e
	}
	if e := i.modify(i.Target+"/etc/locale.gen", func(s string) string { return strings.ReplaceAll(s, "#en_US.UTF-8 UTF-8", "en_US.UTF-8 UTF-8") }); e != nil {
		return e
	}
	if e := i.chroot(ctx, "locale-gen"); e != nil {
		return e
	}
	for _, f := range []struct{ p, s string }{{"locale.conf", "LANG=en_US.UTF-8\n"}, {"vconsole.conf", "KEYMAP=" + a.Keyboard.Keymap + "\n"}, {"hostname", a.Hostname + "\n"}, {"hosts", "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   " + a.Hostname + ".localdomain " + a.Hostname + "\n"}} {
		if e := i.write(i.Target+"/etc/"+f.p, f.s, 0644); e != nil {
			return e
		}
	}
	return nil
}
func (i *Installer) CheckTargetUsername(ctx context.Context) error {
	if i.Dry {
		return nil
	}
	for {
		used, e := i.targetNames()
		if e != nil {
			return e
		}
		if !used {
			return nil
		}
		if i.UI == nil {
			return fmt.Errorf("target account/group already exists")
		}
		if e = i.UI.Drain(); e != nil {
			return e
		}
		if e = i.UI.Notice(ctx, "Installed packages already use account/group "+i.Plan.Answers.Username+". Choose another username."); e != nil {
			return e
		}
		i.UI.Screen("Let's setup your user account...", "")
		name, e := i.AskUsername(ctx)
		if e != nil {
			return e
		}
		i.Plan.Answers.Username = name
	}
}
func (i *Installer) CreateUser(ctx context.Context) error {
	a := i.Plan.Answers
	if e := plan.Username(a.Username); e != nil {
		return e
	}
	if e := plan.Password(a.Password); e != nil {
		return e
	}
	if !i.Dry {
		used, e := i.targetNames()
		if e != nil {
			return e
		}
		if used {
			return fmt.Errorf("target account/group appeared before useradd; refusing to modify it")
		}
	}
	if e := i.chroot(ctx, "useradd", "-m", "-G", "wheel", "-s", "/usr/bin/fish", a.Username); e != nil {
		return e
	}
	if i.Dry {
		fmt.Fprintln(i.Out, "(password via stdin, never logged) | arch-chroot "+i.Target+" chpasswd")
	} else {
		c := run.C("arch-chroot", i.Target, "chpasswd")
		c.Stdin = strings.NewReader(a.Username + ":" + a.Password + "\n")
		c.Secret = true
		if _, e := i.Runner.Run(ctx, c); e != nil {
			return e
		}
	}
	i.Plan.Answers.Password = ""
	if e := i.chroot(ctx, "passwd", "-l", "root"); e != nil {
		return e
	}
	if e := i.write(i.Target+"/etc/sudoers.d/10-wheel", "%wheel ALL=(ALL:ALL) ALL\n", 0440); e != nil {
		return e
	}
	return i.chroot(ctx, "visudo", "-cf", "/etc/sudoers.d/10-wheel")
}
func (i *Installer) TuneSystem(ctx context.Context) error {
	if i.Bootstrap {
		// The settings scriptlet sets the capability; shell owns fish startup.
		return nil
	}
	if e := i.chroot(ctx, "setcap", "cap_sys_nice=ep", "/usr/bin/Hyprland"); e != nil {
		return e
	}
	s := "arch-chroot starship init fish --print-full-init\n"
	if !i.Dry {
		var e error
		s, e = i.Runner.Run(ctx, run.C("arch-chroot", i.Target, "starship", "init", "fish", "--print-full-init"))
		if e != nil {
			return e
		}
	}
	return i.write(i.Target+"/etc/fish/conf.d/starship.fish", s, 0644)
}
func (i *Installer) BuildInitramfs(ctx context.Context) error {
	return i.chroot(ctx, "mkinitcpio", "-p", i.Plan.Kernel)
}
func (i *Installer) InstallBootloader(ctx context.Context) error {
	// GRUB discovers vmlinuz-* and matching initramfs files. Refuse a successful
	// install with only an unrelated (for example, live ISO) kernel present.
	if !i.Dry {
		for _, file := range []string{"vmlinuz-" + i.Plan.Kernel, "initramfs-" + i.Plan.Kernel + ".img"} {
			if !i.FS.Exists(i.Target + "/boot/" + file) {
				return fmt.Errorf("missing boot image for installed kernel: %s", file)
			}
		}
	}
	if e := i.chroot(ctx, "grub-install", "--target=x86_64-efi", "--efi-directory=/boot/efi", "--bootloader-id=Gilgamesh"); e != nil {
		return e
	}
	for _, v := range [][2]string{{"GRUB_TIMEOUT", "0"}, {"GRUB_TIMEOUT_STYLE", "hidden"}, {"GRUB_CMDLINE_LINUX_DEFAULT", `"quiet loglevel=3 nowatchdog zswap.enabled=0"`}, {"GRUB_DISTRIBUTOR", `"Gilgamesh"`}} {
		if e := i.set(i.Target+"/etc/default/grub", v[0], v[1]); e != nil {
			return e
		}
	}
	return i.chroot(ctx, "grub-mkconfig", "-o", "/boot/grub/grub.cfg")
}
func (i *Installer) EnableServices(ctx context.Context) error {
	if e := i.chroot(ctx, "systemctl", "enable", "NetworkManager.service", "systemd-resolved.service", "systemd-timesyncd.service", "ufw.service", "fstrim.timer", "rtkit-daemon.service", "ly@tty2.service"); e != nil {
		return e
	}
	if e := i.chroot(ctx, "systemctl", "disable", "getty@tty2.service"); e != nil {
		return e
	}
	return i.set(i.Target+"/etc/ufw/ufw.conf", "ENABLED", "yes")
}
func (i *Installer) UserConfig(ctx context.Context) error {
	a := i.Plan.Answers
	cfg := i.Target + "/home/" + a.Username + "/.config"
	if e := i.x(ctx, "mkdir", "-p", cfg+"/hypr", cfg+"/fish/conf.d", cfg+"/foot", cfg+"/mpv"); e != nil {
		return e
	}
	if i.Bootstrap {
		// Packaged Hyprland defaults load require("local") last. Keep that lookup
		// in the user's config directory while loading all defaults from /usr.
		s := "local config = os.getenv(\"XDG_CONFIG_HOME\") or (os.getenv(\"HOME\") .. \"/.config\")\npackage.path = config .. \"/hypr/?.lua;\" .. package.path\ndofile(\"/usr/share/gilgamesh/hypr/hyprland.lua\")\n"
		if e := i.write(cfg+"/hypr/hyprland.lua", s, 0644); e != nil {
			return e
		}
	} else {
		for _, c := range []run.Command{run.C("cp", "-r", i.Src+"/quickshell", cfg+"/quickshell"), run.C("cp", i.Src+"/hypr/hyprland.lua", cfg+"/hypr/hyprland.lua"), run.C("cp", i.Src+"/fish/colors.fish", i.Src+"/fish/prompt.fish", i.Src+"/fish/greeting.fish", cfg+"/fish/conf.d/"), run.C("cp", i.Src+"/fish/starship.toml", cfg+"/starship.toml")} {
			if e := i.x(ctx, c.Name, c.Args...); e != nil {
				return e
			}
		}
	}
	for _, v := range [][2]string{{"hypr/local.lua", plan.HyprLocal(a.Keyboard)}, {"foot/foot.ini", "include=~/.local/state/gilgamesh/theme/foot.ini\nfont=JetBrainsMono Nerd Font:size=12\n"}, {"mpv/mpv.conf", "hwdec=auto-safe\n"}} {
		if e := i.write(cfg+"/"+v[0], v[1], 0644); e != nil {
			return e
		}
	}
	return i.chroot(ctx, "chown", "-R", a.Username+":", "/home/"+a.Username)
}
func (i *Installer) LinkResolvConf(ctx context.Context) error {
	return i.x(ctx, "ln", "-sf", "../run/systemd/resolve/stub-resolv.conf", i.Target+"/etc/resolv.conf")
}
