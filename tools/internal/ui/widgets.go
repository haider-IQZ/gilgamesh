package ui

// Bubble Tea models reproducing gum's choose, filter, input, confirm and spin
// commands (github.com/charmbracelet/gum, MIT): same keys, same layout, same
// default styles. Omarchy's configurator is a sequence of those commands, so
// porting them is what makes the screens match.

import (
	"sort"
	"strings"
	"unicode"

	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/paginator"
	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/textinput"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// outcome is how a widget ended: like gum's exit status, Esc is 1 and Ctrl+C 130.
type outcome int

const (
	pending outcome = iota
	submitted
	escaped
	interrupted
)

type widget interface {
	tea.Model
	done() outcome
}

func padded(left int, view string) tea.View {
	return tea.NewView(lipgloss.NewStyle().Padding(0, 0, 0, left).Render(view))
}

func navigate(keys ...string) key.Binding {
	return key.NewBinding(key.WithKeys(keys...))
}

// gum choose

type chooseKeymap struct{ Down, Up, Right, Left, Home, End, Abort, Quit, Submit key.Binding }

func (k chooseKeymap) FullHelp() [][]key.Binding { return nil }
func (k chooseKeymap) ShortHelp() []key.Binding {
	return []key.Binding{key.NewBinding(key.WithKeys("up", "down", "right", "left"), key.WithHelp("←↓↑→", "navigate")), k.Submit}
}

type chooseModel struct {
	header    string
	items     []string
	index     int
	height    int
	padding   int
	paginator paginator.Model
	hasDarkBG bool
	help      help.Model
	keymap    chooseKeymap
	state     outcome
}

func newChoose(header string, items []string, selected string, height, padding int) *chooseModel {
	start := 0
	for n, s := range items {
		if s == selected {
			start = n
			break
		}
	}
	p := paginator.New()
	p.SetTotalPages((len(items) + height - 1) / height)
	p.PerPage = height
	p.Type = paginator.Dots
	p.KeyMap = paginator.KeyMap{}
	p.Page = start / height
	return &chooseModel{header: header, items: items, index: start, height: height, padding: padding, paginator: p, help: help.New(), keymap: chooseKeymap{
		Down: navigate("down", "j", "ctrl+j", "ctrl+n"), Up: navigate("up", "k", "ctrl+k", "ctrl+p"),
		Right: navigate("right", "l", "ctrl+f"), Left: navigate("left", "h", "ctrl+b"),
		Home: navigate("g", "home"), End: navigate("G", "end"),
		Abort: navigate("ctrl+c"), Quit: navigate("esc"),
		Submit: key.NewBinding(key.WithKeys("enter", "ctrl+q"), key.WithHelp("enter", "submit")),
	}}
}
func (m *chooseModel) done() outcome  { return m.state }
func (m *chooseModel) choice() string { return m.items[m.index] }
func (m *chooseModel) Init() tea.Cmd  { return tea.RequestBackgroundColor }
func (m *chooseModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.BackgroundColorMsg:
		m.hasDarkBG = msg.IsDark()
	case tea.KeyPressMsg:
		start, end := m.paginator.GetSliceBounds(len(m.items))
		k := m.keymap
		switch {
		case key.Matches(msg, k.Down):
			m.index++
			if m.index >= len(m.items) {
				m.index = 0
				m.paginator.Page = 0
			}
			if m.index >= end {
				m.paginator.NextPage()
			}
		case key.Matches(msg, k.Up):
			m.index--
			if m.index < 0 {
				m.index = len(m.items) - 1
				m.paginator.Page = m.paginator.TotalPages - 1
			}
			if m.index < start {
				m.paginator.PrevPage()
			}
		case key.Matches(msg, k.Right):
			m.index = min(m.index+m.height, len(m.items)-1)
			m.paginator.NextPage()
		case key.Matches(msg, k.Left):
			m.index = max(m.index-m.height, 0)
			m.paginator.PrevPage()
		case key.Matches(msg, k.End):
			m.index = len(m.items) - 1
			m.paginator.Page = m.paginator.TotalPages - 1
		case key.Matches(msg, k.Home):
			m.index = 0
			m.paginator.Page = 0
		case key.Matches(msg, k.Quit):
			m.state = escaped
			return m, tea.Quit
		case key.Matches(msg, k.Abort):
			m.state = interrupted
			return m, tea.Interrupt
		case key.Matches(msg, k.Submit):
			m.state = submitted
			return m, tea.Quit
		}
	}
	return m, nil
}
func (m *chooseModel) View() tea.View {
	if m.state != pending {
		return tea.NewView("")
	}
	var s strings.Builder
	start, end := m.paginator.GetSliceBounds(len(m.items))
	for n, item := range m.items[start:end] {
		if n == m.index%m.height {
			s.WriteString(chooseCursor.Render("> "))
			s.WriteString(chooseCursor.Render(item))
		} else {
			s.WriteString("  ")
			s.WriteString(chooseItem.Render(item))
		}
		s.WriteRune('\n')
	}
	if m.paginator.TotalPages > 1 {
		lightDark := lipgloss.LightDark(m.hasDarkBG)
		m.paginator.ActiveDot = lipgloss.NewStyle().Foreground(lightDark(lipgloss.Color("#847A85"), lipgloss.Color("#979797"))).Render("•")
		m.paginator.InactiveDot = lipgloss.NewStyle().Foreground(lightDark(lipgloss.Color("#DDDADA"), lipgloss.Color("#3C3C3C"))).Render("•")
		s.WriteString(strings.Repeat("\n", m.height-m.paginator.ItemsOnPage(len(m.items))+1))
		s.WriteString("  " + m.paginator.View())
	}
	parts := []string{}
	if m.header != "" {
		parts = append(parts, chooseHeader.Render(m.header))
	}
	parts = append(parts, s.String(), "", m.help.View(m.keymap))
	return padded(m.padding, lipgloss.JoinVertical(lipgloss.Left, parts...))
}

// gum filter

type filterKeymap struct {
	FocusInSearch, FocusOutSearch, Down, Up, NDown, NUp, Home, End, Abort, Quit, Submit key.Binding
}

func (k filterKeymap) FullHelp() [][]key.Binding { return nil }
func (k filterKeymap) ShortHelp() []key.Binding {
	return []key.Binding{key.NewBinding(key.WithKeys("up", "down"), key.WithHelp("↓↑", "navigate")), k.FocusInSearch, k.FocusOutSearch, k.Submit}
}

type match struct {
	text    string
	indexes []int // rune positions
	score   int
}

// fuzzyFind is a subsequence matcher standing in for gum's sahilm/fuzzy: every
// pattern rune must appear in order; tighter and earlier matches sort first.
func fuzzyFind(pattern string, choices []string) []match {
	var out []match
	p := []rune(strings.ToLower(pattern))
	for _, c := range choices {
		if len(p) == 0 {
			out = append(out, match{text: c})
			continue
		}
		var idx []int
		n := 0
		for pos, r := range []rune(strings.ToLower(c)) {
			if n < len(p) && r == p[n] {
				idx = append(idx, pos)
				n++
			}
		}
		if n < len(p) {
			continue
		}
		score := idx[0] + (idx[len(idx)-1] - idx[0] - len(idx) + 1)
		runes := []rune(c)
		for _, i := range idx {
			if i == 0 || !unicode.IsLetter(runes[i-1]) {
				score--
			}
		}
		out = append(out, match{c, idx, score})
	}
	if len(p) > 0 {
		sort.SliceStable(out, func(a, b int) bool { return out[a].score < out[b].score })
	}
	return out
}

type filterModel struct {
	header   string
	choices  []string
	matches  []match
	cursor   int
	height   int
	padding  int
	input    textinput.Model
	viewport viewport.Model
	help     help.Model
	keymap   filterKeymap
	state    outcome
}

func newFilter(header string, choices []string, height, padding int) *filterModel {
	in := textinput.New()
	in.Focus()
	in.Prompt = "> "
	in.Placeholder = "Filter..."
	st := in.Styles()
	st.Focused.Prompt, st.Blurred.Prompt = filterPrompt, filterPrompt
	st.Focused.Placeholder, st.Blurred.Placeholder = filterPlaceholder, filterPlaceholder
	in.SetStyles(st)
	m := &filterModel{header: header, choices: choices, matches: fuzzyFind("", choices), height: height, padding: padding, input: in, viewport: viewport.New(viewport.WithHeight(height)), help: help.New(), keymap: filterKeymap{
		Down: navigate("down", "ctrl+j", "ctrl+n"), Up: navigate("up", "ctrl+k", "ctrl+p"), NDown: navigate("j"), NUp: navigate("k"),
		Home: navigate("g", "home"), End: navigate("G", "end"),
		FocusInSearch:  key.NewBinding(key.WithKeys("/"), key.WithHelp("/", "search")),
		FocusOutSearch: key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "blur search")),
		Quit:           navigate("esc"), Abort: navigate("ctrl+c"),
		Submit: key.NewBinding(key.WithKeys("enter", "ctrl+q"), key.WithHelp("enter", "submit")),
	}}
	m.focusKeys()
	return m
}
func (m *filterModel) focusKeys() {
	focused := m.input.Focused()
	m.keymap.FocusInSearch.SetEnabled(!focused)
	m.keymap.FocusOutSearch.SetEnabled(focused)
	m.keymap.NUp.SetEnabled(!focused)
	m.keymap.NDown.SetEnabled(!focused)
	m.keymap.Home.SetEnabled(!focused)
	m.keymap.End.SetEnabled(!focused)
}
func (m *filterModel) done() outcome { return m.state }
func (m *filterModel) choice() (string, bool) {
	if m.cursor >= 0 && m.cursor < len(m.matches) {
		return m.matches[m.cursor].text, true
	}
	return "", false
}
func (m *filterModel) Init() tea.Cmd { return textinput.Blink }
func (m *filterModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if m.height == 0 || m.height > msg.Height {
			m.viewport.SetHeight(msg.Height - lipgloss.Height(m.input.View()))
		}
		m.viewport.SetWidth(msg.Width - m.padding)
		m.input.SetWidth(msg.Width - m.padding)
	case tea.KeyPressMsg:
		k := m.keymap
		switch {
		case key.Matches(msg, k.FocusInSearch):
			m.input.Focus()
		case key.Matches(msg, k.FocusOutSearch):
			m.input.Blur()
		case key.Matches(msg, k.Quit):
			m.state = escaped
			return m, tea.Quit
		case key.Matches(msg, k.Abort):
			m.state = interrupted
			return m, tea.Interrupt
		case key.Matches(msg, k.Submit):
			if len(m.matches) == 0 {
				break // nothing to pick yet; keep filtering
			}
			m.state = submitted
			return m, tea.Quit
		case key.Matches(msg, k.Down, k.NDown):
			m.move(1)
		case key.Matches(msg, k.Up, k.NUp):
			m.move(-1)
		case key.Matches(msg, k.Home):
			m.cursor = 0
			m.viewport.GotoTop()
		case key.Matches(msg, k.End):
			m.cursor = len(m.matches) - 1
			m.viewport.GotoBottom()
		default:
			m.matches = fuzzyFind(m.input.Value(), m.choices)
		}
	}
	m.focusKeys()
	m.cursor = max(0, min(m.cursor, len(m.matches)-1))
	return m, cmd
}
func (m *filterModel) move(d int) {
	if len(m.matches) == 0 {
		return
	}
	m.cursor = (m.cursor + d + len(m.matches)) % len(m.matches)
	switch {
	case m.cursor < m.viewport.YOffset():
		if d > 0 {
			m.viewport.GotoTop()
		} else {
			m.viewport.ScrollUp(1)
		}
	case m.cursor >= m.viewport.YOffset()+m.viewport.Height():
		if d > 0 {
			m.viewport.ScrollDown(1)
		} else {
			m.viewport.SetYOffset(len(m.matches) - m.viewport.Height())
		}
	}
}
func (m *filterModel) View() tea.View {
	if m.state != pending {
		return tea.NewView("")
	}
	var s strings.Builder
	for n, match := range m.matches {
		if n == m.cursor {
			s.WriteString(filterIndicator.Render("•"))
		} else {
			s.WriteString(" ")
		}
		s.WriteString(" ")
		var ranges []lipgloss.Range
		for _, r := range runs(match.indexes) {
			ranges = append(ranges, lipgloss.NewRange(r[0], r[1]+1, filterMatch))
		}
		s.WriteString(lipgloss.StyleRanges(match.text, ranges...))
		s.WriteRune('\n')
	}
	m.viewport.SetContent(s.String())
	view := m.input.View() + "\n" + m.viewport.View() + "\n\n" + m.help.View(m.keymap)
	if m.header != "" {
		view = filterHeader.Render(m.header) + "\n" + view
	}
	v := padded(m.padding, view)
	v.ReportFocus = true
	return v
}
func runs(in []int) [][2]int {
	var out [][2]int
	for _, i := range in {
		if n := len(out); n > 0 && out[n-1][1]+1 == i {
			out[n-1][1] = i
			continue
		}
		out = append(out, [2]int{i, i})
	}
	return out
}

// gum input

type inputKeymap struct{}

func (inputKeymap) FullHelp() [][]key.Binding { return nil }
func (inputKeymap) ShortHelp() []key.Binding {
	return []key.Binding{key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "submit"))}
}

type inputModel struct {
	input   textinput.Model
	padding int
	help    help.Model
	state   outcome
}

func newInput(prompt, placeholder string, secret bool, padding int) *inputModel {
	in := textinput.New()
	in.Focus()
	in.Prompt = prompt
	in.Placeholder = placeholder
	in.CharLimit = 400
	st := in.Styles()
	st.Focused.Prompt, st.Blurred.Prompt = inputPrompt, inputPrompt
	st.Focused.Placeholder, st.Blurred.Placeholder = inputPlaceholder, inputPlaceholder
	st.Cursor.Color = inputCursor.GetForeground()
	st.Cursor.Blink = true
	in.SetStyles(st)
	if secret {
		in.EchoMode = textinput.EchoPassword
		in.EchoCharacter = '•'
	}
	return &inputModel{input: in, padding: padding, help: help.New()}
}
func (m *inputModel) done() outcome { return m.state }
func (m *inputModel) value() string { return m.input.Value() }
func (m *inputModel) Init() tea.Cmd { return textinput.Blink }
func (m *inputModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.input.SetWidth(msg.Width - 1 - lipgloss.Width(m.input.Prompt) - m.padding)
	case tea.KeyPressMsg:
		switch msg.String() {
		case "ctrl+c":
			m.state = interrupted
			return m, tea.Interrupt
		case "esc":
			m.state = escaped
			return m, tea.Quit
		case "enter":
			m.state = submitted
			return m, tea.Quit
		}
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}
func (m *inputModel) View() tea.View {
	if m.state != pending {
		return tea.NewView("")
	}
	v := padded(m.padding, lipgloss.JoinVertical(lipgloss.Top, m.input.View(), "", m.help.View(inputKeymap{})))
	v.ReportFocus = true
	return v
}

// gum confirm

type confirmKeymap struct{ Abort, Quit, Negative, Affirmative, Toggle, Submit key.Binding }

func (k confirmKeymap) FullHelp() [][]key.Binding { return nil }
func (k confirmKeymap) ShortHelp() []key.Binding {
	return []key.Binding{k.Toggle, k.Submit, k.Affirmative, k.Negative}
}

type confirmModel struct {
	prompt, affirmative, negative string
	confirmation                  bool
	showHelp                      bool
	padding, width                int
	help                          help.Model
	keys                          confirmKeymap
	state                         outcome
}

func newConfirm(prompt, affirmative, negative string, yes, showHelp bool, padding int) *confirmModel {
	return &confirmModel{prompt: prompt, affirmative: affirmative, negative: negative, confirmation: yes, showHelp: showHelp, padding: padding, help: help.New(), keys: confirmKeymap{
		Abort:       key.NewBinding(key.WithKeys("ctrl+c"), key.WithHelp("ctrl+c", "cancel")),
		Quit:        key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "quit")),
		Negative:    key.NewBinding(key.WithKeys("n", "N", "q"), key.WithHelp("n", negative)),
		Affirmative: key.NewBinding(key.WithKeys("y", "Y"), key.WithHelp("y", affirmative)),
		Toggle:      key.NewBinding(key.WithKeys("left", "h", "ctrl+n", "shift+tab", "right", "l", "ctrl+p", "tab"), key.WithHelp("←→", "toggle")),
		Submit:      key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "submit")),
	}}
}
func (m *confirmModel) done() outcome { return m.state }
func (m *confirmModel) Init() tea.Cmd { return nil }
func (m *confirmModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
	case tea.KeyPressMsg:
		switch {
		case key.Matches(msg, m.keys.Abort):
			m.confirmation = false
			m.state = interrupted
			return m, tea.Interrupt
		case key.Matches(msg, m.keys.Quit):
			m.confirmation = false
			m.state = escaped
			return m, tea.Quit
		case key.Matches(msg, m.keys.Negative):
			m.confirmation = false
			m.state = submitted
			return m, tea.Quit
		case key.Matches(msg, m.keys.Toggle):
			if m.negative != "" {
				m.confirmation = !m.confirmation
			}
		case key.Matches(msg, m.keys.Submit):
			m.state = submitted
			return m, tea.Quit
		case key.Matches(msg, m.keys.Affirmative):
			m.confirmation = true
			m.state = submitted
			return m, tea.Quit
		}
	}
	return m, nil
}
func (m *confirmModel) View() tea.View {
	if m.state != pending {
		return tea.NewView("")
	}
	aff, neg := confirmUnselected.Render(m.affirmative), confirmSelected.Render(m.negative)
	if m.confirmation {
		aff, neg = confirmSelected.Render(m.affirmative), confirmUnselected.Render(m.negative)
	}
	if m.negative == "" {
		neg = ""
	}
	// gum never wraps the prompt; the console would, mid-word. A disk label is
	// long, so wrap at the console edge instead to keep every word readable.
	prompt := confirmPrompt
	if avail := m.width - m.padding - 1; avail > 20 && lipgloss.Width(m.prompt) > avail {
		prompt = prompt.Width(avail)
	}
	parts := []string{prompt.Render(m.prompt) + "\n", lipgloss.JoinHorizontal(lipgloss.Left, aff, neg)}
	if m.showHelp {
		parts = append(parts, "", m.help.View(m.keys))
	}
	return padded(m.padding, lipgloss.JoinVertical(lipgloss.Left, parts...))
}

// gum spin --spinner pulse

type spinDone struct{ err error }

type spinModel struct {
	spinner spinner.Model
	title   string
	padding int
	run     func() error
	err     error
	state   outcome
}

func newSpin(title string, padding int, run func() error) *spinModel {
	s := spinner.New()
	s.Style = spinStyle
	s.Spinner = spinner.Pulse
	return &spinModel{spinner: s, title: title, padding: padding, run: run}
}
func (m *spinModel) done() outcome { return m.state }
func (m *spinModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, func() tea.Msg { return spinDone{m.run()} })
}
func (m *spinModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case spinDone:
		m.err = msg.err
		m.state = submitted
		return m, tea.Quit
	case tea.KeyPressMsg:
		if msg.String() == "ctrl+c" {
			m.state = interrupted
			return m, tea.Interrupt
		}
	}
	var cmd tea.Cmd
	m.spinner, cmd = m.spinner.Update(msg)
	return m, cmd
}
func (m *spinModel) View() tea.View {
	if m.state != pending {
		return tea.NewView("")
	}
	return padded(m.padding, m.spinner.View()+" "+m.title)
}

// keypress waits for Return, like the greeter's `read` on /dev/tty.

type keypressModel struct{ state outcome }

func (m *keypressModel) done() outcome { return m.state }
func (m *keypressModel) Init() tea.Cmd { return nil }
func (m *keypressModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if k, ok := msg.(tea.KeyPressMsg); ok {
		switch k.String() {
		case "ctrl+c":
			m.state = interrupted
			return m, tea.Interrupt
		case "enter":
			m.state = submitted
			return m, tea.Quit
		}
	}
	return m, nil
}
func (m *keypressModel) View() tea.View { return tea.NewView("") }
