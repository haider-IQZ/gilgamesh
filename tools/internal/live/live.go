// Package live protects every physical ancestor of the running installation medium.
package live

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/haider-IQZ/gilgamesh/tools/internal/disk"
	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/fsys"
)

type Detector struct {
	Runner   run.Runner
	FS       fsys.FS
	Retained map[string]bool
}

func (d *Detector) Detect(ctx context.Context, i disk.Inventory, required bool) (map[string]bool, error) {
	if d.Retained == nil {
		d.Retained = map[string]bool{}
	}
	vis := map[string]int{}
	cmd := func(n string, args ...string) (string, error) {
		s, e := d.Runner.Run(ctx, run.C(n, args...))
		return strings.TrimSpace(s), e
	}
	var ancestors func(string) error
	ancestors = func(dev string) error {
		dev = strings.Split(dev, "[")[0]
		if _, ok := i.Get(dev); !ok {
			v, e := d.FS.Resolve(dev)
			if e != nil {
				return e
			}
			dev = v
		}
		if vis[dev] == 1 {
			return fmt.Errorf("cycle in live ancestry at %s", dev)
		}
		if vis[dev] == 2 {
			return nil
		}
		vis[dev] = 1
		found := false
		for _, n := range i {
			if n.Name != dev {
				canonical, e := d.FS.Resolve(n.Name)
				if e != nil || canonical != dev {
					continue
				}
			}
			found = true
			switch n.Type {
			case "disk", "rom":
				d.Retained[dev] = true
				d.Retained[n.Name] = true
			case "loop":
				back, e := cmd("losetup", "-n", "--raw", "-O", "BACK-FILE", dev)
				if e != nil || back == "" {
					b, e := d.FS.Read("/sys/block/" + filepath.Base(dev) + "/loop/backing_file")
					if e != nil {
						b, e = d.FS.Read("/sys/class/block/" + filepath.Base(dev) + "/loop/backing_file")
					}
					if e != nil {
						return e
					}
					back = strings.TrimSpace(string(b))
				}
				if back == "" {
					return fmt.Errorf("empty live loop backing file")
				}
				back = disk.Unescape(back)
				source := ""
				for _, p := range []string{back, "/run/archiso/img_dev/" + strings.TrimPrefix(back, "/")} {
					if !d.FS.Exists(p) {
						continue
					}
					v, e := cmd("findmnt", "-rn", "-T", p, "-o", "SOURCE")
					if e != nil {
						return e
					}
					if v != "" {
						source = v
						break
					}
				}
				if source == "" {
					return fmt.Errorf("cannot locate live ISO backing file: %s", back)
				}
				if e := ancestors(source); e != nil {
					return e
				}
			default:
				if n.Parent == "" {
					return fmt.Errorf("cannot identify physical ancestor of %s", dev)
				}
				if e := ancestors(n.Parent); e != nil {
					return e
				}
			}
		}
		if !found {
			return fmt.Errorf("live device %s missing from inventory", dev)
		}
		vis[dev] = 2
		return nil
	}
	for _, p := range []string{"/run/archiso/bootmnt", "/run/archiso/img_dev"} {
		v, e := cmd("findmnt", "-rn", "-M", p, "-o", "SOURCE")
		if e != nil && (run.Code(e) != 1 || v != "") {
			return nil, e
		}
		if v != "" {
			if e := ancestors(v); e != nil {
				return nil, e
			}
		}
	}
	b, e := d.FS.Read("/proc/cmdline")
	if e != nil {
		return nil, e
	}
	for _, t := range strings.Fields(string(b)) {
		key, v, ok := strings.Cut(t, "=")
		if !ok {
			continue
		}
		switch key {
		case "archisodevice", "img_dev":
		case "archisolabel":
			v = "LABEL=" + v
		case "archisosearchuuid":
			v = "UUID=" + v
		default:
			continue
		}
		if !strings.HasPrefix(v, "/dev/") {
			v, e = cmd("findfs", v)
			if e != nil {
				return nil, e
			}
		}
		if e := ancestors(v); e != nil {
			return nil, e
		}
	}
	if required && len(d.Retained) == 0 {
		return nil, fmt.Errorf("cannot identify the live medium's physical disks; refusing to install")
	}
	out := map[string]bool{}
	for k, v := range d.Retained {
		out[k] = v
	}
	return out, nil
}
