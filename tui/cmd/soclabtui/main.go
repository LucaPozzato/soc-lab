package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	"github.com/charmbracelet/lipgloss"
	tea "github.com/charmbracelet/bubbletea"
)

func resolveRepoRoot() string {
	if v := strings.TrimSpace(os.Getenv("SOC_LAB_ROOT")); v != "" {
		return v
	}
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	if filepath.Base(wd) == "tui" {
		return filepath.Dir(wd)
	}
	return wd
}

func newModel() model {
	ti := textinput.New()
	ti.Prompt = "soc-lab> "
	ti.Placeholder = "stack status"
	ti.Focus()
	ti.CharLimit = 300
	ti.Width = 80

	sp := spinner.New()
	sp.Spinner = spinner.MiniDot
	sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("114"))
	cmds := []string{
		"stack install", "stack start", "stack status", "stack stop", "stack reset", "stack uninstall",
		"health check",
		"rules compile",
		"capture replay <pcap>", "capture replay <pcap> --now", "capture replay <pcap> --keep",
		"capture live <iface> <rotation-seconds>",
		"capture upload <log-file> --type <pipeline>", "capture upload <log-file> --build-pipeline",
	}
	vp := viewport.New(80, 20)
	vp.SetContent("")
	return model{
		input:        ti,
		spinner:      sp,
		output:       "Welcome. Type a command and press Enter.",
		followOutput: true,
		services:     []serviceStatus{},
		repoRoot:     resolveRepoRoot(),
		history:      []string{},
		histPos:      -1,
		commands:     cmds,
		viewport:     vp,
	}
}

func commandPaletteText() string {
	return strings.Join([]string{
		"Command Palette",
		"",
		"  stack install / start / status / stop / reset / uninstall",
		"  capture replay <pcap> [--keep] [--now]",
		"  capture upload <file> [--build-pipeline | --type <name>]",
		"  capture live [iface] [rotation]",
		"  rules compile",
		"  health check",
		"",
		"  tab       autocomplete / cycle files",
		"  up/down   command history",
		"  pgup/pgdn output pages",
		"  y / n     confirm reset/uninstall",
		"  q         quit",
	}, "\n")
}

func main() {
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Println("error:", err)
	}
}
