package plan

import (
	"sort"
	"strings"
)

// Keyboards is the offline fallback when the live system has no XKB rules.
var Keyboards = SortKeyboards([]Keyboard{
	{"English (US)", "us", "", "", "us"},
	{"English (UK)", "gb", "", "", "uk"},
	{"German", "de", "", "", "de-latin1"},
	{"French", "fr", "", "", "fr-latin1"},
	{"Spanish", "es", "", "", "es"},
	{"Italian", "it", "", "", "it"},
	{"Portuguese", "pt", "", "", "pt-latin1"},
	{"Portuguese (Brazil)", "br", "", "", "br-abnt2"},
	{"Russian + English (Alt+Shift switches)", "us,ru", "", "grp:alt_shift_toggle", "us"},
	{"Arabic + English (Alt+Shift switches)", "us,ara", "", "grp:alt_shift_toggle", "us"},
	{"Turkish", "tr", "", "", "trq"},
	{"Polish", "pl", "", "", "pl"},
	{"Swedish", "se", "", "", "sv-latin1"},
	{"Norwegian", "no", "", "", "no-latin1"},
	{"Danish", "dk", "", "", "dk-latin1"},
	{"Japanese", "jp", "", "", "jp106"},
})

// The two files ParseKeyboards reads on the live system.
const (
	XKBRules    = "/usr/share/X11/xkb/rules/base.lst"
	KbdModelMap = "/usr/share/systemd/kbd-model-map"
)

// keymapRow is one line of systemd's kbd-model-map: the console keymap that
// localectl pairs with an X11 layout/variant/options triple.
type keymapRow struct {
	keymap, layout, variant, options string
	tagged                           bool // carries BCP 47 tags: systemd's canonical row for its layout
}

func first(list string) string {
	v, _, _ := strings.Cut(list, ",")
	return v
}
func parseKbdModelMap(s string) []keymapRow {
	var rows []keymapRow
	for _, l := range strings.Split(s, "\n") {
		f := strings.Fields(l)
		if len(f) < 5 || strings.HasPrefix(f[0], "#") {
			continue
		}
		r := keymapRow{keymap: f[0], layout: f[1], variant: f[3], options: f[4], tagged: len(f) >= 6 && f[5] != "-"}
		if r.variant == "-" {
			r.variant = ""
		}
		// X servers kill the session on this chord; Hyprland does not implement it.
		var opts []string
		for _, o := range strings.Split(r.options, ",") {
			if o != "" && o != "-" && o != "terminate:ctrl_alt_bksp" {
				opts = append(opts, o)
			}
		}
		r.options = strings.Join(opts, ",")
		rows = append(rows, r)
	}
	return rows
}

// consoleRow picks the kbd-model-map row for an XKB layout and variant (which
// may be empty). Variant-free rows serve a plain layout; tagged rows beat the
// legacy aliases systemd lists next to them.
func consoleRow(rows []keymapRow, layout, variant string) (keymapRow, bool) {
	best, bestScore := keymapRow{}, -1
	for _, r := range rows {
		if first(r.layout) != layout {
			continue
		}
		score := 0
		switch {
		case variant == "" && r.variant == "":
			score = 4
		case variant == "" && first(r.variant) == "":
			score = 2
		case variant != "" && first(r.variant) == variant:
			score = 2
		case variant == "": // systemd only knows this layout with a variant
			score = 1
		default:
			continue
		}
		if r.tagged {
			score++
		}
		if score > bestScore {
			best, bestScore = r, score
		}
	}
	return best, bestScore >= 0
}

// ParseKeyboards lists every layout in xkeyboard-config's base.lst plus the
// variants systemd knows a console keymap for, each paired with its console
// keymap through kbd-model-map ("us" when systemd has no mapping). Where
// systemd pairs a non-Latin layout with a second one and a group toggle, the
// pair is kept, so the console and Hyprland agree. The result is in
// SortKeyboards order, or nil when the rules file lists no layouts.
func ParseKeyboards(baseLst, kbdModelMap string) []Keyboard {
	rows := parseKbdModelMap(kbdModelMap)
	section := ""
	var codes []string
	labels := map[string]string{}
	variants := map[[2]string]string{}
	for _, l := range strings.Split(baseLst, "\n") {
		if strings.HasPrefix(l, "!") {
			section = strings.TrimSpace(l[1:])
			continue
		}
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		switch section {
		case "layout":
			if f[0] != "custom" {
				labels[f[0]] = strings.Join(f[1:], " ")
				codes = append(codes, f[0])
			}
		case "variant":
			if len(f) >= 3 && strings.HasSuffix(f[1], ":") {
				variants[[2]string{strings.TrimSuffix(f[1], ":"), f[0]}] = strings.Join(f[2:], " ")
			}
		}
	}
	if len(codes) == 0 {
		return nil
	}
	var out []Keyboard
	for _, code := range codes {
		k := Keyboard{Label: labels[code], Layout: code, Keymap: "us"}
		if r, ok := consoleRow(rows, code, ""); ok {
			k = Keyboard{labels[code], r.layout, r.variant, r.options, r.keymap}
		}
		out = append(out, k)
	}
	seen := map[[2]string]bool{}
	for _, r := range rows {
		key := [2]string{first(r.layout), first(r.variant)}
		label, ok := variants[key]
		if !ok || seen[key] {
			continue
		}
		seen[key] = true
		r, _ = consoleRow(rows, key[0], key[1])
		out = append(out, Keyboard{label, r.layout, r.variant, r.options, r.keymap})
	}
	return SortKeyboards(out)
}

// SortKeyboards puts English (US) and English (UK) first, the other English
// layouts next, then everything else alphabetically, so the default and its
// relatives open the list however long it grows.
func SortKeyboards(k []Keyboard) []Keyboard {
	rank := func(k Keyboard) int {
		switch {
		case k.Label == "English (US)":
			return 0
		case k.Label == "English (UK)":
			return 1
		case strings.HasPrefix(k.Label, "English"):
			return 2
		}
		return 3
	}
	sort.SliceStable(k, func(a, b int) bool {
		if ra, rb := rank(k[a]), rank(k[b]); ra != rb {
			return ra < rb
		}
		return k[a].Label < k[b].Label
	})
	return k
}
