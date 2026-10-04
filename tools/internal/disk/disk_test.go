package disk

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/testkit"
)

func fixture(name string) (Inventory, State) {
	p := Part(name, 1)
	return Inventory{{Name: name, Type: "disk", Size: 60e9}, {Name: p, Parent: name, Type: "part", Size: 1e9}}, State{Holders: map[string][]string{name: {}, p: {}}, Protected: map[string]bool{}}
}
func TestSelection(t *testing.T) {
	for _, name := range []string{"/dev/sda", "/dev/nvme0n1", "/dev/mmcblk0", "/dev/vda"} {
		t.Run(name, func(t *testing.T) {
			i, s := fixture(name)
			got, e := Select(i, name, s)
			want := []string{Part(name, 1), name}
			if e != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("%v %v", got, e)
			}
		})
	}
}
func TestRefusals(t *testing.T) {
	cases := []struct {
		name   string
		change func(*Inventory, *State)
	}{
		{"md holder", func(i *Inventory, s *State) { s.Holders["/dev/vda1"] = []string{"md0"} }},
		{"LVM", func(i *Inventory, s *State) {
			*i = append(*i, Node{Name: "/dev/dm-0", Type: "lvm", Parent: "/dev/vda1"})
		}},
		{"crypt", func(i *Inventory, s *State) {
			*i = append(*i, Node{Name: "/dev/mapper/crypt", Type: "crypt", Parent: "/dev/vda"})
		}},
		{"mounted partition", func(i *Inventory, s *State) { (*i)[1].Mounts = []string{"/home"} }},
		{"mounted disk", func(i *Inventory, s *State) { (*i)[0].Mounts = []string{"/"} }},
		{"swap", func(i *Inventory, s *State) { s.Swap = []string{"/dev/vda1"} }},
		{"read only", func(i *Inventory, s *State) { (*i)[0].ReadOnly = true }},
		{"read only partition", func(i *Inventory, s *State) { (*i)[1].ReadOnly = true }},
		{"too small", func(i *Inventory, s *State) { (*i)[0].Size = MinBytes - 1 }},
		{"live", func(i *Inventory, s *State) { s.Protected["/dev/vda"] = true }},
		{"unreadable holders", func(i *Inventory, s *State) { delete(s.Holders, "/dev/vda1") }},
		{"partition target", func(i *Inventory, s *State) { (*i)[0].Type = "part" }},
		{"missing", func(i *Inventory, s *State) { *i = (*i)[1:] }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			i, s := fixture("/dev/vda")
			c.change(&i, &s)
			if v, e := Select(i, "/dev/vda", s); e == nil {
				t.Fatalf("accepted: %v", v)
			}
		})
	}
}
func TestNeverSelectUnrelatedOrMapped(t *testing.T) {
	i, s := fixture("/dev/vda")
	i = append(i, Node{Name: "/dev/vdb1", Type: "part", Parent: "/dev/vdb"}, Node{Name: "/dev/dm-0", Type: "crypt", Parent: "/dev/vdb1"})
	v, e := Select(i, "/dev/vda", s)
	if e != nil || !reflect.DeepEqual(v, []string{"/dev/vda1", "/dev/vda"}) {
		t.Fatal(v, e)
	}
}
func TestIdentityChanges(t *testing.T) {
	base := Identity{"253:0", 60e9, "7", "", ""}
	for _, field := range []string{"major", "size", "sequence", "serial", "wwn", "sequence disappeared"} {
		t.Run(field, func(t *testing.T) {
			v := base
			switch field {
			case "major":
				v.MajorMinor = "253:1"
			case "size":
				v.Size++
			case "sequence":
				v.DiskSeq = "8"
			case "serial":
				v.Serial = "new"
			case "wwn":
				v.WWN = "new"
			case "sequence disappeared":
				v.DiskSeq = "unavailable"
			}
			if Verify(base, v) == nil {
				t.Fatal("identity change allowed")
			}
		})
	}
	if Verify(base, base) != nil {
		t.Fatal("serial-less identity rejected")
	}
}
func TestIdentityRead(t *testing.T) {
	for _, seq := range []string{"7", "missing", "invalid"} {
		t.Run(seq, func(t *testing.T) {
			f := testkit.FS(t)
			if seq != "missing" {
				testkit.Write(t, f, "/sys/block/vda/diskseq", seq)
			}
			r := &run.Fake{Handle: func(context.Context, run.Command) (string, error) { return "253:0\n", nil }}
			id, e := ReadIdentity(context.Background(), r, f, Node{Name: "/dev/vda", Size: 60e9})
			if seq == "invalid" {
				if e == nil {
					t.Fatal("accepted invalid seq")
				}
				return
			}
			if e != nil || id.Serial != "" || id.Size != 60e9 {
				t.Fatal(id, e)
			}
		})
	}
}
func TestParse(t *testing.T) {
	valid := `{"blockdevices":[{"name":"/dev/vda","type":"disk","pkname":null,"size":60000000000,"model":"Virtio","serial":null,"wwn":null,"ro":false,"mountpoints":[null],"children":[{"name":"/dev/vda1","type":"part","pkname":"/dev/vda","size":"1000000000","ro":"0","mountpoints":[null]}]}]}`
	i, e := Parse([]byte(valid))
	if e != nil || len(i) != 2 || i[0].Serial != "" {
		t.Fatal(i, e)
	}
	for _, s := range []string{"", `{}`, `{"blockdevices":[]}`, `{broken`, strings.Replace(valid, `"size":60000000000`, `"size":null`, 1), strings.Replace(valid, `"pkname":"/dev/vda"`, `"pkname":null`, 1), strings.Replace(valid, `"ro":false`, `"ro":null`, 1)} {
		t.Run(s, func(t *testing.T) {
			if _, e := Parse([]byte(s)); e == nil {
				t.Fatal("accepted malformed inventory")
			}
		})
	}
	_, _ = json.Marshal(i)
}
func TestTargetMounts(t *testing.T) {
	for _, c := range []struct {
		path string
		bad  bool
	}{{"/mnt", true}, {"/mnt/boot/efi", true}, {"/mnt2", false}, {"/", false}} {
		t.Run(c.path, func(t *testing.T) {
			if (TargetClear("/mnt", []string{c.path}) != nil) != c.bad {
				t.Fatal(c)
			}
		})
	}
}
func TestInspect(t *testing.T) {
	f := testkit.FS(t)
	i, _ := fixture("/dev/vda")
	testkit.Dir(t, f, "/sys/block/vda/holders")
	testkit.Dir(t, f, "/sys/class/block/vda1/holders")
	testkit.Write(t, f, "/proc/swaps", "Filename Type Size Used Priority\n/dev/vda1 partition 1 0 -2\n")
	testkit.Write(t, f, "/dev/vda1", "")
	s, e := Inspect(f, i, "/dev/vda")
	if e != nil || !reflect.DeepEqual(s.Swap, []string{"/dev/vda1"}) {
		t.Fatal(s, e)
	}
	if _, e = Select(i, "/dev/vda", s); e == nil {
		t.Fatal("active swap accepted")
	}
}

func TestIncompleteOrInconsistentInventory(t *testing.T) {
	for _, s := range []string{
		`{"blockdevices":[{"name":"/dev/vda","type":"disk","size":60000000000,"ro":false}]}`,
		`{"blockdevices":[{"name":"/dev/vda1","type":"part","pkname":"/dev/vda","size":1000000000,"ro":false,"mountpoints":[null]}]}`,
		`{"blockdevices":[{"name":"/dev/vda","type":"disk","size":60000000000,"ro":false,"mountpoints":[null]},{"name":"/dev/vda","type":"disk","size":60000000000,"ro":false,"mountpoints":["/home"]}]}`,
	} {
		t.Run(s, func(t *testing.T) {
			if _, e := Parse([]byte(s)); e == nil {
				t.Fatal("accepted unsafe inventory")
			}
		})
	}
}
