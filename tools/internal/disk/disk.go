// Package disk separates block graph decisions from Linux inventory collection.
package disk

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"

	run "github.com/haider-IQZ/gilgamesh/tools/internal/exec"
	"github.com/haider-IQZ/gilgamesh/tools/internal/fsys"
)

const MinBytes uint64 = 40_000_000_000
const Columns = "NAME,TYPE,PKNAME,SIZE,MODEL,SERIAL,WWN,MOUNTPOINTS,RO"

type Node struct {
	Name, Type, Parent, Model, Serial, WWN string
	Size                                   uint64
	ReadOnly                               bool
	Mounts                                 []string
}
type Inventory []Node

func number(b json.RawMessage) (uint64, error) {
	s := strings.Trim(string(b), `"`)
	return strconv.ParseUint(s, 10, 64)
}
func Parse(b []byte) (Inventory, error) {
	type raw struct {
		Name     string            `json:"name"`
		Type     string            `json:"type"`
		Parent   string            `json:"pkname"`
		Size     json.RawMessage   `json:"size"`
		Model    string            `json:"model"`
		Serial   string            `json:"serial"`
		WWN      string            `json:"wwn"`
		Mounts   json.RawMessage   `json:"mountpoints"`
		RO       json.RawMessage   `json:"ro"`
		Children []json.RawMessage `json:"children"`
	}
	var root struct {
		Devices []json.RawMessage `json:"blockdevices"`
	}
	if e := json.Unmarshal(b, &root); e != nil {
		return nil, e
	}
	if len(root.Devices) == 0 {
		return nil, fmt.Errorf("empty block inventory")
	}
	var out Inventory
	var walk func(json.RawMessage) error
	walk = func(b json.RawMessage) error {
		var r raw
		if e := json.Unmarshal(b, &r); e != nil {
			return e
		}
		size, e := number(r.Size)
		if e != nil {
			return fmt.Errorf("invalid size for %s", r.Name)
		}
		if !device(r.Name) || r.Type == "" || (r.Type == "part" && !device(r.Parent)) {
			return fmt.Errorf("invalid block inventory node %q", r.Name)
		}
		ro := string(r.RO)
		if ro != "true" && ro != "false" && ro != "0" && ro != "1" && ro != `"0"` && ro != `"1"` {
			return fmt.Errorf("invalid RO for %s", r.Name)
		}
		var mounts []string
		if len(r.Mounts) == 0 || string(r.Mounts) == "null" {
			return fmt.Errorf("missing mountpoints for %s", r.Name)
		}
		if e := json.Unmarshal(r.Mounts, &mounts); e != nil {
			return e
		}
		node := Node{r.Name, r.Type, r.Parent, r.Model, r.Serial, r.WWN, size, ro == "true" || ro == "1" || ro == `"1"`, mounts}
		for _, old := range out {
			if old.Name == node.Name {
				same := old
				same.Parent = node.Parent
				if !reflect.DeepEqual(same, node) || (old.Parent != node.Parent && (node.Type == "part" || node.Type == "disk")) {
					return fmt.Errorf("inconsistent repeated block node %s", node.Name)
				}
			}
		}
		out = append(out, node)
		for _, c := range r.Children {
			if e := walk(c); e != nil {
				return e
			}
		}
		return nil
	}
	for _, r := range root.Devices {
		if e := walk(r); e != nil {
			return nil, e
		}
	}
	for _, n := range out {
		if n.Parent != "" {
			if _, ok := out.Get(n.Parent); !ok {
				return nil, fmt.Errorf("missing parent %s for %s", n.Parent, n.Name)
			}
		}
	}
	return out, nil
}
func device(s string) bool {
	return strings.HasPrefix(s, "/dev/") && filepath.Clean(s) == s && !strings.ContainsAny(s, "\n\r\t ")
}
func Read(ctx context.Context, r run.Runner) (Inventory, error) {
	s, e := r.Run(ctx, run.C("lsblk", "-J", "-b", "-p", "-o", Columns))
	if e != nil {
		return nil, e
	}
	return Parse([]byte(s))
}
func (i Inventory) Get(name string) (Node, bool) {
	for _, n := range i {
		if n.Name == name {
			return n, true
		}
	}
	return Node{}, false
}

type State struct {
	Holders      map[string][]string
	Swap         []string
	Protected    map[string]bool
	MountTargets []string
}

// Select returns only immediate TYPE=part children, followed by the whole disk.
// Mapped children are a refusal, never a wipe target.
func Select(i Inventory, name string, s State) ([]string, error) {
	n, ok := i.Get(name)
	if !ok || n.Type != "disk" || strings.HasPrefix(name, "/dev/zram") {
		return nil, fmt.Errorf("%s is not a whole install disk", name)
	}
	if n.Size < MinBytes {
		return nil, fmt.Errorf("%s needs at least 40 GB", name)
	}
	if s.Protected[name] {
		return nil, fmt.Errorf("%s backs the live medium", name)
	}
	var nodes []string
	seen := map[string]bool{}
	for _, p := range i {
		if p.Type == "part" && p.Parent == name && !seen[p.Name] {
			nodes = append(nodes, p.Name)
			seen[p.Name] = true
		}
	}
	nodes = append(nodes, name)
	for _, p := range nodes {
		n, _ := i.Get(p)
		if n.ReadOnly {
			return nil, fmt.Errorf("%s is read-only", p)
		}
		for _, m := range n.Mounts {
			if m != "" {
				return nil, fmt.Errorf("%s is mounted or active swap (%s)", p, m)
			}
		}
		h, ok := s.Holders[p]
		if !ok {
			return nil, fmt.Errorf("cannot inspect holders for %s", p)
		}
		if len(h) > 0 {
			return nil, fmt.Errorf("%s has active holder %s (md, LVM or crypt)", p, h[0])
		}
		for _, c := range i {
			if c.Parent == p && c.Type != "part" {
				return nil, fmt.Errorf("%s has active mapped descendant %s", p, c.Name)
			}
		}
		for _, v := range s.Swap {
			if v == p {
				return nil, fmt.Errorf("%s is active swap", p)
			}
		}
	}
	return nodes, nil
}
func TargetClear(target string, mounts []string) error {
	for _, m := range mounts {
		if m == target || strings.HasPrefix(m, target+"/") {
			return fmt.Errorf("unrelated mount at %s; unmount it yourself before installing", m)
		}
	}
	return nil
}
func Inspect(f fsys.FS, i Inventory, name string) (State, error) {
	s := State{Holders: map[string][]string{}}
	for _, n := range i {
		if n.Name != name && !(n.Type == "part" && n.Parent == name) {
			continue
		}
		p := "/sys/class/block/" + filepath.Base(n.Name) + "/holders"
		if n.Name == name {
			p = "/sys/block/" + filepath.Base(name) + "/holders"
		}
		entries, e := os.ReadDir(f.Path(p))
		if e != nil {
			return s, e
		}
		s.Holders[n.Name] = []string{}
		for _, v := range entries {
			s.Holders[n.Name] = append(s.Holders[n.Name], v.Name())
		}
	}
	b, e := f.Read("/proc/swaps")
	if e != nil {
		return s, e
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) == 0 || !strings.HasPrefix(lines[0], "Filename") {
		return s, fmt.Errorf("invalid swap inventory")
	}
	for _, l := range lines[1:] {
		v := strings.Fields(l)
		if len(v) == 0 {
			continue
		}
		p := Unescape(v[0])
		resolved, e := f.Resolve(p)
		if e != nil {
			return s, fmt.Errorf("cannot resolve active swap %s: %w", p, e)
		}
		s.Swap = append(s.Swap, resolved)
	}
	return s, nil
}
func Unescape(s string) string {
	r := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	return r.Replace(s)
}

type Identity struct {
	MajorMinor           string
	Size                 uint64
	DiskSeq, Serial, WWN string
}

var major = regexp.MustCompile(`^[0-9]+:[0-9]+$`)

func ReadIdentity(ctx context.Context, r run.Runner, f fsys.FS, n Node) (Identity, error) {
	s, e := r.Run(ctx, run.C("lsblk", "-dnpo", "MAJ:MIN", n.Name))
	if e != nil {
		return Identity{}, e
	}
	s = strings.TrimSpace(s)
	if !major.MatchString(s) {
		return Identity{}, fmt.Errorf("invalid major:minor for %s", n.Name)
	}
	seq, e := f.Read("/sys/block/" + filepath.Base(n.Name) + "/diskseq")
	sequence := "unavailable"
	if e == nil {
		sequence = strings.TrimSpace(string(seq))
		if _, e = strconv.ParseUint(sequence, 10, 64); e != nil {
			return Identity{}, fmt.Errorf("invalid diskseq")
		}
	} else if !os.IsNotExist(e) {
		return Identity{}, e
	}
	return Identity{s, n.Size, sequence, n.Serial, n.WWN}, nil
}
func Verify(confirmed, current Identity) error {
	if confirmed != current {
		return fmt.Errorf("disk identity changed since confirmation; refusing to wipe")
	}
	return nil
}
func Part(name string, n int) string {
	sep := ""
	if name[len(name)-1] >= '0' && name[len(name)-1] <= '9' {
		sep = "p"
	}
	return name + sep + strconv.Itoa(n)
}
