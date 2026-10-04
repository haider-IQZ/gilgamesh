package ui

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/sys/unix"
)

// A private pseudo-terminal tests terminal input only, never a disk or system config.
func pty(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	fd, e := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if e != nil {
		t.Fatal(e)
	}
	master := os.NewFile(uintptr(fd), "pty-master")
	t.Cleanup(func() { master.Close() })
	if e = unix.IoctlSetPointerInt(fd, unix.TIOCSPTLCK, 0); e != nil {
		t.Fatal(e)
	}
	n, e := unix.IoctlGetInt(fd, unix.TIOCGPTN)
	if e != nil {
		t.Fatal(e)
	}
	slave, e := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|unix.O_NOCTTY, 0)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { slave.Close() })
	return master, slave
}
func TestDrainQueuedKeys(t *testing.T) {
	for _, input := range []string{"stray keys\n", "unfinished keys"} {
		t.Run(input, func(t *testing.T) {
			master, slave := pty(t)
			if _, e := master.WriteString(input); e != nil {
				t.Fatal(e)
			}
			u := UI{In: slave, Out: io.Discard}
			time.Sleep(10 * time.Millisecond)
			if e := u.Drain(); e != nil {
				t.Fatal(e)
			}
			p := []unix.PollFd{{Fd: int32(slave.Fd()), Events: unix.POLLIN}}
			n, e := unix.Poll(p, 20)
			if e != nil || n != 0 {
				t.Fatal("buffered keys survived flush", n, e)
			}
			if _, e = master.WriteString("\n"); e != nil {
				t.Fatal(e)
			}
			if n, e = unix.Poll(p, 1000); e != nil || n != 1 {
				t.Fatal("fresh input missing", n, e)
			}
			buf := make([]byte, 128)
			n, e = slave.Read(buf)
			if e != nil || string(buf[:n]) != "\n" {
				t.Fatal("unfinished input survived flush", string(buf[:n]), e)
			}
		})
	}
}

type brokenWriter struct{}

func (brokenWriter) Write([]byte) (int, error) { return 0, errors.New("test display failure") }
func TestDisplayFailureWaitsForWorker(t *testing.T) {
	_, slave := pty(t)
	u := UI{In: slave, Out: brokenWriter{}}
	cleaned := false
	e := u.Step(context.Background(), "Installing packages", func(ctx context.Context) error {
		<-ctx.Done()
		time.Sleep(20 * time.Millisecond)
		cleaned = true
		return ctx.Err()
	})
	if e == nil || !strings.Contains(e.Error(), "progress display failed") || !cleaned {
		t.Fatal(e, cleaned)
	}
}
func TestLogoMatchesSource(t *testing.T) {
	b, e := os.ReadFile("../../../installer/logo.txt")
	if e != nil || Logo != string(b) {
		t.Fatal("embedded logo drifted", e)
	}
	if w := logoWidth(); w > 81 || w < 40 {
		t.Fatal("logo width out of the range the padding was designed for", w)
	}
}
func TestDryStepPanic(t *testing.T) {
	u := UI{Out: io.Discard, Dry: true}
	e := u.Step(context.Background(), "Preview", func(context.Context) error { panic("synthetic failure") })
	if e == nil || !strings.Contains(e.Error(), "step Preview panicked: synthetic failure") {
		t.Fatal(e)
	}
}

func colorEnv(t *testing.T, term, colorterm string) {
	t.Helper()
	t.Setenv("TERM", term)
	t.Setenv("COLORTERM", colorterm)
	t.Setenv("NO_COLOR", "")
	t.Setenv("CLICOLOR", "")
	t.Setenv("CLICOLOR_FORCE", "")
	t.Setenv("TERM_PROGRAM", "")
	t.Setenv("TMUX", "")
}

func TestLinuxColors(t *testing.T) {
	// No terminfo or terminal writer is required for the Linux VT override.
	colorEnv(t, "linux", "truecolor") // Ignore a stale inherited COLORTERM.
	var out bytes.Buffer
	u := UI{Out: &out}
	if got := terminalProfile(u.Out); got != colorprofile.ANSI {
		t.Fatal(got)
	}
	u.Screen("Let's setup your machine...", "Press Ctrl+C to cancel.")
	got := out.String()
	if !strings.Contains(got, "\033[32m") || !strings.Contains(got, "\033[90m") || strings.Contains(got, "38;2;") || strings.Contains(got, "38;5;") {
		t.Fatalf("logo and hint did not use the ANSI palette: %q", got)
	}
	// Omarchy's GUM_CONFIRM_*: black on green for the selected button, cyan prompt.
	w := &colorprofile.Writer{Forward: &out, Profile: colorprofile.ANSI}
	out.Reset()
	fmt.Fprint(w, confirmSelected.Render("Yes"), confirmPrompt.Render("Does this look right?"))
	if got := out.String(); !strings.Contains(got, "42m") || !strings.Contains(got, "30") || !strings.Contains(got, "1;36m") {
		t.Fatalf("confirm styles lost their ANSI indexes: %q", got)
	}
	out.Reset()
	u.Begin([]string{"Test step", "Failed step"})
	if e := u.Step(context.Background(), "Test step", func(context.Context) error { return nil }); e != nil {
		t.Fatal(e)
	}
	if e := u.Step(context.Background(), "Failed step", func(context.Context) error { return errors.New("synthetic failure") }); e == nil {
		t.Fatal("step failure swallowed")
	}
	if got := out.String(); !strings.Contains(got, "\033[32m") || strings.Contains(got, "38;2;") || !strings.Contains(got, "\033[?25h") {
		t.Fatalf("progress view lost ANSI green or left the cursor hidden: %q", got)
	}
}

func TestTruecolorAndNoColor(t *testing.T) {
	_, slave := pty(t)
	colorEnv(t, "xterm-256color", "truecolor")
	if profile := terminalProfile(slave); profile != colorprofile.TrueColor {
		t.Fatal(profile)
	}
	t.Setenv("TERM", "linux")
	t.Setenv("NO_COLOR", "1")
	if got := terminalProfile(slave); got != colorprofile.ASCII {
		t.Fatal("explicit NO_COLOR ignored", got)
	}
}

func TestLinuxConfirmKeepsColorsAndNoDefault(t *testing.T) {
	colorEnv(t, "linux", "")
	master, slave := pty(t)
	var out bytes.Buffer
	u := UI{In: slave, Out: &out}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	// Exercise the real Bubble Tea renderer using only a private PTY.
	// Repeated Enter handles startup timing without reading output concurrently.
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				_, _ = master.WriteString("\r")
			}
		}
	}()
	u.Screen("Everything will be overwritten. There is no recovery possible.", "")
	yes, e := u.Confirm(ctx, "Erase everything on the synthetic test disk? This cannot be undone.", "Yes, install", "No, change it", false)
	cancel()
	<-done
	if e != nil || yes {
		t.Fatal("No default changed", yes, e)
	}
	// Remove the banner: these colours must survive in Bubble Tea's output.
	_, form, ok := strings.Cut(out.String(), "There is no recovery possible.")
	if !ok || !strings.Contains(form, "42m") || !strings.Contains(form, "36") || strings.Contains(form, "38;2;") {
		t.Fatalf("renderer stripped or expanded Linux colours: %q", form)
	}
}

func TestEscapeAndInterrupt(t *testing.T) {
	for _, tc := range []struct {
		key  string
		want error
	}{{"\033", ErrBack}, {"\x03", ErrAborted}} {
		master, slave := pty(t)
		u := UI{In: slave, Out: io.Discard}
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		go func() {
			ticker := time.NewTicker(100 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					_, _ = master.WriteString(tc.key)
				}
			}
		}()
		_, e := u.Choose(ctx, "Select keyboard layout", []string{"English (US)", "German"}, "German")
		if !errors.Is(e, tc.want) {
			t.Fatalf("%q: got %v want %v", tc.key, e, tc.want)
		}
		cancel()
	}
}

// view renders a widget the way the terminal would see it at 80 columns.
func view(m tea.Model, cols, rows int) string {
	m.Init()
	m, _ = m.Update(tea.WindowSizeMsg{Width: cols, Height: rows})
	var lines []string
	for _, l := range strings.Split(ansi.Strip(m.View().Content), "\n") {
		lines = append(lines, strings.TrimRight(l, " "))
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

func TestChooseLooksLikeGum(t *testing.T) {
	items := []string{"English (US)", "English (UK)", "Albanian", "Amharic", "Arabic", "Armenian", "Azerbaijani", "Bambara", "Bangla", "Belarusian", "Belgian", "Bosnian"}
	m := newChoose("Select keyboard layout", items, "English (US)", 10, 4)
	got := view(m, 80, 24)
	want := strings.Join([]string{
		"    Select keyboard layout",
		"    > English (US)",
		"      English (UK)",
		"      Albanian",
		"      Amharic",
		"      Arabic",
		"      Armenian",
		"      Azerbaijani",
		"      Bambara",
		"      Bangla",
		"      Belarusian",
		"",
		"      ••",
		"",
		"    ←↓↑→ navigate • enter submit",
	}, "\n")
	if got != want {
		t.Fatalf("choose view:\n%s\nwant:\n%s", got, want)
	}
	// --selected opens on the page holding the selection, cursor on it.
	m = newChoose("Timezone", items, "Belgian", 10, 0)
	if got := view(m, 80, 24); !strings.Contains(got, "> Belgian") || strings.Contains(got, "English (US)") {
		t.Fatalf("selected item not on screen:\n%s", got)
	}
	for _, k := range []string{"down", "down"} {
		_ = k
		m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	}
	if m.choice() != "English (US)" { // wraps to the top like gum
		t.Fatal(m.choice())
	}
}

func TestFilterFuzzy(t *testing.T) {
	zones := []string{"Africa/Abidjan", "America/New_York", "Europe/Berlin", "Europe/London", "Pacific/Auckland"}
	got := fuzzyFind("lon", zones)
	if len(got) != 1 || got[0].text != "Europe/London" || !strings.Contains(fmt.Sprint(got[0].indexes), "7 8 9") {
		t.Fatal(got)
	}
	if got = fuzzyFind("eu", zones); len(got) != 2 || got[0].text != "Europe/Berlin" {
		t.Fatal(got)
	}
	if got = fuzzyFind("", zones); len(got) != len(zones) {
		t.Fatal(got)
	}
	m := newFilter("Timezone", zones, 10, 2)
	s := view(m, 80, 24)
	if !strings.HasPrefix(s, "  Timezone\n  > Filter...") || !strings.Contains(s, "  • Africa/Abidjan") || !strings.Contains(s, "↓↑ navigate • esc blur search • enter submit") {
		t.Fatalf("filter view:\n%s", s)
	}
}

func TestInputAndConfirmViews(t *testing.T) {
	in := newInput("Username> ", "Alphanumeric without spaces (like enkidu)", false, 3)
	if s := view(in, 80, 24); !strings.HasPrefix(s, "   Username> Alphanumeric without spaces (like enkidu)") || !strings.HasSuffix(s, "   enter submit") {
		t.Fatalf("input view: %q", s)
	}
	pw := newInput("Password> ", "", true, 0)
	pw.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	if s := view(pw, 80, 24); !strings.Contains(s, "Password> •") || strings.Contains(s, "> a") {
		t.Fatalf("password echoed: %q", s)
	}
	c := newConfirm("Does this look right?", "Yes", "No, change it", true, true, 2)
	want := "   Does this look right?\n\n      Yes        No, change it\n\n  ←→ toggle • enter submit • y Yes • n No, change it"
	if s := view(c, 80, 24); s != want {
		t.Fatalf("confirm view:\n%q\nwant\n%q", s, want)
	}
	c.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	if c.confirmation {
		t.Fatal("toggle ignored")
	}
}

func TestProgressBands(t *testing.T) {
	u := UI{Out: io.Discard}
	u.Begin([]string{"Partitioning", "Installing packages (takes a while)", "Bootloader"})
	lo, hi := u.band(1)
	if lo0, hi0 := u.band(0); lo0 != 10 || hi0 != lo || hi-lo < 800 || hi >= 1000 {
		t.Fatal(lo0, hi0, lo, hi)
	}
	if _, hi = u.band(2); hi != 1000 {
		t.Fatal(hi)
	}
	for _, s := range []string{"0m 0s", "4m 12s", "1h 4m 12s"} {
		d, _ := time.ParseDuration(strings.NewReplacer(" ", "", "h", "h", "m", "m", "s", "s").Replace(s))
		if got := Duration(d); got != s {
			t.Fatal(got, s)
		}
	}
}

// screen replays the cursor-addressing sequences the dashboard emits onto a
// blank console, so a test can look at the frame rather than the byte stream.
func screen(out string, cols, rows int) string {
	grid := make([][]rune, rows)
	for r := range grid {
		grid[r] = []rune(strings.Repeat(" ", cols))
	}
	row, col := 0, 0
	s := []rune(out)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\033' && i+1 < len(s) && s[i+1] == '[':
			j := i + 2
			for j < len(s) && !(s[j] >= '@' && s[j] <= '~') {
				j++
			}
			if j >= len(s) {
				return "truncated escape"
			}
			params, final := string(s[i+2:j]), s[j]
			switch final {
			case 'H':
				row, col = 0, 0
				if r, c, ok := strings.Cut(params, ";"); ok {
					row, _ = strconv.Atoi(r)
					col, _ = strconv.Atoi(c)
					row, col = max(0, row-1), max(0, col-1)
				}
			case 'J':
				if params == "2" {
					for r := range grid {
						grid[r] = []rune(strings.Repeat(" ", cols))
					}
				} else if row < rows {
					for c := col; c < cols; c++ {
						grid[row][c] = ' '
					}
					for r := row + 1; r < rows; r++ {
						grid[r] = []rune(strings.Repeat(" ", cols))
					}
				}
			case 'K':
				if row < rows {
					grid[row] = []rune(strings.Repeat(" ", cols))
				}
			}
			i = j
		case c == '\n':
			row++
			col = 0
		case c == '\r':
			col = 0
		default:
			if row < rows && col < cols {
				grid[row][col] = c
			}
			col++
		}
	}
	var b strings.Builder
	for _, r := range grid {
		b.WriteString(strings.TrimRight(string(r), " ") + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func TestScreenCenteringAndDump(t *testing.T) {
	colorEnv(t, "linux", "")
	cols, rows := 100, 30
	var out bytes.Buffer
	u := UI{Out: &out, Width: cols, Height: rows}
	pad := strings.Repeat(" ", (cols-logoWidth())/2)
	type shot struct{ name, text string }
	var shots []shot
	widget := func(name string, head func(), m tea.Model) {
		out.Reset()
		head()
		shots = append(shots, shot{name, screen(out.String()+view(m, cols, rows)+"\n", cols, rows)})
	}
	keyboards := []string{"English (US)", "English (UK)", "English (Australia)", "English (Dvorak)", "Albanian", "Amharic", "Arabic", "Armenian", "Azerbaijani", "Bambara", "Bangla", "Belarusian"}
	widget("keyboard", func() { u.Screen("Let's setup your machine...", "") }, newChoose("Select keyboard layout", keyboards, "English (US)", 10, (cols-logoWidth())/2))
	widget("username", func() { u.Screen("Let's setup your user account...", "") }, newInput("Username> ", "Alphanumeric without spaces (like enkidu)", false, (cols-logoWidth())/2))
	widget("timezone", func() { u.Screen("Let's setup your user account...", "") }, newChoose("Timezone", []string{"Europe/Berlin", "Africa/Abidjan", "Africa/Accra", "Africa/Addis_Ababa", "Africa/Algiers", "Africa/Asmara", "Africa/Bamako", "Africa/Bangui", "Africa/Banjul", "Africa/Bissau", "Africa/Blantyre"}, "Europe/Berlin", 10, (cols-logoWidth())/2))
	widget("timezone-filter", func() { u.Screen("Let's setup your user account...", "") }, newFilter("Timezone", []string{"Africa/Abidjan", "Africa/Accra", "Europe/Berlin", "Europe/London"}, 10, (cols-logoWidth())/2))
	widget("notice", func() { u.clearLogo(); fmt.Fprintln(u.output()) }, newSpin("Passwords didn't match!", (cols-logoWidth())/2, func() error { return nil }))
	rows2 := [][2]string{{"Username", "enkidu"}, {"Password", "*********"}, {"Hostname", "uruk"}, {"Timezone", "Europe/Berlin"}, {"Keyboard", "English (US)"}, {"Graphics", "no NVIDIA GPU found"}, {"Kernel", "linux"}}
	widget("summary", func() {
		u.Screen("Let's setup your user account...", "")
		fmt.Fprint(u.output(), u.summaryTable(rows2))
	}, newConfirm("Does this look right?", "Yes", "No, change it", true, true, (cols-logoWidth())/2))
	widget("disk", func() { u.Screen("Let's select where to install Gilgamesh...", "") }, newChoose("Select install disk", []string{"/dev/vda  60.0 GB  Virtio", "/dev/nvme0n1  1000.2 GB  Example NVMe  Serial: 0000  WWN: eui.0000"}, "", 10, (cols-logoWidth())/2))
	widget("erase", func() { u.Screen("Everything will be overwritten. There is no recovery possible.", "") }, newConfirm("Erase everything on /dev/vda  60.0 GB  Virtio? This cannot be undone.", "Yes, install", "No, change it", false, true, (cols-logoWidth())/2))
	out.Reset()
	u.Begin([]string{"Partitioning /dev/vda", "Creating filesystems", "Installing packages (takes a while)"})
	if e := u.Step(context.Background(), "Partitioning /dev/vda", func(context.Context) error { return nil }); e != nil {
		t.Fatal(e)
	}
	u.index = 2
	u.pos = 400
	if e := u.renderStatic(); e != nil {
		t.Fatal(e)
	}
	for n := 0; n < 40; n++ {
		if e := u.renderDynamic("Installing packages (takes a while)"); e != nil {
			t.Fatal(e)
		}
	}
	shots = append(shots, shot{"progress", screen(out.String(), cols, rows)})
	out.Reset()
	u.Failure("step Installing packages (takes a while): pacstrap: exit status 1", []string{"$ pacstrap -K /mnt base", "error: failed retrieving file 'core.db'"}, "Log: /tmp/gilgamesh-install.log")
	shots = append(shots, shot{"failure", screen(out.String(), cols, rows)})
	out.Reset()
	cols2 := cols
	u.In = nil
	finish := func() string {
		// Finished runs a widget; render its static part and the button by hand.
		lines := logoLines()
		top := max(0, (rows-(len(lines)+5))/2) + 1
		var b strings.Builder
		fmt.Fprintf(&b, "\033[2J\033[H")
		for n, l := range lines {
			fmt.Fprintf(&b, "\033[%d;1H%s%s", top+n, pad, l)
		}
		fmt.Fprintf(&b, "\033[%d;1H%s", top+len(lines)+1, center("Installed Gilgamesh in 4m 12s", cols2, logoWidth()))
		fmt.Fprintf(&b, "\033[%d;1H", top+len(lines)+2)
		return b.String() + view(newConfirm("", "Reboot Now", "", true, false, (cols2-18)/2), cols2, rows)
	}
	shots = append(shots, shot{"finished", screen(finish(), cols, rows)})

	var dump strings.Builder
	for _, s := range shots {
		fmt.Fprintf(&dump, "==== %s (%dx%d) ====\n%s\n\n", s.name, cols, rows, s.text)
	}
	if p := os.Getenv("GILGAMESH_SCREENS"); p != "" {
		if e := os.WriteFile(p, []byte(dump.String()), 0644); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range shots {
		lines := strings.Split(s.text, "\n")
		switch s.name {
		case "keyboard":
			// Omarchy's frame: blank, logo, blank, title, blank, widget; everything at the logo's edge.
			if lines[0] != "" || !strings.HasPrefix(lines[1], pad) || lines[7] != "" || lines[8] != pad+"Let's setup your machine..." || lines[9] != "" || lines[10] != pad+"Select keyboard layout" || lines[11] != pad+"> English (US)" {
				t.Fatalf("keyboard screen:\n%s", s.text)
			}
			for _, l := range lines {
				if strings.Contains(l, "│") || strings.Contains(l, "┃") || strings.Contains(l, "Preparing") {
					t.Fatalf("border or stray subtitle:\n%s", s.text)
				}
			}
		case "timezone":
			if lines[11] != pad+"> Europe/Berlin" {
				t.Fatalf("detected timezone not first:\n%s", s.text)
			}
		case "summary":
			if !strings.Contains(s.text, pad+"╭") || !strings.Contains(s.text, pad+"│ Username │ enkidu") || !strings.Contains(s.text, "Yes        No, change it") {
				t.Fatalf("summary table:\n%s", s.text)
			}
		case "progress":
			if !strings.Contains(s.text, "%") || !strings.Contains(s.text, "Installing packages (takes a while)") || !strings.Contains(s.text, "Step 3 of 3") {
				t.Fatalf("progress:\n%s", s.text)
			}
		case "failure":
			if !strings.Contains(s.text, "Gilgamesh installation stopped") || !strings.Contains(s.text, "Last log lines:") {
				t.Fatalf("failure:\n%s", s.text)
			}
		case "finished":
			if !strings.Contains(s.text, "Installed Gilgamesh in 4m 12s") || !strings.Contains(s.text, "Reboot Now") {
				t.Fatalf("finished:\n%s", s.text)
			}
		}
		for _, l := range lines {
			if lipgloss.Width(l) > cols {
				t.Fatalf("%s overflows %d columns: %q", s.name, cols, l)
			}
		}
	}
}
