package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	var (
		configPath string
		dryRun     bool
		noWildcard bool
		baseBranch string
	)

	flag.StringVar(&configPath, "config", "", "load the full config from a JSON file and skip the forms")
	flag.BoolVar(&dryRun, "dry-run", false, "render everything but write nothing and run no git commands")
	flag.BoolVar(&noWildcard, "no-wildcard", false, "skip the cluster service wildcard record")
	flag.StringVar(&baseBranch, "base", "main", "base branch the first PR branch is cut from")
	flag.Parse()

	repoRoot, err := findRepoRoot()
	if err != nil {
		log.Fatal(err)
	}
	if err := os.Chdir(repoRoot); err != nil {
		log.Fatal(err)
	}

	if !dryRun {
		if err := GitStatusClean(); err != nil {
			log.Fatalf("refusing to start: %v", err)
		}
	}

	cfg := &Config{
		ClusterClass:      "dev",
		ProxmoxNode:       "balteus",
		TemplateVmId:      9000,
		TemplateStorage:   "iscsi",
		VlanId:            40,
		TalosVersion:      "v1.14.1",
		StorageBridge:     "vmbr2",
		OidcEnabled:       true,
		CheckHealth:       false,
		ServiceWildcard:   true,
		KarpenterCpu:      "32",
		KarpenterMemory:   "128Gi",
		StorageNfs:        true,
		StorageTruenasCsi: true,
	}

	if configPath != "" {
		cfg, err = LoadConfig(configPath)
		if err != nil {
			log.Fatalf("loading config: %v", err)
		}
	} else if !dryRun {
		if err := RunForms(cfg); err != nil {
			log.Fatal(err)
		}
	} else {
		log.Fatal("--dry-run without --config has nothing to render")
	}

	if noWildcard {
		cfg.ServiceWildcard = false
	}
	if cfg.Endpoint == "" {
		cfg.Endpoint = fmt.Sprintf("https://%s-k8s.srv.hnatekmar.dev:6443", cfg.ClusterName)
	}
	if err := cfg.Validate(); err != nil {
		log.Fatalf("config validation failed: %v", err)
	}

	dhcpPath := filepath.Join(repoRoot, "terraform/routeros/dhcp.tf")
	dnsPath := filepath.Join(repoRoot, "terraform/routeros/dns.tf")
	if err := CheckCollisions(dhcpPath, cfg); err != nil {
		log.Fatalf("collision: %v", err)
	}
	for _, w := range PoolWarnings(cfg) {
		fmt.Fprintf(os.Stderr, "warning: %s\n", w)
	}

	prereqsBranch := fmt.Sprintf("feat/%s-router-prereqs", cfg.ClusterName)
	rootBranch := fmt.Sprintf("feat/%s-cluster-root", cfg.ClusterName)

	if dryRun {
		renderDryRun(cfg, dhcpPath, dnsPath, prereqsBranch, rootBranch)
		return
	}

	if _, err := runGit("rev-parse", "--verify", baseBranch); err != nil {
		log.Fatalf("base branch %q does not exist: %v", baseBranch, err)
	}
	if exists, _ := GitVerifyBranch(prereqsBranch); exists {
		log.Fatalf("branch %s already exists", prereqsBranch)
	}
	if exists, _ := GitVerifyBranch(rootBranch); exists {
		log.Fatalf("branch %s already exists", rootBranch)
	}
	if _, err := os.Stat(filepath.Join(repoRoot, "terraform/clusters", cfg.ClusterName)); !os.IsNotExist(err) {
		log.Fatalf("cluster root terraform/clusters/%s already exists", cfg.ClusterName)
	}

	// ----- PR 1: router prerequisites -------------------------------------------------
	fmt.Printf("PR 1: %s (router prerequisites)\n", prereqsBranch)
	if _, err := runGit("checkout", baseBranch); err != nil {
		log.Fatal(err)
	}
	if err := GitCheckoutBranch(prereqsBranch, true); err != nil {
		log.Fatal(err)
	}
	if err := InsertReservations(dhcpPath, cfg); err != nil {
		log.Fatal(err)
	}
	if err := InsertDNS(dnsPath, cfg); err != nil {
		log.Fatal(err)
	}
	if cfg.ServiceWildcard {
		if err := AppendServiceWildcard(dnsPath, cfg); err != nil {
			log.Fatal(err)
		}
	}
	if err := GitAdd("terraform/routeros/dhcp.tf", "terraform/routeros/dns.tf"); err != nil {
		log.Fatal(err)
	}
	prereqsBody := fmt.Sprintf(
		"The network side of a %s cluster: the nodes' fixed identities and the names that follow them.\n\n"+
			"Nothing here touches a device until the router root is applied, which is the order this is meant to be\n"+
			"reviewed in — a cluster cannot come up on a segment that cannot address it. Merge and APPLY this before\n"+
			"merging %s: a node with no reservation still gets a ten-minute pool lease, so the cluster comes up\n"+
			"looking fine and then re-addresses itself.\n\n"+
			"Reservations, DNS records%s.",
		cfg.ClusterName, rootBranch,
		map[bool]string{true: " and the service wildcard", false: ""}[cfg.ServiceWildcard],
	)
	if err := GitCommit(fmt.Sprintf("feat(routeros): the %s cluster's names and reservations", cfg.ClusterName), prereqsBody); err != nil {
		log.Fatal(err)
	}

	// ----- PR 2: cluster root ---------------------------------------------------------
	fmt.Printf("PR 2: %s (cluster root)\n", rootBranch)
	if err := GitCheckoutBranch(rootBranch, true); err != nil {
		log.Fatal(err)
	}
	files, err := RenderAll(cfg)
	if err != nil {
		log.Fatal(err)
	}
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		full := filepath.Join(repoRoot, path)
		if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
			log.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(files[path]), 0644); err != nil {
			log.Fatal(err)
		}
	}
	if err := GitAdd("terraform/clusters/"+cfg.ClusterName, "bootstrap/argocd/"+cfg.ClusterName); err != nil {
		log.Fatal(err)
	}
	rootBody := fmt.Sprintf(
		"The root for the %s cluster, and the one per-cluster value that is about access (class=%s in\n"+
			"bootstrap/argocd/%s/cluster-base.yaml).\n\n"+
			"Files:\n%s\n\n"+
			"Merge sequence: PR 1 (router prerequisites) must be merged AND applied first, then this.\n"+
			"CI derives the state key cluster-%s/terraform.tfstate from the directory name, so no workflow\n"+
			"change is needed.",
		cfg.ClusterName, cfg.ClusterClass, cfg.ClusterName,
		indentList(paths), cfg.ClusterName,
	)
	if err := GitCommit(fmt.Sprintf("feat(clusters): the %s cluster root", cfg.ClusterName), rootBody); err != nil {
		log.Fatal(err)
	}

	fmt.Printf("\nDone. Two stacked branches are ready:\n")
	fmt.Printf("  1. %s  (router prerequisites — merge AND apply first)\n", prereqsBranch)
	fmt.Printf("  2. %s  (cluster root — stacked on 1)\n", rootBranch)
	fmt.Printf("\nNothing was pushed. To publish:\n")
	fmt.Printf("  git push -u origin %s\n", prereqsBranch)
	fmt.Printf("  git push -u origin %s\n", rootBranch)
}

func renderDryRun(cfg *Config, dhcpPath, dnsPath, prereqsBranch, rootBranch string) {
	fmt.Printf("--- DRY RUN: cluster %s ---\n\n", cfg.ClusterName)
	fmt.Printf("PR 1 branch: %s\n", prereqsBranch)
	fmt.Printf("  insert into %s (above the sentinel, inside local.dhcp_reservations):\n", dhcpPath)
	fmt.Print(indent(ReservationBlock(cfg), "  | "))
	fmt.Printf("  insert into %s (above the sentinel, inside local.dns_records):\n", dnsPath)
	fmt.Print(indent(DNSBlock(cfg), "  | "))
	if cfg.ServiceWildcard {
		fmt.Printf("  append to %s:\n", dnsPath)
		fmt.Print(indent(strings.TrimRight(ServiceWildcardBlock(cfg), "\n"), "  | "))
		fmt.Println()
	}

	fmt.Printf("\nPR 2 branch: %s\n", rootBranch)
	files, err := RenderAll(cfg)
	if err != nil {
		log.Fatal(err)
	}
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		fmt.Printf("\n==> %s\n%s", path, files[path])
		if !strings.HasSuffix(files[path], "\n") {
			fmt.Println()
		}
	}
}

func indent(s, prefix string) string {
	var b strings.Builder
	for _, line := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		b.WriteString(prefix)
		b.WriteString(line)
		b.WriteString("\n")
	}
	return b.String()
}

func indentList(paths []string) string {
	var b strings.Builder
	for _, p := range paths {
		fmt.Fprintf(&b, "  %s\n", p)
	}
	return b.String()
}

func findRepoRoot() (string, error) {
	curr, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(curr, ".git")); err == nil {
			if _, err := os.Stat(filepath.Join(curr, "terraform", "routeros", "dhcp.tf")); err == nil {
				return curr, nil
			}
		}
		parent := filepath.Dir(curr)
		if parent == curr {
			return "", fmt.Errorf("could not find the repo root (no .git and terraform/routeros/dhcp.tf above %s)", curr)
		}
		curr = parent
	}
}
