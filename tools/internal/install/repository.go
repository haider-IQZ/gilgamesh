package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/haider-IQZ/gilgamesh/tools/internal/plan"
)

const bootstrapDB = "/opt/gilgamesh/repo/gilgamesh.db"

func (i *Installer) note(s string) {
	fmt.Fprintln(i.Out, s)
	if i.Log != nil {
		fmt.Fprintln(i.Log, s)
	}
}

// temporaryFile returns a logical path usable by Runner, including in fixtures.
// Dry runs preview the file without allocating anything on the live filesystem.
func (i *Installer) temporaryFile(dir, pattern, content string) (string, error) {
	p := filepath.Join(dir, strings.Replace(pattern, "*", "preview", 1))
	if !i.Dry {
		if e := os.MkdirAll(i.FS.Path(dir), 0755); e != nil {
			return "", e
		}
		f, e := os.CreateTemp(i.FS.Path(dir), pattern)
		if e != nil {
			return "", e
		}
		p = filepath.Join(dir, filepath.Base(f.Name()))
		if e = f.Close(); e != nil {
			return "", errors.Join(e, i.FS.Remove(p))
		}
	}
	if e := i.write(p, content, 0600); e != nil {
		return "", errors.Join(e, i.FS.Remove(p))
	}
	return p, nil
}

func (i *Installer) InstallPackages(ctx context.Context) (err error) {
	args := []string{"-K"}
	if i.Bootstrap {
		i.note("Using local Gilgamesh bootstrap repository: linux-tkg and packaged settings/shell.")
		b, e := i.FS.Read("/etc/pacman.conf")
		if e != nil {
			return e
		}
		conf := plan.Repository(plan.Multilib(string(b)), plan.BootstrapRepository)
		p, e := i.temporaryFile("/tmp", "gilgamesh-pacman-*.conf", conf)
		if e != nil {
			return e
		}
		defer func() { err = errors.Join(err, i.FS.Remove(p)) }()
		args = append(args, "-C", p)
	} else {
		i.note("Local Gilgamesh bootstrap repository absent; using checkout fallback with kernel " + i.Plan.Kernel + ".")
	}
	args = append(args, i.Target)
	return i.x(ctx, "pacstrap", append(args, i.Plan.Packages...)...)
}

func (i *Installer) ConfigureRepository(ctx context.Context) error {
	// Sanitize before importing the key, so a failed import cannot leave an
	// unsigned bootstrap section or an enabled but untrusted published repo.
	p := i.Target + "/etc/pacman.conf"
	if e := i.modify(p, plan.TargetPacman); e != nil {
		return e
	}
	key := i.Src + "/keys/gilgamesh.asc"
	if !i.FS.Exists(key) {
		i.note("No keys/gilgamesh.asc in checkout; target [gilgamesh] repository disabled. Gilgamesh package updates require the public signing key and signed repository.")
		return nil
	}
	if e := i.trustRepositoryKey(ctx, key); e != nil {
		return e
	}
	if i.Dry {
		i.note("Would enable the signed published repository after successful key import and local signing.")
	} else {
		i.note("Public Gilgamesh key imported and locally signed; enabling the signed published repository.")
	}
	return i.modify(p, func(s string) string { return plan.Repository(s, plan.PublishedRepository) })
}

func (i *Installer) trustRepositoryKey(ctx context.Context, source string) (err error) {
	b, e := i.FS.Read(source)
	if e != nil {
		return e
	}
	// arch-chroot may mount a fresh /tmp; keep the input outside transient mounts.
	p, e := i.temporaryFile(i.Target+"/etc/pacman.d", "gilgamesh-key-*.asc", string(b))
	if e != nil {
		return e
	}
	defer func() { err = errors.Join(err, i.FS.Remove(p)) }()
	key := strings.TrimPrefix(p, i.Target)
	if i.Dry {
		i.note("Would inspect the public certificate and run target pacman-key --add and --lsign-key for its primary fingerprints.")
		return nil
	}
	s, e := i.read(ctx, "arch-chroot", i.Target, "gpg", "--batch", "--homedir", "/etc/pacman.d/gnupg", "--with-colons", "--show-keys", key)
	if e != nil {
		return e
	}
	fingerprints, e := publicFingerprints(s)
	if e != nil {
		return e
	}
	if e = i.chroot(ctx, "pacman-key", "--add", key); e != nil {
		return e
	}
	return i.chroot(ctx, "pacman-key", append([]string{"--lsign-key"}, fingerprints...)...)
}

var fingerprint = regexp.MustCompile(`^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$`)

func publicFingerprints(s string) ([]string, error) {
	var out []string
	primary := false
	for _, l := range strings.Split(s, "\n") {
		f := strings.Split(l, ":")
		switch f[0] {
		case "sec", "ssb":
			return nil, fmt.Errorf("keys/gilgamesh.asc must contain only public certificates")
		case "pub":
			primary = true
		case "sub":
			primary = false
		case "fpr":
			if primary {
				if len(f) < 10 || !fingerprint.MatchString(f[9]) {
					return nil, fmt.Errorf("invalid repository key fingerprint")
				}
				out = append(out, f[9])
				primary = false
			}
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no public key fingerprints in keys/gilgamesh.asc")
	}
	return out, nil
}
