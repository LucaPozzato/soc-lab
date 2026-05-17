package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
)

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.viewport.Width = max(1, msg.Width-4)
		m.viewport.Height = m.estimateVpH()

	case spinner.TickMsg:
		if m.running {
			var spinCmd tea.Cmd
			m.spinner, spinCmd = m.spinner.Update(msg)
			return m, spinCmd
		}
		return m, nil

	case tickMsg:
		return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), fetchRulesStatusCmd(m.repoRoot), fetchCaptureStatusCmd(m.repoRoot), tickCmd())

	case statusMsg:
		m.services = msg.Services

	case esStatsMsg:
		m.es = esStats(msg)

	case rulesStatusMsg:
		m.rules = rulesStatus(msg)

	case captureStatusMsg:
		m.capture = captureStatus(msg)

	case cmdOutMsg:
		m.running = false
		m.lastCmd = msg.Cmd
		m.lastExitCode = msg.Code
		if !m.cmdStart.IsZero() {
			m.lastDuration = time.Since(m.cmdStart).Round(time.Second)
		}
		if msg.Err != nil {
			if len(strings.TrimSpace(m.output)) > 0 {
				m.output += "\n"
			}
			m.output += fmt.Sprintf("(exit: %v)", msg.Err)
		}
		if !strings.HasSuffix(m.output, "\n\n") {
			m.output += "\n"
		}
		m.viewport.Height = m.estimateVpH()
		m.viewport.SetContent(m.outputContent())
		if m.followOutput {
			m.viewport.GotoBottom()
		}
		return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), fetchRulesStatusCmd(m.repoRoot))

	case streamEnvelopeMsg:
		switch inner := msg.Msg.(type) {
		case cmdStreamChunkMsg:
			if inner.Text != "" {
				follow := m.followOutput || m.viewport.AtBottom()
				if m.output != "" && !strings.HasSuffix(m.output, "\n\n") && !strings.HasSuffix(m.output, "\n") {
					m.output += "\n"
				}
				m.output += inner.Text + "\n"
				m.viewport.Height = m.estimateVpH()
				m.viewport.SetContent(m.outputContent())
				if follow {
					m.viewport.GotoBottom()
					m.followOutput = true
				}
			}
		case cmdOutMsg:
			m.running = false
			m.lastExitCode = inner.Code
			if !m.cmdStart.IsZero() {
				m.lastDuration = time.Since(m.cmdStart).Round(time.Second)
			}
			if inner.Err != nil {
				if !strings.HasSuffix(m.output, "\n") {
					m.output += "\n"
				}
				m.output += fmt.Sprintf("(exit: %v)", inner.Err)
			}
			if !strings.HasSuffix(m.output, "\n\n") {
				m.output += "\n"
			}
			m.viewport.Height = m.estimateVpH()
			m.viewport.SetContent(m.outputContent())
			if m.followOutput {
				m.viewport.GotoBottom()
			}
			return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), fetchRulesStatusCmd(m.repoRoot))
		}
		return m, waitForStreamMsg(msg.Ch)

	case streamClosedMsg:
		if m.running {
			m.running = false
			return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), fetchRulesStatusCmd(m.repoRoot))
		}
		return m, nil

	case tea.KeyMsg:
		if m.confirming {
			switch strings.ToLower(strings.TrimSpace(msg.String())) {
			case "y", "enter":
				line := m.confirmCmd
				m.confirming = false
				m.confirmCmd = ""
				m.running = true
				m.lastCmd = line
				m.cmdStart = time.Now()
				m.input.SetValue("")
				m.output = ""
				m.viewport.Height = m.estimateVpH()
				m.viewport.SetContent(m.outputContent())
				m.viewport.GotoBottom()
				m.followOutput = true
				return m, tea.Batch(runSocLabCmd(m.repoRoot, line, true), m.spinner.Tick)
			case "n", "esc", "ctrl+c":
				m.confirming = false
				m.confirmCmd = ""
				m.output = "Destructive command cancelled."
				m.viewport.Height = m.estimateVpH()
				m.viewport.SetContent(m.outputContent())
				m.viewport.GotoBottom()
				m.followOutput = true
				return m, nil
			default:
				return m, nil
			}
		}

		if msg.String() != "tab" {
			m.completions = nil
			m.completionIdx = 0
		}
		switch msg.String() {
		case "q":
			return m, tea.Quit
		case "ctrl+c":
			if m.running {
				if stopRunningCmd() {
					if !strings.HasSuffix(m.output, "\n") {
						m.output += "\n"
					}
					m.output += "(interrupt requested)"
					m.viewport.Height = m.estimateVpH()
					m.viewport.SetContent(m.outputContent())
					m.viewport.GotoBottom()
					m.followOutput = true
				}
				return m, nil
			}
			return m, nil
		case "f":
			m.focusMode = !m.focusMode
			return m, nil
		case "pgdown", "ctrl+f":
			m.viewport.ViewDown()
			m.followOutput = m.viewport.AtBottom()
			return m, nil
		case "pgup", "ctrl+b":
			m.viewport.ViewUp()
			m.followOutput = false
			return m, nil
		case "tab":
			if len(m.completions) > 0 {
				m.completionIdx = (m.completionIdx + 1) % len(m.completions)
				s := m.buildInputWithCompletion(m.completions[m.completionIdx])
				m.input.SetValue(s)
				m.input.CursorEnd()
			} else {
				fileCmps := m.fileCompletions()
				switch {
				case len(fileCmps) > 1:
					m.completions = fileCmps
					m.completionIdx = 0
					m.input.SetValue(m.buildInputWithCompletion(fileCmps[0]))
					m.input.CursorEnd()
				case len(fileCmps) == 1:
					s := m.buildInputWithCompletion(fileCmps[0])
					if !strings.HasSuffix(s, "/") {
						s += " "
					}
					m.input.SetValue(s)
					m.input.CursorEnd()
				default:
					if s := m.suggestion(); s != "" {
						if !strings.HasSuffix(s, "/") && !strings.HasSuffix(s, " ") {
							s += " "
						}
						m.input.SetValue(s)
						m.input.CursorEnd()
					}
				}
			}
			return m, nil
		case "up":
			if len(m.history) == 0 {
				return m, nil
			}
			if m.histPos == -1 {
				m.histPos = len(m.history) - 1
			} else if m.histPos > 0 {
				m.histPos--
			}
			m.input.SetValue(m.history[m.histPos])
			m.input.CursorEnd()
			return m, nil
		case "down":
			if len(m.history) == 0 || m.histPos == -1 {
				return m, nil
			}
			if m.histPos < len(m.history)-1 {
				m.histPos++
				m.input.SetValue(m.history[m.histPos])
				m.input.CursorEnd()
			} else {
				m.histPos = -1
				m.input.SetValue("")
			}
			return m, nil
		case "enter":
			if m.running {
				return m, nil
			}
			line := strings.TrimSpace(m.input.Value())
			if line == "" {
				return m, nil
			}
			if line == "help" {
				m.output = commandPaletteText()
				m.viewport.Height = m.estimateVpH()
				m.viewport.SetContent(m.outputContent())
				m.viewport.GotoTop()
				m.followOutput = false
				m.input.SetValue("")
				return m, nil
			}
			if len(m.history) == 0 || m.history[len(m.history)-1] != line {
				m.history = append(m.history, line)
			}
			if line == "stack reset" || strings.HasPrefix(line, "stack reset ") || line == "stack uninstall" || strings.HasPrefix(line, "stack uninstall ") {
				m.confirming = true
				m.confirmCmd = line
				m.output = "This is destructive. Confirm in TUI: [y]es / [n]o"
				m.viewport.Height = m.estimateVpH()
				m.viewport.SetContent(m.outputContent())
				m.viewport.GotoTop()
				m.followOutput = false
				m.input.SetValue("")
				return m, nil
			}
			m.histPos = -1
			m.running = true
			m.lastCmd = line
			m.cmdStart = time.Now()
			m.output = ""
			m.viewport.Height = m.estimateVpH()
			m.viewport.SetContent(m.outputContent())
			m.viewport.GotoBottom()
			m.followOutput = true
			m.input.SetValue("")
			return m, tea.Batch(runSocLabCmd(m.repoRoot, line, false), m.spinner.Tick)
		}
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	vp, vcmd := m.viewport.Update(msg)
	m.viewport = vp
	return m, tea.Batch(cmd, vcmd)
}
