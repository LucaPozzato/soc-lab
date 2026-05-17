package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func (m model) Init() tea.Cmd {
	return tea.Batch(fetchStatusCmd(), fetchESStatsCmd(), fetchRulesStatusCmd(resolveRepoRoot()), fetchCaptureStatusCmd(resolveRepoRoot()), tickCmd())
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
			var res struct{ Count int64 `json:"count"` }
			json.Unmarshal(body, &res)
			return res.Count
		}
		stats.EventCount = getCount("suricata*")
		stats.AlertCount = getCount("soc-alerts")
		if r, err := client.Get("http://localhost:9200/_cluster/health?filter_path=status"); err == nil {
			defer r.Body.Close()
			body, _ := io.ReadAll(r.Body)
			var res struct{ Status string `json:"status"` }
			json.Unmarshal(body, &res)
			stats.ClusterHealth = res.Status
		}
		return esStatsMsg(stats)
	}
}

func fetchRulesStatusCmd(repoRoot string) tea.Cmd {
	return func() tea.Msg {
		statusPath := filepath.Join(repoRoot, "docker-logs", "rules", "status.json")
		body, err := os.ReadFile(statusPath)
		if err != nil {
			return rulesStatusMsg(rulesStatus{})
		}
		var rs rulesStatus
		if err := json.Unmarshal(body, &rs); err != nil {
			return rulesStatusMsg(rulesStatus{})
		}
		return rulesStatusMsg(rs)
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

func fetchCaptureStatusCmd(repoRoot string) tea.Cmd {
	return func() tea.Msg {
		cs := captureStatus{}

		// detect dumpcap process
		pidOut, err := exec.Command("pgrep", "dumpcap").Output()
		if err == nil {
			pid := strings.TrimSpace(strings.SplitN(string(pidOut), "\n", 2)[0])
			if pid != "" {
				cs.LiveActive = true
				if argsOut, err := exec.Command("ps", "-p", pid, "-o", "args=").Output(); err == nil {
					parts := strings.Fields(string(argsOut))
					for i, p := range parts {
						if p == "-i" && i+1 < len(parts) {
							cs.Interface = parts[i+1]
							break
						}
					}
				}
			}
		}

		liveDir := filepath.Join(repoRoot, "pcap", "live")
		chunks, _ := filepath.Glob(filepath.Join(liveDir, "capture_*.pcapng"))
		cs.ChunksTotal = len(chunks)

		if data, err := os.ReadFile(filepath.Join(liveDir, ".played")); err == nil {
			for _, l := range strings.Split(strings.TrimSpace(string(data)), "\n") {
				if l != "" {
					cs.ChunksPlayed++
				}
			}
		}

		if len(chunks) > 0 {
			sort.Strings(chunks)
			latest := chunks[len(chunks)-1]
			if info, err := os.Stat(latest); err == nil {
				cs.LastChunkAge = time.Since(info.ModTime()).Round(time.Second)
			}
		}

		return captureStatusMsg(cs)
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
