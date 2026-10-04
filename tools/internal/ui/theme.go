package ui

import (
	"io"
	"os"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/colorprofile"
)

// Linux VTs support 16 colours even when terminfo is absent from the live ISO.
// Pass this profile to Bubble Tea as well as our own output writer: otherwise
// its renderer can strip the colours out of an already styled widget.
func terminalProfile(out io.Writer) colorprofile.Profile {
	if os.Getenv("TERM") == "linux" {
		if os.Getenv("NO_COLOR") != "" {
			return colorprofile.ASCII
		}
		return colorprofile.ANSI
	}
	return colorprofile.Detect(out, os.Environ())
}

// The look is Omarchy's ISO configurator: gum's stock widget styles plus the
// GUM_CONFIRM_* overrides and the --foreground flags its scripts pass. Colours
// are the same palette indexes gum would receive, so the Linux console and a
// terminal emulator render them identically to the original; hex values are
// downsampled by the colour profile exactly as gum does it.
func fg(c string) lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(c)) }

var (
	logoStyle = fg("2")             // gum style --foreground 2
	hintStyle = fg("8")             // say --foreground 8
	plain     = lipgloss.NewStyle() // gum style / say
	dim       = lipgloss.NewStyle().Faint(true)

	// gum choose
	chooseCursor = fg("212")
	chooseHeader = fg("99")
	chooseItem   = plain

	// gum filter
	filterIndicator   = fg("212")
	filterMatch       = fg("212")
	filterHeader      = fg("99")
	filterPrompt      = fg("240")
	filterPlaceholder = fg("240")

	// gum input, with Omarchy's --prompt.foreground
	inputPrompt      = fg("#845DF9")
	inputPlaceholder = fg("240")
	inputCursor      = fg("212")

	// gum confirm under Omarchy's GUM_CONFIRM_* environment
	confirmPrompt     = lipgloss.NewStyle().Margin(0, 0, 0, 1).Bold(true).Foreground(lipgloss.Color("6"))
	confirmSelected   = lipgloss.NewStyle().Padding(0, 3).Margin(0, 1).Foreground(lipgloss.Color("0")).Background(lipgloss.Color("2"))
	confirmUnselected = lipgloss.NewStyle().Padding(0, 3).Margin(0, 1).Foreground(lipgloss.Color("7")).Background(lipgloss.Color("0"))

	// gum spin --spinner pulse
	spinStyle = fg("212")

	// gum table -p: bubbles' table defaults, applied the way gum does
	tableHeader = lipgloss.NewStyle().Bold(true).Padding(0, 1)
	tableCell   = lipgloss.NewStyle().Padding(0, 1)

	// omarchy-install-dashboard draws with plain SGR codes
	green = fg("2")
	red   = fg("1")
)
