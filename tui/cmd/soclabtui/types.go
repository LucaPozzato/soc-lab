package main

import (
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
)

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

type rulesEngineStatus struct {
	Status      string `json:"status"`
	LastCheck   string `json:"last_check"`
	ErrorLog    string `json:"error_log"`
	LoadedRules int    `json:"loaded_rules"`
	ETRules     int    `json:"et_rules"`
	CustomRules int    `json:"custom_rules"`
	OKCount     int    `json:"ok_count"`
	FailCount   int    `json:"fail_count"`
}

type rulesStatus struct {
	UpdatedAt string            `json:"updated_at"`
	Suricata  rulesEngineStatus `json:"suricata"`
	Sigma     rulesEngineStatus `json:"sigma"`
}

type captureStatus struct {
	LiveActive   bool
	Interface    string
	ChunksTotal  int
	ChunksPlayed int
	LastChunkAge time.Duration // 0 means unknown
}
type captureStatusMsg captureStatus

type statusMsg struct{ Services []serviceStatus }
type esStatsMsg esStats
type rulesStatusMsg rulesStatus
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
	spinner       spinner.Model
	services      []serviceStatus
	es            esStats
	rules         rulesStatus
	capture       captureStatus
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
	followOutput  bool
}

func (m model) outputContent() string {
	return strings.TrimRight(m.output, "\n")
}
