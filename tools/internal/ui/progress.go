package ui

// The install view follows omarchy-install-dashboard: a drawing centred on the
// console, a green percentage and status line under it, a dim line below, and
// the logo with "Installed ... in <time>" plus a Reboot Now button at the end.
// Our drawing is the logo itself; progress is the dashboard's monotonic
// per-mille position, each step owning a band it approaches asymptotically.

import (
	"context"
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
)

type progress struct {
	titles       []string
	index        int
	pos, display int // per-mille, both only ever grow
	top          int
	last         [2]int
}

// Weight and time constant of a step's band: package installation is most of
// the install, so it owns most of the bar and crawls slowest.
func stepShape(title string) (weight, tau int) {
	if strings.HasPrefix(title, "Installing packages") {
		return 16, 120
	}
	return 1, 3
}

// Begin announces the steps Step will be called for, in order.
func (u *UI) Begin(titles []string) {
	u.progress = progress{titles: titles, pos: 10, display: 10}
}

// band is the per-mille range of step n out of the weighted total.
func (u *UI) band(n int) (lo, hi int) {
	sum, before, own := 0, 0, 0
	for i, title := range u.titles {
		w, _ := stepShape(title)
		sum += w
		if i < n {
			before += w
		}
		if i == n {
			own = w
		}
	}
	if sum == 0 {
		return 10, 1000
	}
	return 10 + 990*before/sum, 10 + 990*(before+own)/sum
}

func center(text string, cols, width int) string {
	left := max(0, (cols-width)/2)
	inner := max(0, (width-lipgloss.Width(text))/2)
	return strings.Repeat(" ", left+inner) + text
}
func truncate(s string, width int) string {
	if lipgloss.Width(s) <= width || width < 2 {
		return s
	}
	r := []rune(s)
	return string(r[:max(0, min(len(r), width-1))]) + "…"
}
func (u *UI) textWidth(cols int) int { return min(cols-2, logoWidth()) }

// renderStatic clears the console and draws the logo vertically centred, leaving
// the rows below it for the dynamic lines.
func (u *UI) renderStatic() error {
	cols, rows := u.size()
	u.last = [2]int{cols, rows}
	lines := logoLines()
	u.top = max(0, (rows-(len(lines)+6))/2) + 1
	pad := strings.Repeat(" ", max(0, (cols-logoWidth())/2))
	var b strings.Builder
	b.WriteString("\033[?25l\033[2J\033[H")
	for n, l := range lines {
		fmt.Fprintf(&b, "\033[%d;1H%s%s", u.top+n, pad, green.Render(l))
	}
	_, e := fmt.Fprint(u.output(), b.String())
	return e
}

// renderDynamic eases the shown position toward the measured one and rewrites
// the percentage, status and footer rows.
func (u *UI) renderDynamic(title string) error {
	cols, rows := u.size()
	if u.last != [2]int{cols, rows} {
		if e := u.renderStatic(); e != nil {
			return e
		}
	}
	u.display += (u.pos - u.display + 3) / 4
	width := u.textWidth(cols)
	row := u.top + len(logoLines()) + 1
	footer := fmt.Sprintf("Step %d of %d", min(u.index+1, len(u.titles)), len(u.titles))
	var b strings.Builder
	fmt.Fprintf(&b, "\033[%d;1H\033[2K%s\n", row, center(green.Render(fmt.Sprintf("%d%%", u.display/10)), cols, width))
	fmt.Fprintf(&b, "\033[2K%s\n\033[2K\n", center(green.Render(truncate(title, width)), cols, width))
	fmt.Fprintf(&b, "\033[2K%s\033[J", center(dim.Render(truncate(footer, width)), cols, width))
	_, e := fmt.Fprint(u.output(), b.String())
	return e
}

// Step runs one install step under the progress view. A display failure
// cancels the work and waits for it before returning, so cleanup never races
// a still-running step.
func (u *UI) Step(ctx context.Context, title string, fn func(context.Context) error) error {
	work := func(ctx context.Context) (err error) {
		defer func() {
			if p := recover(); p != nil {
				err = fmt.Errorf("step %s panicked: %v", title, p)
			}
		}()
		return fn(ctx)
	}
	if u.Dry {
		fmt.Fprintln(u.output(), green.Render("→ "+title))
		return work(ctx)
	}
	if u.index >= len(u.titles) { // A step Begin did not announce: give it a band of its own.
		u.titles = append(u.titles, title)
		u.index = len(u.titles) - 1
		u.pos, u.display = max(u.pos, 10), max(u.display, 10)
	}
	lo, hi := u.band(u.index)
	_, tau := stepShape(title)
	u.pos = max(u.pos, lo)
	start := time.Now()
	stepCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- work(stepCtx) }()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	if e := u.renderStatic(); e != nil {
		cancel()
		<-done
		return fmt.Errorf("progress display failed: %w", e)
	}
	for {
		select {
		case e := <-done:
			if e != nil {
				fmt.Fprint(u.output(), "\033[?25h")
				return e
			}
			u.pos = max(u.pos, hi-1)
			u.index++
			if u.index == len(u.titles) {
				u.pos = 1000
				for u.display < 999 {
					if e := u.renderDynamic(title); e != nil {
						return fmt.Errorf("progress display failed: %w", e)
					}
					if u.sleep(ctx, 50*time.Millisecond) != nil {
						break
					}
				}
			}
			return nil
		case <-ticker.C:
			span := max(2, hi-lo)
			t := int(time.Since(start) / time.Second)
			u.pos = min(max(u.pos, lo+(span-1)*t/(t+tau)), hi-1)
			if e := u.renderDynamic(title); e != nil {
				cancel()
				<-done
				fmt.Fprint(u.output(), "\033[?25h")
				return fmt.Errorf("progress display failed: %w", e)
			}
		}
	}
}

// Duration formats an install time the way the dashboard does: "4m 12s" or "1h 4m 12s".
func Duration(d time.Duration) string {
	s := int(d.Round(time.Second) / time.Second)
	if s >= 3600 {
		return fmt.Sprintf("%dh %dm %ds", s/3600, s%3600/60, s%60)
	}
	return fmt.Sprintf("%dm %ds", s/60, s%60)
}

// Finished is the dashboard's finish screen: the logo, "Installed Gilgamesh in
// <time>" and a single Reboot Now button, centred. It reports whether to reboot.
func (u *UI) Finished(ctx context.Context, duration string) (bool, error) {
	cols, rows := u.size()
	lines := logoLines()
	top := max(0, (rows-(len(lines)+5))/2) + 1
	title := "Installed Gilgamesh"
	if duration != "" {
		title += " in " + duration
	}
	pad := strings.Repeat(" ", max(0, (cols-logoWidth())/2))
	var b strings.Builder
	b.WriteString("\033[?25l\033[2J\033[H")
	for n, l := range lines {
		fmt.Fprintf(&b, "\033[%d;1H%s%s", top+n, pad, green.Render(l))
	}
	fmt.Fprintf(&b, "\033[%d;1H%s", top+len(lines)+1, center(title, cols, logoWidth()))
	// gum paints its prompt row at the cursor and the button two rows under it.
	fmt.Fprintf(&b, "\033[?25h\033[%d;1H", top+len(lines)+2)
	fmt.Fprint(u.output(), b.String())
	m := newConfirm("", "Reboot Now", "", true, false, max(0, (cols-18)/2))
	e := u.run(ctx, m, true)
	if e != nil && e != ErrBack {
		return false, e
	}
	return m.confirmation && e == nil, nil
}

// Failure is the dashboard's failure screen: the logo, a red headline, the
// reason, and the last lines of the install log.
func (u *UI) Failure(reason string, tail []string, footer string) {
	cols, rows := u.size()
	width := logoWidth()
	pad := strings.Repeat(" ", max(0, (cols-width)/2))
	var b strings.Builder
	b.WriteString("\033[?25h\033[2J\033[H\n")
	for _, l := range logoLines() {
		b.WriteString(pad + green.Render(l) + "\n")
	}
	b.WriteString("\n" + center(red.Render("Gilgamesh installation stopped"), cols, width) + "\n")
	for _, l := range strings.Split(lipgloss.NewStyle().Width(width).Render(reason), "\n") {
		b.WriteString(center(strings.TrimRight(l, " "), cols, width) + "\n")
	}
	if len(tail) > 0 {
		lines := min(len(tail), max(6, min(14, rows-len(logoLines())-18)))
		b.WriteString("\n" + pad + "  " + dim.Render("Last log lines:") + "\n")
		for _, l := range tail[len(tail)-lines:] {
			b.WriteString(pad + "  " + truncate(l, max(40, width-4)) + "\n")
		}
	}
	if footer != "" {
		b.WriteString("\n" + center(dim.Render(footer), cols, width) + "\n")
	}
	fmt.Fprint(u.output(), b.String()+"\n")
}
