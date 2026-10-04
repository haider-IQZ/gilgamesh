// Package ui is the installer's screens: a port of the Omarchy ISO configurator
// (https://github.com/omacom/omarchy-iso, MIT) and its install dashboard, built
// from the same Bubble Tea widgets gum uses. The logo is centred, every widget
// is left-padded to the logo's edge, and each question is one gum command.
package ui

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"charm.land/lipgloss/v2/table"
	"github.com/charmbracelet/colorprofile"
	"golang.org/x/sys/unix"
)

//go:embed logo.txt
var Logo string

// Tagline is the greeter's line under the logo.
const Tagline = "A fast, gaming-focused Arch desktop"

// ErrAborted is Ctrl+C in a prompt: gum's exit 130, Omarchy's abort().
var ErrAborted = errors.New("aborted installation")

// ErrBack is Esc in a prompt: gum's exit 1, which Omarchy's form unwinds on.
var ErrBack = errors.New("back")

// Height of gum choose/filter lists, as in `gum choose --height 10`.
const listHeight = 10

// How long a validation notice spins before the question is asked again.
const noticeDelay = time.Second

type UI struct {
	In            *os.File
	Out           io.Writer
	Dry           bool
	Width, Height int // console size when In is not a terminal; 80x24 if zero
	Sleep         func(context.Context, time.Duration) error
	progress
}

func (u *UI) size() (int, int) {
	w, h := 80, 24
	if u.Width > 0 && u.Height > 0 {
		w, h = u.Width, u.Height
	}
	if u.In == nil {
		return w, h
	}
	if s, e := unix.IoctlGetWinsize(int(u.In.Fd()), unix.TIOCGWINSZ); e == nil && s.Col > 0 && s.Row > 0 {
		w, h = int(s.Col), int(s.Row)
	}
	return w, h
}
func (u *UI) output() io.Writer {
	return &colorprofile.Writer{Forward: u.Out, Profile: terminalProfile(u.Out)}
}
func logoLines() []string { return strings.Split(strings.TrimRight(Logo, "\n"), "\n") }
func logoWidth() int      { return lipgloss.Width(strings.TrimRight(Logo, "\n")) }

// padding is Omarchy's PADDING_LEFT: the logo's left edge, remeasured on every
// redraw because the console can grow after boot.
func (u *UI) padding() int {
	w, _ := u.size()
	return max(0, (w-logoWidth())/2)
}

// WaitStable holds the first draw until the console width has settled at or
// above the logo width (the live VT starts at 80 columns and grows late), for
// at most five seconds.
func (u *UI) WaitStable(ctx context.Context) {
	last, stable := -1, 0
	for waited := 0; waited < 5000; waited += 200 {
		w, _ := u.size()
		if w == last && w >= logoWidth() {
			if stable++; stable >= 3 {
				return
			}
		} else {
			stable = 0
		}
		last = w
		if u.sleep(ctx, 200*time.Millisecond) != nil {
			return
		}
	}
}
func (u *UI) sleep(ctx context.Context, d time.Duration) error {
	if u.Sleep != nil {
		return u.Sleep(ctx, d)
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(d):
		return nil
	}
}

// clearLogo is Omarchy's clear_logo: clear, then the logo in green with one
// blank line above and the centring padding on the left.
func (u *UI) clearLogo() {
	fmt.Fprint(u.output(), "\033[H\033[2J", logoStyle.Padding(1, 0, 0, u.padding()).Render(strings.TrimRight(Logo, "\n")), "\n")
}

// say is Omarchy's say: body text padded to line up with the logo and widgets.
func (u *UI) say(style lipgloss.Style, s string) {
	fmt.Fprintln(u.output(), style.Padding(0, 0, 0, u.padding()).Render(s))
}

// Screen is Omarchy's step(): the logo, a blank line, the title (and a grey
// hint when given), a blank line. The widgets that follow draw under it.
func (u *UI) Screen(title, hint string) {
	u.clearLogo()
	fmt.Fprintln(u.output())
	u.say(plain, title)
	if u.Dry {
		u.say(hintStyle, "Dry run: nothing will be changed.")
	}
	if hint != "" {
		u.say(hintStyle, hint)
	}
	fmt.Fprintln(u.output())
}

// run drives one widget at the cursor, the way gum draws on the tty, and maps
// its ending to gum's exit statuses.
func (u *UI) run(ctx context.Context, m widget, input bool) error {
	w, h := u.size()
	var in io.Reader
	if input && u.In != nil {
		in = u.In
	}
	opts := []tea.ProgramOption{tea.WithInput(in), tea.WithOutput(u.Out), tea.WithColorProfile(terminalProfile(u.Out)), tea.WithWindowSize(w, h), tea.WithContext(ctx), tea.WithoutSignalHandler()}
	_, e := tea.NewProgram(m, opts...).Run()
	switch {
	case ctx.Err() != nil:
		return ctx.Err()
	case errors.Is(e, tea.ErrInterrupted) || m.done() == interrupted:
		return ErrAborted
	case e != nil:
		return fmt.Errorf("terminal: %w", e)
	case m.done() == escaped:
		return ErrBack
	case m.done() != submitted:
		return ErrAborted
	}
	return nil
}

// Welcome is the greeter: logo, tagline and hint centred on the screen, then
// Return starts the install.
func (u *UI) Welcome(ctx context.Context) error {
	w, h := u.size()
	lines := logoLines()
	top := max(0, (h-(len(lines)+4))/2)
	out := u.output()
	fmt.Fprint(out, "\033[?25l\033[H\033[2J")
	fmt.Fprintf(out, "\033[%d;1H%s", top+1, logoStyle.Padding(0, 0, 0, u.padding()).Render(strings.Join(lines, "\n")))
	fmt.Fprintf(out, "\033[%d;%dH%s", top+len(lines)+2, max(0, (w-lipgloss.Width(Tagline))/2)+1, Tagline)
	hint := "Press Return to Start Install"
	fmt.Fprintf(out, "\033[%d;%dH%s", top+len(lines)+4, max(0, (w-len(hint))/2)+1, dim.Render(hint))
	e := u.run(ctx, &keypressModel{}, true)
	fmt.Fprint(out, "\033[0m\033[H\033[2J\033[?25h")
	if errors.Is(e, ErrBack) {
		return nil
	}
	return e
}

// Choose is `gum choose --height 10 --selected <selected> --header <header>`.
func (u *UI) Choose(ctx context.Context, header string, choices []string, selected string) (string, error) {
	if len(choices) == 0 {
		return "", fmt.Errorf("nothing to choose from")
	}
	m := newChoose(header, choices, selected, listHeight, u.padding())
	if e := u.run(ctx, m, true); e != nil {
		return "", e
	}
	return m.choice(), nil
}

// Filter is `gum filter --height 10 --header <header>`.
func (u *UI) Filter(ctx context.Context, header string, choices []string) (string, error) {
	m := newFilter(header, choices, listHeight, u.padding())
	if e := u.run(ctx, m, true); e != nil {
		return "", e
	}
	if v, ok := m.choice(); ok {
		return v, nil
	}
	return "", ErrBack
}

// Input is `gum input --prompt <prompt> --placeholder <placeholder> [--password]`.
func (u *UI) Input(ctx context.Context, prompt, placeholder string, secret bool) (string, error) {
	m := newInput(prompt, placeholder, secret, u.padding())
	if e := u.run(ctx, m, true); e != nil {
		return "", e
	}
	return m.value(), nil
}

// Confirm is `gum confirm --affirmative --negative <prompt>`; Esc answers No,
// as gum's exit status 1 reads to a script.
func (u *UI) Confirm(ctx context.Context, prompt, affirmative, negative string, yes bool) (bool, error) {
	m := newConfirm(prompt, affirmative, negative, yes, true, u.padding())
	e := u.run(ctx, m, true)
	if errors.Is(e, ErrBack) {
		return false, nil
	}
	return m.confirmation && e == nil, e
}

// Summary prints the answers as `gum table -p` indented to the logo, then asks
// "Does this look right?".
func (u *UI) Summary(ctx context.Context, rows [][2]string) (bool, error) {
	fmt.Fprint(u.output(), u.summaryTable(rows))
	return u.Confirm(ctx, "Does this look right?", "Yes", "No, change it", true)
}
func (u *UI) summaryTable(rows [][2]string) string {
	t := table.New().Border(lipgloss.RoundedBorder()).Headers("Field", "Value")
	for _, r := range rows {
		t.Row(r[0], r[1])
	}
	// gum styles its first data row as the header: row 0 is a data row in
	// lipgloss' table. Kept, so the table looks like the original.
	t.StyleFunc(func(row, _ int) lipgloss.Style {
		if row == 0 {
			return tableHeader
		}
		return tableCell
	})
	pad := strings.Repeat(" ", u.padding())
	var b strings.Builder
	for _, l := range strings.Split(t.Render(), "\n") {
		b.WriteString(pad + l + "\n")
	}
	return b.String() + "\n"
}

// Notice is Omarchy's notice: the logo, then a pulse spinner with the message
// for a second, after which the caller asks again.
func (u *UI) Notice(ctx context.Context, message string) error {
	return u.Spin(ctx, message, func(ctx context.Context) error { return u.sleep(ctx, noticeDelay) })
}

// Spin is `gum spin --spinner pulse --title <title> -- <command>` under the
// logo. Input stays with the terminal, so Ctrl+C reaches the signal handler.
func (u *UI) Spin(ctx context.Context, title string, fn func(context.Context) error) error {
	if u.Dry {
		fmt.Fprintln(u.output(), hintStyle.Render("→ "+title))
		return fn(ctx)
	}
	u.clearLogo()
	fmt.Fprintln(u.output())
	m := newSpin(title, u.padding(), func() error { return fn(ctx) })
	if e := u.run(ctx, m, false); e != nil {
		return e
	}
	fmt.Fprintln(u.output())
	return m.err
}

// TCIFLUSH discards both complete lines and unfinished keys, without consuming
// input for the next form. It is read-only with respect to disks/filesystems.
func (u *UI) Drain() error {
	if e := unix.IoctlSetInt(int(u.In.Fd()), unix.TCFLSH, unix.TCIFLUSH); e != nil {
		return fmt.Errorf("cannot drain terminal input: %w", e)
	}
	return nil
}
