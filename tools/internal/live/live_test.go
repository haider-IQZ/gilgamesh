package live

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"github.com/haider-IQZ/gilgamesh/tools/internal/disk"
	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

func TestDetection(t *testing.T) {
	for _, mode := range []string{"optical", "partition", "loop sysfs", "loop losetup", "mapped multi-parent", "copy to RAM UUID", "literal glob", "unidentified ISO", "unidentified dry run", "cycle", "missing backing", "failed mount inspection", "retained"} {
		t.Run(mode, func(t *testing.T) {
			f := testkit.FS(t)
			testkit.Write(t, f, "/proc/cmdline", "quiet")
			inv := disk.Inventory{{Name: "/dev/sr0", Type: "rom"}, {Name: "/dev/sda", Type: "disk"}, {Name: "/dev/sda1", Type: "part", Parent: "/dev/sda"}, {Name: "/dev/sdb", Type: "disk"}, {Name: "/dev/loop0", Type: "loop"}, {Name: "/dev/dm-0", Type: "crypt", Parent: "/dev/sda1"}, {Name: "/dev/dm-0", Type: "crypt", Parent: "/dev/sdb"}}
			source := "/dev/sr0"
			want := map[string]bool{"/dev/sr0": true}
			bad := false
			required := true
			switch mode {
			case "partition":
				source = "/dev/sda1"
				want = map[string]bool{"/dev/sda": true}
			case "loop sysfs", "loop losetup", "missing backing":
				source = "/dev/loop0"
				want = map[string]bool{"/dev/sda": true}
				testkit.Write(t, f, "/sys/block/loop0/loop/backing_file", "/images/live\\040image.iso\n")
				if mode != "missing backing" {
					testkit.Write(t, f, "/images/live image.iso", "")
				} else {
					bad = true
				}
			case "mapped multi-parent":
				source = "/dev/dm-0"
				want = map[string]bool{"/dev/sda": true, "/dev/sdb": true}
			case "copy to RAM UUID":
				source = ""
				testkit.Write(t, f, "/proc/cmdline", "quiet archisosearchuuid=abc")
				want = map[string]bool{"/dev/sda": true}
			case "literal glob":
				source = ""
				testkit.Write(t, f, "/proc/cmdline", "archisolabel=LIVE*")
				want = map[string]bool{"/dev/sda": true}
			case "unidentified ISO":
				source = ""
				bad = true
			case "unidentified dry run":
				source = ""
				required = false
				want = map[string]bool{}
			case "cycle":
				source = "/dev/dm-0"
				inv[5].Parent = "/dev/dm-0"
				bad = true
			case "failed mount inspection":
				bad = true
			case "retained":
				source = ""
				want = map[string]bool{"/dev/sr0": true}
			}
			r := &run.Fake{Handle: func(_ context.Context, c run.Command) (string, error) {
				switch c.Name {
				case "findmnt":
					if mode == "failed mount inspection" {
						return "", run.ExitError{Code: 32}
					}
					if c.Args[1] == "-T" {
						return "/dev/sda1", nil
					}
					if c.Args[2] == "/run/archiso/bootmnt" && source != "" {
						return source, nil
					}
					return "", run.ExitError{Code: 1}
				case "losetup":
					if mode == "loop losetup" {
						return "/images/live\\040image.iso", nil
					}
					return "", run.ExitError{Code: 1}
				case "findfs":
					expected := "UUID=abc"
					if mode == "literal glob" {
						expected = "LABEL=LIVE*"
					}
					if !reflect.DeepEqual(c.Args, []string{expected}) {
						t.Fatalf("boot parameter altered: %q", c.Args)
					}
					return "/dev/sda1", nil
				}
				return "", fmt.Errorf("unexpected command %s", run.Show(c))
			}}
			d := Detector{Runner: r, FS: f}
			if mode == "retained" {
				d.Retained = want
			}
			got, e := d.Detect(context.Background(), inv, required)
			if (e != nil) != bad {
				t.Fatalf("%v %v", got, e)
			}
			if !bad && !reflect.DeepEqual(got, want) {
				t.Fatalf("got %v want %v", got, want)
			}
		})
	}
}
