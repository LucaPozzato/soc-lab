package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ── types ──────────────────────────────────────────────────────────────────

type serviceStatus struct {
	Name   string
	State  string
	Health string
}

type esStats struct {
	EventCount    int64
	AlertCount    int64
	ClusterHealth string
}

type statusMsg struct{ Services []serviceStatus }
type esStatsMsg esStats
type tickMsg time.Time
type cmdStreamChunkMsg struct{ Text string }
type cmdOutMsg struct {
	Cmd    string
	Output string
	Err    error
	Code   int
}
type streamEnvelopeMsg struct {
	Ch  <-chan tea.Msg
	Msg tea.Msg
}
type streamClosedMsg struct{}

var runningProc = struct {
	sync.Mutex
	cmd *exec.Cmd
}{}

func setRunningCmd(cmd *exec.Cmd) {
	runningProc.Lock()
	runningProc.cmd = cmd
	runningProc.Unlock()
}

func clearRunningCmd(cmd *exec.Cmd) {
	runningProc.Lock()
	if runningProc.cmd == cmd {
		runningProc.cmd = nil
	}
	runningProc.Unlock()
}

func stopRunningCmd() bool {
	runningProc.Lock()
	cmd := runningProc.cmd
	runningProc.Unlock()
	if cmd == nil || cmd.Process == nil {
		return false
	}
	pid := cmd.Process.Pid
	if pid <= 0 {
		return false
	}
	return syscall.Kill(-pid, syscall.SIGINT) == nil
}

type model struct {
	input         textinput.Model
	services      []serviceStatus
	es            esStats
	output        string
	running       bool
	lastCmd       string
	repoRoot      string
	history       []string
	histPos       int
	commands      []string
	viewport      viewport.Model
	width         int
	height        int
	completions   []string
	completionIdx int
	confirming    bool
	confirmCmd    string
	focusMode     bool
	cmdStart      time.Time
	lastExitCode  int
	lastDuration  time.Duration
}

// ── init ───────────────────────────────────────────────────────────────────

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
	cmds := []string{
		"stack install", "stack start", "stack status", "stack stop", "stack reset", "stack uninstall",
		"health check",
		"rules reload",
		"so sync", "so pipelines", "so templates",
		"capture replay <pcap>", "capture replay <pcap> --now", "capture replay <pcap> --keep",
		"capture live <iface> <rotation-seconds>",
		"capture upload <log-file> --type <pipeline>", "capture upload <log-file> --build-pipeline",
	}
	vp := viewport.New(80, 20)
	vp.SetContent("Welcome. Type a command and press Enter.")
	return model{
		input:    ti,
		output:   "Welcome. Type a command and press Enter.",
		services: []serviceStatus{},
		repoRoot: resolveRepoRoot(),
		history:  []string{},
		histPos:  -1,
		commands: cmds,
		viewport: vp,
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
		"  rules reload",
		"  so sync / pipelines / templates",
		"  health check",
		"",
		"  tab       autocomplete / cycle files",
		"  up/down   command history",
		"  pgup/pgdn scroll output",
		"  y / n     confirm reset/uninstall",
		"  q         quit",
	}, "\n")
}

// ── file autocomplete ──────────────────────────────────────────────────────

// expandTilde replaces a leading ~ with the user's home directory.
func expandTilde(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return home + path[1:]
		}
	}
	return path
}

// globFiles globs for file completions. typed may be relative (to repo root),
// absolute, or tilde-prefixed. exts filters by extension (nil = all).
func (m model) globFiles(typed string, exts []string) []string {
	if typed == "" {
		return nil
	}
	expanded := expandTilde(typed)
	isAbs := filepath.IsAbs(expanded)

	trailingSlash := strings.HasSuffix(typed, "/")
	var globPat string
	if isAbs {
		if trailingSlash {
			globPat = filepath.Join(expanded, "*")
		} else {
			globPat = expanded + "*"
		}
	} else {
		if trailingSlash {
			globPat = filepath.Join(m.repoRoot, expanded, "*")
		} else {
			globPat = filepath.Join(m.repoRoot, expanded) + "*"
		}
	}

	matches, _ := filepath.Glob(globPat)
	home, _ := os.UserHomeDir()
	var results []string
	for _, p := range matches {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		var label string
		if isAbs {
			// Keep tilde notation when the typed path started with ~
			if home != "" && strings.HasPrefix(typed, "~") && strings.HasPrefix(p, home) {
				label = "~" + filepath.ToSlash(p[len(home):])
			} else {
				label = filepath.ToSlash(p)
			}
		} else {
			rel, err := filepath.Rel(m.repoRoot, p)
			if err != nil {
				continue
			}
			label = filepath.ToSlash(rel)
		}
		if fi.IsDir() {
			results = append(results, label+"/")
			continue
		}
		if len(exts) > 0 {
			ok := false
			for _, e := range exts {
				if strings.HasSuffix(strings.ToLower(label), e) {
					ok = true
					break
				}
			}
			if !ok {
				continue
			}
		}
		results = append(results, label)
	}
	return results
}

// fileCompletions returns file candidates for the last word being typed,
// system-wide (any command position). Returns at most 10 results.
func (m model) fileCompletions() []string {
	raw := m.input.Value()
	if strings.HasSuffix(raw, " ") {
		return nil
	}
	parts := strings.Fields(raw)
	if len(parts) < 2 || parts[0] != "capture" {
		return nil
	}
	typed := parts[len(parts)-1]
	if strings.HasPrefix(typed, "--") {
		return nil
	}
	var (
		exts []string
	)

	switch parts[1] {
	case "replay":
		if len(parts) != 3 {
			return nil
		}
		exts = []string{".pcap", ".pcapng"}
		if !strings.Contains(typed, "/") {
			typed = filepath.Join("pcap", typed)
		}
	case "upload":
		if len(parts) == 3 {
			if !strings.Contains(typed, "/") {
				typed = filepath.Join("logs", typed)
			}
		} else if len(parts) == 5 && parts[3] == "--type" {
			exts = []string{".yml", ".yaml", ".json"}
			if !strings.Contains(typed, "/") {
				typed = filepath.Join("pipelines", typed)
			}
		} else {
			return nil
		}
	default:
		return nil
	}

	results := m.globFiles(typed, exts)
	if len(results) > 10 {
		results = results[:10]
	}
	return results
}

// buildInputWithCompletion replaces the last word with the completed file.
func (m model) buildInputWithCompletion(file string) string {
	raw := strings.TrimSpace(m.input.Value())
	parts := strings.Fields(raw)
	if len(parts) < 2 {
		return raw
	}
	return strings.Join(parts[:len(parts)-1], " ") + " " + file
}

// suggestion returns ghost-text for command/verb/flag completions (non-file).
func (m model) suggestion() string {
	raw := m.input.Value()
	q := strings.TrimSpace(raw)
	if q == "" {
		return ""
	}
	parts := strings.Fields(q)
	if len(parts) == 0 {
		return ""
	}

	firstWords := []string{"stack", "capture", "health", "rules", "so"}
	if len(parts) == 1 && !strings.HasSuffix(raw, " ") {
		for _, w := range firstWords {
			if strings.HasPrefix(w, parts[0]) && w != parts[0] {
				return w
			}
		}
	}

	secondWords := map[string][]string{
		"stack":   {"install", "start", "status", "stop", "reset", "uninstall"},
		"capture": {"replay", "live", "upload"},
		"health":  {"check"},
		"rules":   {"reload"},
		"so":      {"sync", "pipelines", "templates"},
	}
	root := parts[0]
	if opts, ok := secondWords[root]; ok {
		if len(parts) == 1 && strings.HasSuffix(raw, " ") {
			return raw + opts[0]
		}
		if len(parts) == 2 && !strings.HasSuffix(raw, " ") {
			for _, w := range opts {
				if strings.HasPrefix(w, parts[1]) && w != parts[1] {
					return root + " " + w
				}
			}
		}
	}

	if len(parts) >= 2 && parts[0] == "capture" {
		switch parts[1] {
		case "replay":
			flags := []string{"--keep", "--now"}
			// ghost when single file match
			if len(parts) == 3 && !strings.HasSuffix(raw, " ") {
				if ms := m.globFiles(parts[2], []string{".pcap", ".pcapng"}); len(ms) == 1 {
					return strings.Join(parts[:2], " ") + " " + ms[0]
				}
			}
			if len(parts) == 3 && strings.HasSuffix(raw, " ") {
				return raw + flags[0]
			}
			if len(parts) == 4 && strings.HasPrefix(parts[3], "--") && !strings.HasSuffix(raw, " ") {
				for _, f := range flags {
					if strings.HasPrefix(f, parts[3]) && f != parts[3] {
						return strings.Join(parts[:3], " ") + " " + f
					}
				}
			}
		case "upload":
			flags := []string{"--build-pipeline", "--type"}
			if len(parts) == 3 && !strings.HasSuffix(raw, " ") {
				if ms := m.globFiles(parts[2], nil); len(ms) == 1 {
					return strings.Join(parts[:2], " ") + " " + ms[0]
				}
			}
			if len(parts) == 3 && strings.HasSuffix(raw, " ") {
				return raw + flags[0]
			}
			if len(parts) == 4 && strings.HasPrefix(parts[3], "--") && !strings.HasSuffix(raw, " ") {
				for _, f := range flags {
					if strings.HasPrefix(f, parts[3]) && f != parts[3] {
						return strings.Join(parts[:3], " ") + " " + f
					}
				}
			}
		}
	}

	for _, c := range m.commands {
		if strings.HasPrefix(c, q) && c != q {
			return c
		}
	}
	return ""
}

// ── async commands ─────────────────────────────────────────────────────────

func (m model) Init() tea.Cmd {
	return tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), tickCmd())
}

func tickCmd() tea.Cmd {
	return tea.Tick(3*time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func fetchStatusCmd() tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("docker", "compose", "ps", "--all", "--format", "json")
		out, err := cmd.Output()
		if err != nil {
			return statusMsg{}
		}
		lines := bytes.Split(bytes.TrimSpace(out), []byte("\n"))
		services := make([]serviceStatus, 0, len(lines))
		for _, ln := range lines {
			if len(bytes.TrimSpace(ln)) == 0 {
				continue
			}
			var row map[string]any
			if json.Unmarshal(ln, &row) != nil {
				continue
			}
			name, _ := row["Service"].(string)
			state, _ := row["State"].(string)
			health := ""
			if h, ok := row["Health"].(string); ok {
				health = h
			}
			services = append(services, serviceStatus{Name: name, State: state, Health: health})
		}
		sort.Slice(services, func(i, j int) bool { return services[i].Name < services[j].Name })
		return statusMsg{Services: services}
	}
}

func fetchESStatsCmd() tea.Cmd {
	return func() tea.Msg {
		client := &http.Client{Timeout: 2 * time.Second}
		stats := esStats{}

		getCount := func(index string) int64 {
			r, err := client.Get("http://localhost:9200/" + index + "/_count")
			if err != nil {
				return 0
			}
			defer r.Body.Close()
			body, _ := io.ReadAll(r.Body)
			var res struct {
				Count int64 `json:"count"`
			}
			json.Unmarshal(body, &res)
			return res.Count
		}

		stats.EventCount = getCount("suricata*")
		stats.AlertCount = getCount("soc-alerts")

		if r, err := client.Get("http://localhost:9200/_cluster/health?filter_path=status"); err == nil {
			defer r.Body.Close()
			body, _ := io.ReadAll(r.Body)
			var res struct {
				Status string `json:"status"`
			}
			json.Unmarshal(body, &res)
			stats.ClusterHealth = res.Status
		}

		return esStatsMsg(stats)
	}
}

func runSocLabCmd(repoRoot, cmdline string, assumeYes bool) tea.Cmd {
	return func() tea.Msg {
		parts := strings.Fields(cmdline)
		args := append([]string{"--cli"}, parts...)
		cmd := exec.Command(filepath.Join(repoRoot, "soc-lab"), args...)
		cmd.Dir = repoRoot
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		env := append([]string{}, os.Environ()...)
		isStackInstall := len(parts) >= 2 && parts[0] == "stack" && parts[1] == "install"
		isStackUninstall := len(parts) >= 2 && parts[0] == "stack" && parts[1] == "uninstall"
		if !isStackInstall && !isStackUninstall {
			env = append(env, "SOC_LAB_SHELL=1", "SOC_LAB_NO_BANNER=1")
		}
		if assumeYes {
			env = append(env, "SOC_LAB_ASSUME_YES=1")
		}
		cmd.Env = env

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return cmdOutMsg{Cmd: cmdline, Output: err.Error(), Err: err}
		}
		stderr, err := cmd.StderrPipe()
		if err != nil {
			return cmdOutMsg{Cmd: cmdline, Output: err.Error(), Err: err}
		}

		streamCh := make(chan tea.Msg, 64)
		if err := cmd.Start(); err != nil {
			return cmdOutMsg{Cmd: cmdline, Output: err.Error(), Err: err}
		}
		setRunningCmd(cmd)

		go func() {
			defer close(streamCh)
			defer clearRunningCmd(cmd)
			forward := func(r io.Reader) {
				s := bufio.NewScanner(r)
				buf := make([]byte, 0, 64*1024)
				s.Buffer(buf, 1024*1024)
				for s.Scan() {
					streamCh <- cmdStreamChunkMsg{Text: s.Text()}
				}
			}

			done := make(chan struct{}, 2)
			go func() { forward(stdout); done <- struct{}{} }()
			go func() { forward(stderr); done <- struct{}{} }()
			<-done
			<-done

			err := cmd.Wait()
			code := 0
			if err != nil {
				if ee, ok := err.(*exec.ExitError); ok {
					code = ee.ExitCode()
				} else {
					code = 1
				}
			}
			streamCh <- cmdOutMsg{Cmd: cmdline, Err: err, Code: code}
		}()

		return streamEnvelopeMsg{Ch: streamCh, Msg: cmdStreamChunkMsg{Text: ""}}
	}
}

func waitForStreamMsg(ch <-chan tea.Msg) tea.Cmd {
	return func() tea.Msg {
		msg, ok := <-ch
		if !ok {
			return streamClosedMsg{}
		}
		return streamEnvelopeMsg{Ch: ch, Msg: msg}
	}
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

// ── update ─────────────────────────────────────────────────────────────────

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height

	case tickMsg:
		return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), tickCmd())

	case statusMsg:
		m.services = msg.Services

	case esStatsMsg:
		m.es = esStats(msg)

	case cmdOutMsg:
		m.running = false
		m.lastCmd = msg.Cmd
		m.lastExitCode = msg.Code
		if !m.cmdStart.IsZero() {
			m.lastDuration = time.Since(m.cmdStart).Round(time.Second)
		}
		if msg.Cmd != "" && (m.output == "" || !strings.HasPrefix(m.output, "$ "+msg.Cmd+"\n\n")) {
			m.output = fmt.Sprintf("$ %s\n\n", msg.Cmd)
		}
		if msg.Err != nil {
			if len(strings.TrimSpace(m.output)) > 0 {
				m.output += "\n"
			}
			m.output += fmt.Sprintf("(exit: %v)", msg.Err)
		}
		m.viewport.SetContent(m.output)
		m.viewport.GotoBottom()
		return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd())

	case streamEnvelopeMsg:
		switch inner := msg.Msg.(type) {
		case cmdStreamChunkMsg:
			if inner.Text != "" {
				if m.output == "" || !strings.HasPrefix(m.output, "$ "+m.lastCmd+"\n\n") {
					m.output = fmt.Sprintf("$ %s\n\n", m.lastCmd)
				}
				if !strings.HasSuffix(m.output, "\n\n") && !strings.HasSuffix(m.output, "\n") {
					m.output += "\n"
				}
				m.output += inner.Text + "\n"
				m.viewport.SetContent(strings.TrimRight(m.output, "\n"))
				m.viewport.GotoBottom()
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
			m.viewport.SetContent(strings.TrimRight(m.output, "\n"))
			m.viewport.GotoBottom()
			return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd())
		}
		return m, waitForStreamMsg(msg.Ch)

	case streamClosedMsg:
		if m.running {
			m.running = false
			return m, tea.Batch(fetchStatusCmd(), fetchESStatsCmd())
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
				m.output = fmt.Sprintf("$ %s\n\n", line)
				m.viewport.SetContent(m.output)
				m.viewport.GotoBottom()
				return m, runSocLabCmd(m.repoRoot, line, true)
			case "n", "esc", "ctrl+c":
				m.confirming = false
				m.confirmCmd = ""
				m.output = "Destructive command cancelled."
				m.viewport.SetContent(m.output)
				m.viewport.GotoTop()
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
					m.viewport.SetContent(strings.TrimRight(m.output, "\n"))
					m.viewport.GotoBottom()
				}
				return m, nil
			}
			return m, nil
		case "f":
			m.focusMode = !m.focusMode
			return m, nil

		case "pgdown", "ctrl+f":
			m.viewport.ViewDown()
			return m, nil

		case "pgup", "ctrl+b":
			m.viewport.ViewUp()
			return m, nil

		case "tab":
			// Check existing completions FIRST — if we call fileCompletions() after
			// a file was already placed in the input, it globs to exactly 1 match
			// and breaks cycling.
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
				m.viewport.SetContent(m.output)
				m.viewport.GotoTop()
				m.input.SetValue("")
				return m, nil
			}
			if len(m.history) == 0 || m.history[len(m.history)-1] != line {
				m.history = append(m.history, line)
			}
			if line == "stack reset" || strings.HasPrefix(line, "stack reset ") || line == "stack uninstall" || strings.HasPrefix(line, "stack uninstall ") {
				m.confirming = true
				m.confirmCmd = line
				m.output = fmt.Sprintf("$ %s\n\nThis is destructive. Confirm in TUI: [y]es / [n]o", line)
				m.viewport.SetContent(m.output)
				m.viewport.GotoTop()
				m.input.SetValue("")
				return m, nil
			}
			m.histPos = -1
			m.running = true
			m.lastCmd = line
			m.cmdStart = time.Now()
			m.output = fmt.Sprintf("$ %s\n\n", line)
			m.viewport.SetContent(strings.TrimRight(m.output, "\n"))
			m.viewport.GotoBottom()
			m.input.SetValue("")
			return m, runSocLabCmd(m.repoRoot, line, false)
		}
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	vp, vcmd := m.viewport.Update(msg)
	m.viewport = vp
	return m, tea.Batch(cmd, vcmd)
}

// ── view ───────────────────────────────────────────────────────────────────

func (m model) View() string {
	base := m.width
	if base <= 0 {
		base = 120
	}

	dim := lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	bold110 := lipgloss.NewStyle().Foreground(lipgloss.Color("110")).Bold(true)

	// ── services + ES stats panel ───────────────────────────────────────────
	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("67")).
		Padding(0, 1)

	rows := []string{""}
	if len(m.services) == 0 {
		rows = append(rows, "  · no data")
	}
	for _, s := range m.services {
		stateStyle := dim
		healthStyle := dim
		if strings.EqualFold(s.State, "running") {
			stateStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("114")).Bold(true)
		} else if strings.EqualFold(s.State, "exited") || strings.EqualFold(s.State, "dead") {
			stateStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true)
		}
		if strings.EqualFold(s.Health, "healthy") {
			healthStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("114"))
		} else if s.Health != "" {
			healthStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("221"))
		}
		state := stateStyle.Render(s.State)
		if s.Health != "" {
			state += " " + healthStyle.Render("("+s.Health+")")
		}
		rows = append(rows, fmt.Sprintf("  · %-14s %s", s.Name, state))
	}

	// ES cluster health: yellow is normal for single-node (no replica shards).
	// Use teal (67) instead of warning-orange so it doesn't look alarming.
	rows = append(rows, "")
	dotColor := lipgloss.Color("245")
	switch m.es.ClusterHealth {
	case "green":
		dotColor = lipgloss.Color("114")
	case "yellow":
		dotColor = lipgloss.Color("67") // teal — expected on single-node ES
	case "red":
		dotColor = lipgloss.Color("203")
	}
	dot := lipgloss.NewStyle().Foreground(dotColor).Render("●")
	healthLabel := func() string {
		switch m.es.ClusterHealth {
		case "green":
			return lipgloss.NewStyle().Foreground(lipgloss.Color("114")).Render("green")
		case "yellow":
			return lipgloss.NewStyle().Foreground(lipgloss.Color("67")).Render("yellow")
		case "red":
			return lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Render("red")
		default:
			return dim.Render("n/a")
		}
	}()
	rows = append(rows,
		fmt.Sprintf("  ES  %s %s", dot, healthLabel),
		fmt.Sprintf("  %s %-8s  %s %s",
			dim.Render("events"), bold110.Render(formatCount(m.es.EventCount)),
			dim.Render("alerts"), bold110.Render(formatCount(m.es.AlertCount)),
		),
		fmt.Sprintf("  %s %s", dim.Render("updated"), dim.Render("live")),
		"",
	)

	svcPanel := card.Width(40).Render(strings.Join(rows, "\n"))
	// Put SERVICES into the top border line of the card.
	if ls := strings.Split(svcPanel, "\n"); len(ls) > 0 {
		innerW := max(0, lipgloss.Width(ls[0])-2)
		labelPlain := " SERVICES "
		labelStyled := lipgloss.NewStyle().Foreground(lipgloss.Color("117")).Bold(true).Render(labelPlain)
		labelW := lipgloss.Width(labelPlain)
		if innerW >= labelW {
			left := (innerW - labelW) / 2
			right := innerW - labelW - left
			border := lipgloss.NewStyle().Foreground(lipgloss.Color("67"))
			ls[0] = border.Render("╭"+strings.Repeat("─", left)) + labelStyled + border.Render(strings.Repeat("─", right)+"╮")
			svcPanel = strings.Join(ls, "\n")
		}
	}
	svcH := lipgloss.Height(svcPanel)
	svcW := lipgloss.Width(svcPanel)

	// ── banner: vertically centered against svcPanel using lipgloss.Place ───
	// Place gives us pixel-perfect width control — no ANSI-width estimation needed.
	leftWidth := base - svcW
	if leftWidth < 1 {
		leftWidth = 1
	}
	banner := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("110")).Render(
		"  ███████╗ ██████╗  ██████╗      ██╗      █████╗ ██████╗\n" +
			"  ██╔════╝██╔═══██╗██╔════╝      ██║     ██╔══██╗██╔══██╗\n" +
			"  ███████╗██║   ██║██║      ███╗ ██║     ███████║██████╔╝\n" +
			"  ╚════██║██║   ██║██║      ╚══╝ ██║     ██╔══██║██╔══██╗\n" +
			"  ███████║╚██████╔╝╚██████╗      ███████╗██║  ██║██████╔╝\n" +
			"  ╚══════╝ ╚═════╝  ╚═════╝      ╚══════╝╚═╝  ╚═╝╚═════╝",
	)

	helper := m.helperLine()
	sub := lipgloss.NewStyle().Foreground(lipgloss.Color("240")).Render("  " + helper)
	leftContent := lipgloss.JoinVertical(lipgloss.Left, banner, "", sub)
	bannerW := lipgloss.Width(banner)
	minSideBySide := svcW + max(48, bannerW)

	var top string
	if base < minSideBySide {
		// Narrow terminal fallback: stack sections vertically to prevent clipping.
		top = lipgloss.JoinVertical(lipgloss.Left, leftContent, "", svcPanel)
	} else {
		panelH := max(svcH, lipgloss.Height(leftContent))
		leftCol := lipgloss.Place(leftWidth, panelH, lipgloss.Left, lipgloss.Center, leftContent)
		rightCol := lipgloss.Place(svcW, panelH, lipgloss.Left, lipgloss.Center, svcPanel)
		top = lipgloss.JoinHorizontal(lipgloss.Top, leftCol, rightCol)
	}

	// ── layout dimensions ────────────────────────────────────────────────────
	topH := lipgloss.Height(top)
	if m.focusMode {
		topH = 0
	}

	compH := 0
	var completionLines []string
	if len(m.completions) > 0 {
		compH = len(m.completions)
		for i, c := range m.completions {
			if i == m.completionIdx {
				completionLines = append(completionLines, bold110.Render("> "+c))
			} else {
				completionLines = append(completionLines, dim.Render("  "+c))
			}
		}
	}

	cmdH := 0
	cmdSection := ""
	if m.lastCmd != "" {
		cmdSection = bold110.Render("$ "+m.lastCmd) + "\n\n"
		cmdH = 2
	}

	overhead := topH + 1 + compH + cmdH + 3
	if m.focusMode {
		overhead = compH + cmdH + 3
	}
	vpH := m.height - overhead
	if vpH < 1 {
		vpH = 1
	}
	m.viewport.Width = max(1, base-4)
	m.viewport.Height = vpH

	// ── render ───────────────────────────────────────────────────────────────
	rule := lipgloss.NewStyle().Foreground(lipgloss.Color("238")).
		Render(strings.Repeat("─", base))

	scrollHint := ""
	if !(m.viewport.AtTop() && m.viewport.AtBottom()) {
		scrollHint = dim.Render("  pgup/pgdn: scroll")
	}

	activity := m.activityBar(base)

	input := m.input.View()
	if len(m.completions) == 0 {
		if s := m.suggestion(); s != "" {
			tail := strings.TrimPrefix(s, m.input.Value())
			input = m.input.Prompt + m.input.Value() + dim.Render(tail)
		}
	}
	if m.running {
		input = "running command..."
	}
	inputBox := card.Width(base - 2).Render(input)
	inputH := lipgloss.Height(inputBox)

	scrollH := 0
	if scrollHint != "" {
		scrollH = 1
	}

	// Recompute viewport height using real rendered block heights so
	// the top section never clips off-screen.
	overhead = topH + 1 + 1 + compH + cmdH + scrollH + inputH + 2
	if m.focusMode {
		overhead = 1 + compH + cmdH + scrollH + inputH + 2
	}
	vpH = m.height - overhead
	if vpH < 1 {
		vpH = 1
	}
	m.viewport.Height = vpH

	outputBlock := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("238")).
		Padding(0, 1).
		Render(m.styleOutput(cmdSection + m.viewport.View()))

	// Sections are joined with "\n" between each.
	sections := []string{
		rule,
		activity,
	}
	if !m.focusMode {
		sections = append([]string{top}, sections...)
	}
	if len(completionLines) > 0 {
		sections = append(sections, strings.Join(completionLines, "\n"))
	}
	sections = append(sections, outputBlock)
	if scrollHint != "" {
		sections = append(sections, scrollHint)
	}
	sections = append(sections, inputBox)

	return strings.Join(sections, "\n")
}

func (m model) helperLine() string {
	raw := strings.TrimSpace(m.input.Value())
	parts := strings.Fields(raw)
	base := "tab: autocomplete  ↑↓: history  pgup/pgdn: scroll  f: focus  q: quit"
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
	status := "idle"
	if m.running {
		status = "running"
	}
	statusStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("114")).Bold(true)
	if !m.running && m.lastExitCode != 0 {
		statusStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Bold(true)
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

// ── helpers ────────────────────────────────────────────────────────────────

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Println("error:", err)
	}
}
