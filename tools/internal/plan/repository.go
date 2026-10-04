package plan

import (
	"path"
	"regexp"
	"strings"
)

const BootstrapRepository = "[gilgamesh]\nSigLevel = Never\nServer = file:///opt/gilgamesh/repo\n\n"
const PublishedRepository = "[gilgamesh]\nSigLevel = Required DatabaseRequired\nServer = https://github.com/haider-IQZ/gilgamesh/releases/download/repo\n\n"

var repoSection = regexp.MustCompile(`^\s*\[([^]]+)\]\s*(#.*)?$`)

// Repository replaces every old Gilgamesh section and puts the replacement ahead
// of all other repositories, after [options]. An empty replacement removes it.
func Repository(s, section string) string {
	var lines []string
	skip, inserted := false, false
	for _, l := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		if m := repoSection.FindStringSubmatch(l); m != nil {
			name := strings.TrimSpace(m[1])
			skip = name == "gilgamesh"
			if !skip && name != "options" && !inserted {
				if section != "" {
					lines = append(lines, strings.TrimRight(section, "\n"))
				}
				inserted = true
			}
		}
		if !skip {
			lines = append(lines, l)
		}
	}
	if !inserted && section != "" {
		lines = append(lines, strings.TrimRight(section, "\n"))
	}
	return strings.Join(lines, "\n") + "\n"
}

// TargetPacman never inherits the live medium's unsigned policy. Official repo
// signature settings are preserved unless they explicitly disable verification.
func TargetPacman(s string) string {
	lines := strings.Split(Repository(Multilib(s), ""), "\n")
	for n, l := range lines {
		key, value, ok := strings.Cut(strings.SplitN(l, "#", 2)[0], "=")
		if !ok || strings.TrimSpace(key) != "SigLevel" {
			continue
		}
		for _, v := range strings.Fields(value) {
			if strings.HasSuffix(v, "Never") {
				lines[n] = "SigLevel = Required DatabaseRequired"
				break
			}
		}
	}
	return strings.Join(lines, "\n")
}

// SettingsOwns mirrors packages/gilgamesh-settings/PKGBUILD's source mappings.
// Skip sources even when the package moves their destination into /usr/lib or
// /usr/share: an /etc copy would override the vendor default on every upgrade.
func SettingsOwns(p string) bool {
	for _, pattern := range []string{
		"etc/mkinitcpio.conf.d/*.conf",
		"etc/pipewire/pipewire.conf.d/*.conf", "etc/pipewire/pipewire-pulse.conf.d/*.conf",
		"etc/wireplumber/wireplumber.conf.d/*.conf",
		"etc/sysctl.d/*.conf", "etc/udev/rules.d/*.rules", "etc/modprobe.d/*.conf",
		"etc/modules-load.d/*.conf", "etc/tmpfiles.d/*.conf", "etc/NetworkManager/conf.d/*.conf",
		"etc/systemd/journald.conf.d/*.conf", "etc/systemd/system.conf.d/*.conf",
		"etc/systemd/system/ly@.service.d/*.conf", "etc/systemd/zram-generator.conf",
		"usr/share/libalpm/hooks/*.hook", "etc/systemd/user/localsearch-3.service",
		"etc/dconf/profile/*", "etc/dconf/db/*.d/*",
		"etc/xdg-desktop-portal/*-portals.conf",
	} {
		if matched, _ := path.Match(pattern, p); matched {
			return true
		}
	}
	return false
}
