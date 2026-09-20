package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
)

type Node struct {
	Name     string `json:"name"`
	Role     string `json:"role"`
	MAC      string `json:"mac"`
	Address  string `json:"address"`
	Cores    int    `json:"cores"`
	MemoryMb int    `json:"memoryMb"`
	DiskGb   int    `json:"diskGb"`
	Storage  string `json:"storage"`
}

type Config struct {
	ClusterName       string `json:"clusterName"`
	ClusterClass      string `json:"clusterClass"`
	Endpoint          string `json:"endpoint"`
	VIPBase           string `json:"vipBase"`
	ProxmoxNode       string `json:"proxmoxNode"`
	TemplateVmId      int    `json:"templateVmId"`
	TemplateStorage   string `json:"templateStorage"`
	VlanId            int    `json:"vlanId"`
	TalosVersion      string `json:"talosVersion"`
	StorageBridge     string `json:"storageBridge"`
	OidcEnabled       bool   `json:"oidcEnabled"`
	CheckHealth       bool   `json:"checkHealth"`
	ServiceWildcard   bool   `json:"serviceWildcard"`
	KarpenterCpu      string `json:"karpenterCpu"`
	KarpenterMemory   string `json:"karpenterMemory"`
	StorageNfs        bool   `json:"storageNfs"`
	StorageTruenasCsi bool   `json:"storageTruenasCsi"`
	Nodes             []Node `json:"nodes"`
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.Endpoint == "" && cfg.ClusterName != "" {
		cfg.Endpoint = fmt.Sprintf("https://%s-k8s.srv.hnatekmar.dev:6443", cfg.ClusterName)
	}
	return &cfg, nil
}

var (
	clusterNameRe = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	nodeNameRe    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	macRe         = regexp.MustCompile(`^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$`)
	vipBaseRe     = regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}$`)
)

func validateClusterName(s string) error {
	if !clusterNameRe.MatchString(s) {
		return fmt.Errorf("must be lowercase, start with a letter, and contain only letters, digits and hyphens")
	}
	return nil
}

func validateNodeName(s string) error {
	if !nodeNameRe.MatchString(s) {
		return fmt.Errorf("must be lowercase letters, digits and hyphens")
	}
	return nil
}

func validateMAC(s string) error {
	if !macRe.MatchString(s) {
		return fmt.Errorf("expected an AA:BB:CC:DD:EE:FF MAC")
	}
	return nil
}

func validateIPv4(s string) error {
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() == nil {
		return fmt.Errorf("expected an IPv4 address")
	}
	return nil
}

func validateInt(s string) error {
	if _, err := strconv.Atoi(strings.TrimSpace(s)); err != nil {
		return fmt.Errorf("expected a whole number")
	}
	return nil
}

// validateVIPBase accepts the network part of a /24 (`172.16.50`) and requires it inside the estate's
// reserved 172.16.48.0/20 block.
func validateVIPBase(s string) error {
	if !vipBaseRe.MatchString(s) {
		return fmt.Errorf("expected three octets, e.g. 172.16.50")
	}
	ip := net.ParseIP(s + ".1")
	if ip == nil {
		return fmt.Errorf("invalid address %s.1", s)
	}
	_, block, _ := net.ParseCIDR("172.16.48.0/20")
	if !block.Contains(ip) {
		return fmt.Errorf("%s.0/24 is outside the reserved 172.16.48.0/20 VIP block", s)
	}
	return nil
}

func (c *Config) Validate() error {
	if err := validateClusterName(c.ClusterName); err != nil {
		return fmt.Errorf("cluster name: %w", err)
	}
	if c.ClusterClass != "dev" && c.ClusterClass != "infra" {
		return fmt.Errorf("cluster class must be 'dev' or 'infra', got %q", c.ClusterClass)
	}
	if err := validateVIPBase(c.VIPBase); err != nil {
		return fmt.Errorf("vip base: %w", err)
	}
	if c.ProxmoxNode == "" || c.TemplateStorage == "" || c.TalosVersion == "" || c.StorageBridge == "" {
		return fmt.Errorf("proxmox node, template storage, talos version and storage bridge must be set")
	}
	if len(c.Nodes) == 0 {
		return fmt.Errorf("at least one node is required")
	}

	seenName := map[string]bool{}
	seenAddr := map[string]bool{}
	seenMAC := map[string]bool{}
	controlPlanes := 0
	for _, n := range c.Nodes {
		if err := validateNodeName(n.Name); err != nil {
			return fmt.Errorf("node %q: %w", n.Name, err)
		}
		if n.Role != "controlplane" && n.Role != "worker" {
			return fmt.Errorf("node %q: role must be controlplane or worker", n.Name)
		}
		if n.Role == "controlplane" {
			controlPlanes++
		}
		if n.Storage != "local-lvm" && n.Storage != "iscsi" {
			return fmt.Errorf("node %q: storage must be local-lvm or iscsi", n.Name)
		}
		if n.Cores <= 0 || n.MemoryMb <= 0 || n.DiskGb <= 0 {
			return fmt.Errorf("node %q: cores, memory and disk must be positive", n.Name)
		}
		if err := validateMAC(n.MAC); err != nil {
			return fmt.Errorf("node %q: %w", n.Name, err)
		}
		if err := validateIPv4(n.Address); err != nil {
			return fmt.Errorf("node %q: %w", n.Name, err)
		}

		mac := strings.ToUpper(n.MAC)
		switch {
		case seenName[n.Name]:
			return fmt.Errorf("duplicate node name %q", n.Name)
		case seenAddr[n.Address]:
			return fmt.Errorf("duplicate node address %q", n.Address)
		case seenMAC[mac]:
			return fmt.Errorf("duplicate node MAC %q", n.MAC)
		}
		seenName[n.Name] = true
		seenAddr[n.Address] = true
		seenMAC[mac] = true
	}
	if controlPlanes == 0 {
		return fmt.Errorf("at least one control plane is required")
	}
	if !seenName[c.ClusterName+"-cp1"] {
		return fmt.Errorf("the alias %s-k8s points at %s-cp1, but no such node exists", c.ClusterName, c.ClusterName)
	}
	return nil
}

// AllocateNodes builds a node table from counts and a base address/MAC. Control planes come first; the
// last octet of both the address and the MAC increments per node. Sizes follow the estate's shape: a
// control plane is 4c/8GiB on local storage, a worker 8c/16GiB on iscsi.
func AllocateNodes(clusterName string, cpCount, workerCount int, baseAddr string, baseMAC string) []Node {
	addrParts := strings.Split(baseAddr, ".")
	if len(addrParts) != 4 {
		return nil
	}
	macParts := strings.Split(baseMAC, ":")
	if len(macParts) != 6 {
		return nil
	}

	lastOctet, _ := strconv.Atoi(addrParts[3])
	prefix := strings.Join(addrParts[:3], ".")
	macPrefix := strings.Join(macParts[:5], ":")
	macLast, _ := strconv.ParseInt(macParts[5], 16, 32)

	var nodes []Node
	for i := 1; i <= cpCount; i++ {
		nodes = append(nodes, Node{
			Name:     fmt.Sprintf("%s-cp%d", clusterName, i),
			Role:     "controlplane",
			MAC:      fmt.Sprintf("%s:%02X", macPrefix, macLast),
			Address:  fmt.Sprintf("%s.%d", prefix, lastOctet),
			Cores:    4,
			MemoryMb: 8192,
			DiskGb:   40,
			Storage:  "local-lvm",
		})
		lastOctet++
		macLast++
	}
	for i := 1; i <= workerCount; i++ {
		nodes = append(nodes, Node{
			Name:     fmt.Sprintf("%s-w%d", clusterName, i),
			Role:     "worker",
			MAC:      fmt.Sprintf("%s:%02X", macPrefix, macLast),
			Address:  fmt.Sprintf("%s.%d", prefix, lastOctet),
			Cores:    8,
			MemoryMb: 16384,
			DiskGb:   80,
			Storage:  "iscsi",
		})
		lastOctet++
		macLast++
	}
	return nodes
}

var (
	addressLiteralRe = regexp.MustCompile(`\baddress\s*=\s*"([^"]+)"`)
	macLiteralRe     = regexp.MustCompile(`\bmac\s*=\s*"([^"]+)"`)
)

// CheckCollisions refuses a node whose address or MAC is already claimed by an existing DHCP reservation
// in the router root. It reads only string literals, so computed attributes are ignored.
func CheckCollisions(dhcpPath string, cfg *Config) error {
	data, err := os.ReadFile(dhcpPath)
	if err != nil {
		return err
	}
	addrs := map[string]bool{}
	for _, m := range addressLiteralRe.FindAllStringSubmatch(string(data), -1) {
		addrs[m[1]] = true
	}
	macs := map[string]bool{}
	for _, m := range macLiteralRe.FindAllStringSubmatch(string(data), -1) {
		macs[strings.ToUpper(m[1])] = true
	}
	for _, n := range cfg.Nodes {
		if addrs[n.Address] {
			return fmt.Errorf("address %s is already reserved in %s", n.Address, dhcpPath)
		}
		if macs[strings.ToUpper(n.MAC)] {
			return fmt.Errorf("MAC %s is already reserved in %s", n.MAC, dhcpPath)
		}
	}
	return nil
}

// PoolWarnings flags addresses that fall inside the srv dynamic pools. They are not fatal — a reservation
// excludes the address from a pool — but they are a smell worth stating.
func PoolWarnings(cfg *Config) []string {
	var out []string
	for _, n := range cfg.Nodes {
		parts := strings.Split(n.Address, ".")
		if len(parts) != 4 {
			continue
		}
		last, err := strconv.Atoi(parts[3])
		if err != nil {
			continue
		}
		if (last >= 20 && last <= 99) || (last >= 200 && last <= 250) {
			out = append(out, fmt.Sprintf("node %s address %s sits inside an srv DHCP pool (.20-.99 / .200-.250)", n.Name, n.Address))
		}
	}
	return out
}
