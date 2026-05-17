package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

func (m model) helperLine() string {
	raw := strings.TrimSpace(m.input.Value())
	parts := strings.Fields(raw)
	base := "tab: autocomplete  ↑↓: history  pgup/pgdn: scroll  f: focus  q: quit"
	if m.width > 0 && m.width < 120 {
		base = "tab: autocomplete  ↑↓: history  pgup/pgdn: scroll\n  f: focus  q: quit"
	}
	pad := "  "
	if len(parts) == 0 {
		return base + "\n" + pad
	}
	if parts[0] == "stack" {
		return base + "\n  stack: install/start/status/stop/reset/uninstall"
	}
	if parts[0] == "capture" {
		if len(parts) == 1 {
			return base + "\n  capture: replay/live/upload"
		}
		switch parts[1] {
		case "replay":
			return base + "\n  replay flags: --now --keep  •  pcap/*.pcap only"
		case "upload":
			return base + "\n  upload: logs/<file>  --type pipelines/<parser> or --build-pipeline"
		case "live":
			return base + "\n  live: capture live [iface] [rotation-seconds]"
		}
	}
	return base + "\n" + pad
}

func (m model) activityBar(width int) string {
	dim := lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	label := lipgloss.NewStyle().Foreground(lipgloss.Color("67")).Bold(true)
	statusStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("114")).Bold(true)
	var status string
	if m.running {
		status = m.spinner.View() + " running"
	} else {
		status = "idle"
		if m.lastExitCode != 0 {
			statusStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true)
			status = "error"
		}
	}

	elapsed := "-"
	if m.lastDuration > 0 {
		elapsed = m.lastDuration.String()
	}
	cmd := m.lastCmd
	if cmd == "" {
		cmd = "-"
	}
	line := fmt.Sprintf(" %s %s  %s %s  %s %s  %s %d",
		label.Render("STATE"), statusStyle.Render(status),
		label.Render("CMD"), dim.Render(cmd),
		label.Render("ELAPSED"), dim.Render(elapsed),
		label.Render("EXIT"), m.lastExitCode,
	)
	return lipgloss.NewStyle().Width(width).Render(line)
}

func (m model) styleOutput(s string) string {
	if s == "" {
		return s
	}
	good := lipgloss.NewStyle().Foreground(lipgloss.Color("114"))
	info := lipgloss.NewStyle().Foreground(lipgloss.Color("117"))
	warn := lipgloss.NewStyle().Foreground(lipgloss.Color("221"))
	bad := lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true)

	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		trim := strings.TrimSpace(ln)
		switch {
		case strings.HasPrefix(trim, "[+]"):
			lines[i] = good.Render(ln)
		case strings.HasPrefix(trim, "[*]"):
			lines[i] = info.Render(ln)
		case strings.HasPrefix(trim, "[!]") || strings.HasPrefix(trim, "warn"):
			lines[i] = warn.Render(ln)
		case strings.HasPrefix(trim, "[x]") || strings.Contains(trim, "error"):
			lines[i] = bad.Render(ln)
		}
	}
	return strings.Join(lines, "\n")
}

// estimateVpH approximates the output viewport height without a full render.
// Used in Update() so GotoBottom() uses a realistic offset.
func (m model) estimateVpH() int {
	if m.height == 0 {
		return 10
	}
	nSvcs := len(m.services)
	if nSvcs < 5 {
		nSvcs = 5 // minimum matches view padding so estimate stays stable
	}
	svcPanelH := 2 + 1 + nSvcs + 1 + 3 // border + "Services" header + items + blank + ES rows
	rulesPanelH := 2 + 1 + 2 + 1        // border + "Rules Status" header + 2 rows + timestamp
	capturePanelH := 2 + 4              // border + 4 fixed content rows
	leftH := 9                          // 6 banner lines + 1 empty + 2 helper lines
	topH := max(leftH, svcPanelH+rulesPanelH+capturePanelH)
	if m.focusMode {
		topH = 0
	}
	const inputH = 3  // card border(2) + 1 input line
	const outFixed = 4 // cmdHeader(1) + blank(1) + border(2)
	vpH := m.height - topH - 1 - 1 - inputH - outFixed
	if vpH < 1 {
		vpH = 1
	}
	return vpH
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func formatCount(n int64) string {
	if n == 0 {
		return "-"
	}
	if n >= 1_000_000 {
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	}
	if n >= 1_000 {
		return fmt.Sprintf("%.1fK", float64(n)/1_000)
	}
	return fmt.Sprintf("%d", n)
}

func fitBanner(width int, lines []string) string {
	if width < 84 {
		return "  SOC LAB"
	}
	maxW := width - 6
	if maxW < 20 {
		maxW = 20
	}
	out := make([]string, 0, len(lines))
	for _, ln := range lines {
		r := []rune(ln)
		if len(r) > maxW {
			ln = string(r[:maxW])
		}
		out = append(out, ln)
	}
	return strings.Join(out, "\n")
}
