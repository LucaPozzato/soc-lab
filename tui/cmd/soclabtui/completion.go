package main

import (
	"os"
	"path/filepath"
	"strings"
)

// expandTilde replaces a leading ~ with the user's home directory.
func expandTilde(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return home + path[1:]
		}
	}
	return path
}

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
	var exts []string
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

func (m model) buildInputWithCompletion(file string) string {
	raw := strings.TrimSpace(m.input.Value())
	parts := strings.Fields(raw)
	if len(parts) < 2 {
		return raw
	}
	return strings.Join(parts[:len(parts)-1], " ") + " " + file
}

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
	firstWords := []string{"stack", "capture", "health", "rules"}
	if len(parts) == 1 && !strings.HasSuffix(raw, " ") {
		for _, w := range firstWords {
			if strings.HasPrefix(w, parts[0]) && w != parts[0] {
				return w
			}
		}
	}
	secondWords := map[string][]string{"stack": {"install", "start", "status", "stop", "reset", "uninstall"}, "capture": {"replay", "live", "upload"}, "health": {"check"}, "rules": {"compile"}}
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
