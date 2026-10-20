package main

import (
	"bytes"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestMain lets the test binary act as the program itself: with
// STATUSLINE_TEST_MAIN=1 it runs main() instead of the tests, so the test can
// exercise real stdin/stdout/exit-code behaviour in a subprocess.
func TestMain(m *testing.M) {
	if os.Getenv("STATUSLINE_TEST_MAIN") == "1" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

const sampleInput = `{
  "session_id": "test-session",
  "session_name": "",
  "transcript_path": "",
  "model": {"display_name": "Opus 5.5"},
  "workspace": {"current_dir": "."},
  "context_window": {
    "context_window_size": 200000,
    "used_percentage": 42,
    "current_usage": {"input_tokens": 1000, "cache_creation_input_tokens": 2000, "cache_read_input_tokens": 81000}
  }
}`

func TestRendersOneLineFromSampleInput(t *testing.T) {
	home := t.TempDir() // session bookkeeping must not touch the real home
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(), "STATUSLINE_TEST_MAIN=1", "HOME="+home, "USERPROFILE="+home)
	cmd.Stdin = strings.NewReader(sampleInput)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("exit non-zero: %v\nstderr: %s", err, errb.String())
	}
	got := out.String()
	if strings.TrimSpace(got) == "" {
		t.Fatal("empty output")
	}
	if strings.HasSuffix(got, "\n\n") {
		t.Fatalf("trailing blank line: %q", got)
	}
}
