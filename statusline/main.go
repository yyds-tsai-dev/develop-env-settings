// Claude Code status line.
//
// Line 1: [model] 🏷 name 📂 project ⚡ branch | ████░░░░░░ 42% 85k | 3h12m [2 sessions]
// (🏷 name only when the session was named with /rename)
// Line 2+: last user message (up to 2 lines).
//
// Invoked once per refresh by Claude Code with a JSON payload on stdin.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

// ANSI colours (24-bit).
const (
	reset  = "\033[0m"
	gold   = "\033[38;2;195;158;83m"
	cyan   = "\033[38;2;118;170;185m"
	pink   = "\033[38;2;255;182;193m"
	violet = "\033[38;2;180;142;230m"
	green  = "\033[38;2;152;195;121m"
	gray   = "\033[38;2;64;64;64m"

	ctxGreen = "\033[38;2;108;167;108m"
	ctxGold  = "\033[38;2;188;155;83m"
	ctxRed   = "\033[38;2;185;102;82m"
)

// Ordered so the first match wins (map iteration order is random).
var modelStyles = []struct{ key, color, icon string }{
	{"Fable", violet, "🔮"},
	{"Mythos", violet, "🔮"},
	{"Opus", gold, "💛"},
	{"Sonnet", cyan, "💠"},
	{"Haiku", pink, "🌸"},
}

const (
	defaultContextWindow = 200_000
	sessionGap           = 30 * time.Minute // heartbeats further apart start a new interval
	transcriptTailBytes  = 1 << 20          // scan at most the last 1 MiB of the transcript
	gitTimeout           = 800 * time.Millisecond
	maxSessionNameWidth  = 30 // display columns (CJK counts as 2)
)

// Input is the subset of the Claude Code status-line payload we use.
type Input struct {
	SessionID      string `json:"session_id"`
	SessionName    string `json:"session_name"`
	TranscriptPath string `json:"transcript_path"`
	Model          struct {
		DisplayName string `json:"display_name"`
	} `json:"model"`
	Workspace struct {
		CurrentDir string `json:"current_dir"`
	} `json:"workspace"`
	// Present in recent Claude Code versions; zero when absent.
	ContextWindow struct {
		Size           int     `json:"context_window_size"`
		UsedPercentage float64 `json:"used_percentage"`
		CurrentUsage   *struct {
			InputTokens         int `json:"input_tokens"`
			CacheCreationTokens int `json:"cache_creation_input_tokens"`
			CacheReadTokens     int `json:"cache_read_input_tokens"`
		} `json:"current_usage"`
	} `json:"context_window"`
}

// transcriptLine is the subset of a transcript JSONL record we care about.
type transcriptLine struct {
	Type        string `json:"type"`
	IsSidechain bool   `json:"isSidechain"`
	SessionID   string `json:"sessionId"`
	Message     struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
		Usage   *struct {
			InputTokens         int `json:"input_tokens"`
			CacheCreationTokens int `json:"cache_creation_input_tokens"`
			CacheReadTokens     int `json:"cache_read_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

type session struct {
	ID            string     `json:"id"`
	Date          string     `json:"date"`
	Start         int64      `json:"start"`
	LastHeartbeat int64      `json:"last_heartbeat"`
	TotalSeconds  int64      `json:"total_seconds"`
	Intervals     []interval `json:"intervals"`
}

type interval struct {
	Start int64  `json:"start"`
	End   *int64 `json:"end"`
}

func main() {
	var in Input
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fmt.Fprintln(os.Stderr, "statusline: bad input:", err)
		os.Exit(1)
	}

	var (
		branch, hours, userMsg string
		ctxTokens              int
		wg                     sync.WaitGroup
	)
	wg.Add(3)
	go func() { defer wg.Done(); branch = gitBranch(in.Workspace.CurrentDir) }()
	go func() {
		defer wg.Done()
		updateSession(in.SessionID)
		hours = todayHours()
	}()
	go func() {
		defer wg.Done()
		ctxTokens, userMsg = scanTranscript(in.TranscriptPath, in.SessionID)
	}()
	wg.Wait()

	// Prefer the payload's own context accounting; fall back to the transcript.
	if cu := in.ContextWindow.CurrentUsage; cu != nil {
		if t := cu.InputTokens + cu.CacheCreationTokens + cu.CacheReadTokens; t > 0 {
			ctxTokens = t
		}
	}
	window := in.ContextWindow.Size
	if window <= 0 {
		window = defaultContextWindow
	}
	pct := ctxTokens * 100 / window
	if in.ContextWindow.UsedPercentage > 0 {
		pct = int(in.ContextWindow.UsedPercentage + 0.5)
	}
	if pct > 100 {
		pct = 100
	}

	var b strings.Builder
	fmt.Fprintf(&b, "%s[%s]%s 📂 %s%s | %s %s%d%% %s%s | %s%s\n",
		reset, formatModel(in.Model.DisplayName), formatSessionName(in.SessionName),
		filepath.Base(in.Workspace.CurrentDir), branch,
		progressBar(pct), ctxColor(pct), pct, formatTokens(ctxTokens), reset,
		hours, reset)
	b.WriteString(userMsg)
	os.Stdout.WriteString(b.String())
}

// formatSessionName returns " 🏷 <name>", or "" for an unnamed session.
func formatSessionName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	// Flatten newlines and cap the width so the context-usage segment stays visible.
	name = strings.Join(strings.Fields(name), " ")
	return " " + green + "🏷 " + truncate(name, maxSessionNameWidth) + reset
}

func formatModel(name string) string {
	for _, s := range modelStyles {
		if strings.Contains(name, s.key) {
			return s.color + s.icon + " " + name + reset
		}
	}
	return name
}

// gitBranch returns " ⚡ <branch>" (or short SHA when detached), "" outside a repo.
// Bounded by a timeout so a slow network filesystem cannot stall the status line.
func gitBranch(dir string) string {
	if dir == "" {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	run := func(args ...string) string {
		cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir, "--no-optional-locks"}, args...)...)
		out, err := cmd.Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
	ref := run("symbolic-ref", "--short", "-q", "HEAD")
	if ref == "" {
		ref = run("rev-parse", "--short", "HEAD")
	}
	if ref == "" {
		return ""
	}
	return " ⚡ " + ref
}

func sessionsDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".claude", "session-tracker", "sessions"), nil
}

// updateSession records a heartbeat for this session, extending the current
// interval or opening a new one after a gap of sessionGap.
func updateSession(id string) {
	if id == "" {
		return
	}
	dir, err := sessionsDir()
	if err != nil || os.MkdirAll(dir, 0o755) != nil {
		return
	}
	path := filepath.Join(dir, id+".json")
	now := time.Now()
	ts := now.Unix()

	var s session
	if data, err := os.ReadFile(path); err != nil || json.Unmarshal(data, &s) != nil {
		s = session{ID: id, Date: now.Format("2006-01-02"), Start: ts, LastHeartbeat: ts}
		s.Intervals = []interval{{Start: ts}}
	}

	end := ts
	if n := len(s.Intervals); n > 0 && time.Duration(ts-s.LastHeartbeat)*time.Second < sessionGap {
		s.Intervals[n-1].End = &end
	} else {
		s.Intervals = append(s.Intervals, interval{Start: ts, End: &end})
	}
	s.LastHeartbeat = ts

	s.TotalSeconds = 0
	for _, iv := range s.Intervals {
		if iv.End != nil {
			s.TotalSeconds += *iv.End - iv.Start
		}
	}

	if data, err := json.Marshal(s); err == nil {
		// Write-then-rename so a concurrent reader never sees a torn file.
		tmp := path + ".tmp"
		if os.WriteFile(tmp, data, 0o644) == nil {
			_ = os.Rename(tmp, path)
		}
	}
}

// todayHours sums today's tracked seconds across all sessions.
func todayHours() string {
	dir, err := sessionsDir()
	if err != nil {
		return "0m"
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "0m"
	}
	nowT := time.Now()
	now := nowT.Unix()
	// Local-day window [dayStart, dayEnd). Intervals are clipped to it so a
	// session created on an earlier day (resumed, or spanning midnight) still
	// counts the time worked today. Previously a session was dropped entirely
	// unless its creation Date equalled today, which showed 0m.
	y, mo, d := nowT.Date()
	dayStartT := time.Date(y, mo, d, 0, 0, 0, 0, nowT.Location())
	dayStart, dayEnd := dayStartT.Unix(), dayStartT.AddDate(0, 0, 1).Unix()
	var total int64
	active := 0
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var s session
		if json.Unmarshal(data, &s) != nil || s.LastHeartbeat < dayStart {
			continue
		}
		for _, iv := range s.Intervals {
			if iv.End == nil {
				continue
			}
			lo, hi := iv.Start, *iv.End
			if lo < dayStart {
				lo = dayStart
			}
			if hi > dayEnd {
				hi = dayEnd
			}
			if hi > lo {
				total += hi - lo
			}
		}
		if time.Duration(now-s.LastHeartbeat)*time.Second < sessionGap {
			active++
		}
	}
	h, m := total/3600, (total%3600)/60
	var out string
	switch {
	case h > 0 && m > 0:
		out = fmt.Sprintf("%dh%dm", h, m)
	case h > 0:
		out = fmt.Sprintf("%dh", h)
	default:
		out = fmt.Sprintf("%dm", m)
	}
	if active > 1 {
		out += fmt.Sprintf(" [%d sessions]", active)
	}
	return out
}

// scanTranscript reads only the tail of the transcript and walks it backwards
// once, returning the latest context token count and the latest user message.
func scanTranscript(path, sessionID string) (tokens int, userMsg string) {
	if path == "" {
		return 0, ""
	}
	lines := tailLines(path, transcriptTailBytes)
	needTokens, needMsg := true, true
	for i := len(lines) - 1; i >= 0 && (needTokens || needMsg); i-- {
		line := lines[i]
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		// Cheap pre-filter before paying for a JSON decode.
		hasUsage := needTokens && bytes.Contains(line, []byte(`"usage"`))
		hasUser := needMsg && bytes.Contains(line, []byte(`"role":"user"`))
		if !hasUsage && !hasUser {
			continue
		}
		var rec transcriptLine
		if json.Unmarshal(line, &rec) != nil || rec.IsSidechain {
			continue
		}
		if hasUsage && rec.Message.Usage != nil {
			u := rec.Message.Usage
			if t := u.InputTokens + u.CacheCreationTokens + u.CacheReadTokens; t > 0 {
				tokens, needTokens = t, false
			}
		}
		if hasUser && rec.Type == "user" && rec.Message.Role == "user" && rec.SessionID == sessionID {
			if text := contentText(rec.Message.Content); text != "" && !isSystemMessage(text) {
				userMsg, needMsg = formatUserMessage(text), false
			}
		}
	}
	return tokens, userMsg
}

// tailLines returns the complete lines contained in the last maxBytes of the file.
func tailLines(path string, maxBytes int64) [][]byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil
	}
	start := st.Size() - maxBytes
	if start < 0 {
		start = 0
	}
	buf := make([]byte, st.Size()-start)
	n, _ := f.ReadAt(buf, start)
	buf = buf[:n]
	if start > 0 {
		// Drop the (probably partial) first line.
		if i := bytes.IndexByte(buf, '\n'); i >= 0 {
			buf = buf[i+1:]
		}
	}
	return bytes.Split(buf, []byte{'\n'})
}

// contentText handles both the string form and the content-block array form.
func contentText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	var parts []string
	for _, b := range blocks {
		if b.Type == "text" && b.Text != "" {
			parts = append(parts, b.Text)
		}
	}
	return strings.Join(parts, "\n")
}

var systemTags = []string{
	"<local-command-stdout>", "<local-command-caveat>", "<command-name>",
	"<command-message>", "<command-args>", "<system-reminder>",
	"<task-notification>", "<ide_selection>", "<ide_opened_file>",
}

func isSystemMessage(s string) bool {
	t := strings.TrimSpace(s)
	if (strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]")) ||
		(strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}")) ||
		strings.HasPrefix(t, "Caveat:") {
		return true
	}
	for _, tag := range systemTags {
		if strings.Contains(t, tag) {
			return true
		}
	}
	return false
}

func formatUserMessage(msg string) string {
	const maxLines, lineWidth = 2, 80
	lines := strings.Split(strings.TrimRight(msg, "\n"), "\n")
	var b strings.Builder
	for i, line := range lines {
		if i >= maxLines {
			break
		}
		text := truncate(strings.TrimSpace(line), lineWidth)
		// More lines were dropped: mark the last shown line with an ellipsis.
		if i == maxLines-1 && len(lines) > maxLines && !strings.HasSuffix(text, "...") {
			text += " ..."
		}
		fmt.Fprintf(&b, "%s｜%s%s%s\n", reset, green, text, reset)
	}
	return b.String()
}

// truncate cuts by terminal display width (CJK counts as 2), never mid-rune.
func truncate(s string, width int) string {
	w := 0
	for i, r := range s {
		rw := 1
		if isWide(r) {
			rw = 2
		}
		if w+rw > width-3 {
			// Only truncate if the remainder would actually overflow.
			if displayWidth(s[i:]) > 3 {
				return s[:i] + "..."
			}
			return s
		}
		w += rw
	}
	return s
}

func displayWidth(s string) int {
	w := 0
	for _, r := range s {
		if isWide(r) {
			w += 2
		} else {
			w++
		}
	}
	return w
}

func isWide(r rune) bool {
	return r >= 0x1100 && (unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hangul, r) ||
		unicode.Is(unicode.Hiragana, r) || unicode.Is(unicode.Katakana, r) ||
		(r >= 0xFF00 && r <= 0xFF60) || (r >= 0x1F300 && r <= 0x1FAFF))
}

func progressBar(pct int) string {
	const width = 10
	filled := pct * width / 100
	if filled > width {
		filled = width
	}
	var b strings.Builder
	if filled > 0 {
		b.WriteString(ctxColor(pct) + strings.Repeat("█", filled) + reset)
	}
	if filled < width {
		b.WriteString(gray + strings.Repeat("░", width-filled) + reset)
	}
	return b.String()
}

func ctxColor(pct int) string {
	switch {
	case pct < 60:
		return ctxGreen
	case pct < 80:
		return ctxGold
	}
	return ctxRed
}

func formatTokens(n int) string {
	switch {
	case n == 0:
		return "--"
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1000:
		return fmt.Sprintf("%dk", n/1000)
	}
	return fmt.Sprint(n)
}
