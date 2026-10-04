package plan

import (
	"reflect"
	"strings"
	"testing"
)

func TestUsername(t *testing.T) {
	// Account names here are synthetic validation inputs.
	for _, c := range []struct {
		s  string
		ok bool
	}{{"enkidu", true}, {"_test-2", true}, {strings.Repeat("a", 32), true}, {strings.Repeat("a", 33), false}, {"Enkidu", false}, {"1user", false}, {"", false}, {"a:b", false}, {"root", false}, {"wheel", false}, {"rtkit", false}, {"systemd-new", false}, {"nvidia-persistenced", false}, {"a\n", false}} {
		t.Run(c.s, func(t *testing.T) {
			if (Username(c.s) == nil) != c.ok {
				t.Fatal(c)
			}
		})
	}
}
func TestNameInUse(t *testing.T) {
	for _, db := range []string{"enkidu:x:1:1", "root:x:0\nenkidu:x:1000:"} {
		if !NameInUse("enkidu", db) {
			t.Fatal(db)
		}
	}
	if NameInUse("enkidu", "enkidux:x:1:") {
		t.Fatal("prefix matched")
	}
}
func TestHostname(t *testing.T) {
	for _, s := range []string{"gilgamesh", "vm-1", "a", strings.Repeat("a", 63)} {
		if Hostname(s) != nil {
			t.Fatal(s)
		}
	}
	for _, s := range []string{"-vm", "vm-", "UPPER", "a.b", "", strings.Repeat("a", 64), "a\n"} {
		if Hostname(s) == nil {
			t.Fatal(s)
		}
	}
}
func TestPassword(t *testing.T) {
	for _, s := range []string{"", "p\nroot:x", "p\x00", "p\r"} {
		if Password(s) == nil {
			t.Fatal("accepted invalid password")
		}
	}
	if Password("pa ss$w0rd:") != nil {
		t.Fatal("valid password rejected")
	}
}
func TestPackages(t *testing.T) {
	// Synthetic PCI/CPU combinations cover the driver and microcode branches.
	for _, c := range []struct {
		name, pci, cpu string
		nv, old        bool
		micro          string
	}{{"AMD Turing", "VGA [0300]: GPU [10de:1e00]", "vendor_id : AuthenticAMD", true, false, "amd-ucode"}, {"Intel Ampere", "3D [0302] GPU [10DE:2206]", "vendor_id : GenuineIntel", true, false, "intel-ucode"}, {"old", "VGA [0300] [10de:1b80]", "", false, true, ""}, {"mixed", "VGA [0300] [10de:2206]\n3D [0302] [10de:1b80]", "", false, true, ""}, {"audio", "Audio [0403] [10de:2206]", "", false, false, ""}, {"none", "", "vendor_id : Other", false, false, ""}} {
		t.Run(c.name, func(t *testing.T) {
			p := Build(Answers{Disk: "/dev/vda"}, "linux", []string{"base", "dosfstools"}, []string{"nvidia-open-dkms"}, c.pci, c.cpu)
			want := []string{"linux", "linux-headers", "base", "dosfstools"}
			if c.micro != "" {
				want = append(want, c.micro)
			}
			if c.nv {
				want = append(want, "nvidia-open-dkms")
			}
			if p.NVIDIA != c.nv || p.OldNVIDIA != c.old || !reflect.DeepEqual(p.Packages, want) {
				t.Fatal(p)
			}
		})
	}
}
func TestFstab(t *testing.T) {
	base := "UUID=root / xfs noatime 0 1\nUUID=esp /boot/efi vfat defaults 0 2\n"
	cases := []struct {
		name, s string
		ok      bool
	}{{"valid", base, true}, {"drop swap", base + "UUID=live none swap defaults 0 0\n", true}, {"comments", "# root\n\n" + base, true}, {"extra", base + "UUID=other /data xfs defaults 0 2\n", false}, {"duplicate", base + "UUID=root / xfs defaults 0 1\n", false}, {"missing", "UUID=root / xfs defaults 0 1", false}, {"wrong UUID", strings.Replace(base, "root", "old", 1), false}, {"wrong fs", strings.Replace(base, "xfs", "ext4", 1), false}, {"malformed", base + "oops", false}}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v, e := FilterFstab(c.s, "root", "esp")
			if (e == nil) != c.ok {
				t.Fatal(v, e)
			}
			if e == nil && strings.Contains(v, "swap") {
				t.Fatal(v)
			}
		})
	}
	if _, e := FilterFstab(base, "root", "root"); e == nil {
		t.Fatal("equal UUIDs accepted")
	}
}
func TestLists(t *testing.T) {
	got, e := ReadList("# comment\nbase # foo\ndosfstools\n")
	if e != nil || !reflect.DeepEqual(got, []string{"base", "dosfstools"}) {
		t.Fatal(got, e)
	}
	for _, s := range []string{"", "# only comment", "../../bad"} {
		if _, e := ReadList(s); e == nil {
			t.Fatal(s)
		}
	}
}
func TestConfiguration(t *testing.T) {
	s := SetConf("#GRUB_TIMEOUT=5\nGRUB_OTHER=1\n", "GRUB_TIMEOUT", "0")
	if s != "GRUB_TIMEOUT=0\nGRUB_OTHER=1\n" {
		t.Fatal(s)
	}
	if Multilib("#[multilib]\n#Include = mirrorlist\n#other\n") != "[multilib]\nInclude = mirrorlist\n#other\n" {
		t.Fatal("multilib")
	}
	if len(Keyboards) != 16 || Keyboards[0].Label != "English (US)" || Keyboards[1].Label != "English (UK)" || Keyboards[2].Layout != "us,ara" || !strings.Contains(HyprLocal(Keyboards[2]), "grp:alt_shift_toggle") {
		t.Fatal("keyboard parity", Keyboards)
	}
	if s := HyprLocal(Keyboard{"English (Dvorak)", "us", "dvorak", "", "dvorak"}); !strings.Contains(s, "kb_layout = \"us\",\n        kb_variant = \"dvorak\",\n") || strings.Contains(s, "kb_options") {
		t.Fatal(s)
	}
}

// Excerpts of xkeyboard-config's base.lst and systemd's kbd-model-map.
const xkbRules = `! model
  pc105           Generic 105-key PC

! layout
  al              Albanian
  ara             Arabic
  cz              Czech
  de              German
  dk              Danish
  gb              English (UK)
  us              English (US)
  au              English (Australia)
  it              Italian
  lv              Latvian
  ru              Russian
  custom          A user-defined custom Layout

! variant
  nodeadkeys      de: German (no dead keys)
  dvorak          us: English (Dvorak)
  colemak         us: English (Colemak)
  qwerty          cz: Czech (QWERTY)
  tilde           lv: Latvian (tilde)
  apostrophe      lv: Latvian (apostrophe)

! option
  grp                  Switching to another layout
`
const kbdModelMap = `# consolelayout		xlayout	xmodel		xvariant	xoptions					bcp47
uk			gb	pc105		-		terminate:ctrl_alt_bksp				en-GB
us			us	pc105+inet	-		terminate:ctrl_alt_bksp				en-US,en
de			de	pc105		-		terminate:ctrl_alt_bksp				de-DE,de-AT,de
de-latin1		de	pc105		-		terminate:ctrl_alt_bksp				-
dk			dk	pc105		-		terminate:ctrl_alt_bksp				-
dk-latin1		dk	pc105		-		terminate:ctrl_alt_bksp				da-DK,da
it2			it	pc105		-		terminate:ctrl_alt_bksp				-
it			it	pc105		-		terminate:ctrl_alt_bksp				it-IT,it-CH,it
cz-qwerty		cz,us	pc105		qwerty,		terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll	-
cz-lat2			cz	pc105		qwerty		terminate:ctrl_alt_bksp				-
dvorak			us	pc105		dvorak		terminate:ctrl_alt_bksp				-
de-latin1-nodeadkeys	de	pc105		nodeadkeys	terminate:ctrl_alt_bksp				-
ru			ru,us	pc105		-		terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll	ru-RU,ru
lv			lv	pc105		apostrophe	terminate:ctrl_alt_bksp				lv-LV,lv
lv-tilde		lv	pc105		tilde		terminate:ctrl_alt_bksp				-
ara			ara,us	pc105		-		terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll	ar-SA,ar
`

func TestParseKeyboards(t *testing.T) {
	k := ParseKeyboards(xkbRules, kbdModelMap)
	var labels []string
	for _, v := range k {
		labels = append(labels, v.Label)
	}
	// English (US) and (UK) lead, the other English layouts follow, then A to Z.
	// Colemak has no console keymap in systemd's map, so it is not offered.
	want := []string{"English (US)", "English (UK)", "English (Australia)", "English (Dvorak)", "Albanian", "Arabic", "Czech", "Czech (QWERTY)", "Danish", "German", "German (no dead keys)", "Italian", "Latvian", "Latvian (apostrophe)", "Latvian (tilde)", "Russian"}
	if !reflect.DeepEqual(labels, want) {
		t.Fatalf("got %q\nwant %q", labels, want)
	}
	byLabel := map[string]Keyboard{}
	for _, v := range k {
		byLabel[v.Label] = v
	}
	for label, want := range map[string]Keyboard{
		"English (US)":          {"English (US)", "us", "", "", "us"},
		"English (UK)":          {"English (UK)", "gb", "", "", "uk"},
		"English (Australia)":   {"English (Australia)", "au", "", "", "us"}, // no systemd mapping
		"English (Dvorak)":      {"English (Dvorak)", "us", "dvorak", "", "dvorak"},
		"Albanian":              {"Albanian", "al", "", "", "us"},
		"Arabic":                {"Arabic", "ara,us", "", "grp:shifts_toggle,grp_led:scroll", "ara"},
		"Czech (QWERTY)":        {"Czech (QWERTY)", "cz,us", "qwerty,", "grp:shifts_toggle,grp_led:scroll", "cz-qwerty"},
		"Danish":                {"Danish", "dk", "", "", "dk-latin1"}, // the tagged row beats the alias
		"German":                {"German", "de", "", "", "de"},
		"German (no dead keys)": {"German (no dead keys)", "de", "nodeadkeys", "", "de-latin1-nodeadkeys"},
		"Italian":               {"Italian", "it", "", "", "it"},
		"Latvian":               {"Latvian", "lv", "apostrophe", "", "lv"}, // systemd knows no plain Latvian keymap
		"Russian":               {"Russian", "ru,us", "", "grp:shifts_toggle,grp_led:scroll", "ru"},
	} {
		if got := byLabel[label]; got != want {
			t.Errorf("%s: got %+v want %+v", label, got, want)
		}
	}
	if ParseKeyboards("! model\n  pc105 Generic\n", kbdModelMap) != nil || ParseKeyboards("", "") != nil {
		t.Fatal("rules without layouts must fall back")
	}
	if got := ParseKeyboards(xkbRules, ""); got[0].Keymap != "us" || len(got) != 11 {
		t.Fatal("without kbd-model-map every layout keeps the us console keymap", got)
	}
}

func TestDiskPlan(t *testing.T) {
	p := Build(Answers{Disk: "/dev/nvme0n1"}, "linux", []string{"base"}, nil, "", "")
	if !reflect.DeepEqual(p.Partitions, []Partition{{"/dev/nvme0n1p1", "1 GiB", "ef00", "EFI"}, {"/dev/nvme0n1p2", "remaining", "8304", "gilgamesh"}}) {
		t.Fatal(p.Partitions)
	}
	if !reflect.DeepEqual(p.Formats[1], Format{"mkfs.xfs", []string{"-f", "-L", "gilgamesh", "-m", "rmapbt=0", "-n", "parent=0", "/dev/nvme0n1p2"}}) {
		t.Fatal(p.Formats)
	}
	if !reflect.DeepEqual(p.RootMountOptions, []string{"-o", "noatime"}) {
		t.Fatal(p.RootMountOptions)
	}
}
