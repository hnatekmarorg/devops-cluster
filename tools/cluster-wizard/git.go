package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

func runGit(args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("%v: %s", err, stderr.String())
	}
	return strings.TrimSpace(stdout.String()), nil
}

func GitStatusClean() error {
	out, err := runGit("status", "--porcelain")
	if err != nil {
		return err
	}
	if out != "" {
		return fmt.Errorf("git status is not clean:\n%s", out)
	}
	return nil
}

func GitCheckoutBranch(branch string, create bool) error {
	args := []string{"checkout"}
	if create {
		args = append(args, "-b")
	}
	args = append(args, branch)
	_, err := runGit(args...)
	return err
}

func GitAdd(files ...string) error {
	args := append([]string{"add"}, files...)
	_, err := runGit(args...)
	return err
}

func GitCommit(subject, body string) error {
	args := []string{"commit", "-m", subject, "-m", body}
	_, err := runGit(args...)
	return err
}

func GitVerifyBranch(branch string) (bool, error) {
	_, err := runGit("rev-parse", "--verify", branch)
	if err != nil {
		return false, nil
	}
	return true, nil
}
