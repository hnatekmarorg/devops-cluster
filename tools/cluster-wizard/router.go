package main

import (
	"bytes"
	"fmt"
	"os"
	"strings"
)

const (
	reservationSentinel = "# cluster-wizard:insert-reservations"
	dnsSentinel         = "# cluster-wizard:insert-dns-records"
)

// ReservationBlock renders the lines inserted into `local.dhcp_reservations`, ending in a blank line so
// the sentinel stays separated. The key is quoted — HCL map keys are strings.
func ReservationBlock(cfg *Config) string {
	maxName := 0
	for _, n := range cfg.Nodes {
		if len(n.Name) > maxName {
			maxName = len(n.Name)
		}
	}

	var b strings.Builder
	fmt.Fprintf(&b, "    # The %s cluster's nodes. Clones of PVE template `%d`, so the MACs are ours to pick and the\n", cfg.ClusterName, cfg.TemplateVmId)
	fmt.Fprintf(&b, "    # reservation *is* the address assignment: Talos comes up in maintenance mode and DHCPs straight\n")
	fmt.Fprintf(&b, "    # onto its address, with no static network config in the machine config. %d control plane(s) and\n", countRole(cfg.Nodes, "controlplane"))
	fmt.Fprintf(&b, "    # %d worker(s); addresses sit in srv's free band, outside the pools (`.20-.99`, `.200-.250`).\n", countRole(cfg.Nodes, "worker"))
	for _, n := range cfg.Nodes {
		fmt.Fprintf(&b, "    %-*s = { mac = \"%s\", address = \"%s\", class = \"srv\" }\n",
			maxName+2, fmt.Sprintf("%q", n.Name), n.MAC, n.Address)
	}
	b.WriteString("\n")
	return b.String()
}

// DNSBlock renders the lines inserted into `local.dns_records`: one record per node plus the `<cluster>-k8s`
// alias pointing at the first control plane.
func DNSBlock(cfg *Config) string {
	cp1 := firstControlPlane(cfg.Nodes)

	maxName := len(cfg.ClusterName + "-k8s.srv.hnatekmar.dev")
	for _, n := range cfg.Nodes {
		if len(n.Name)+len(".srv.hnatekmar.dev") > maxName {
			maxName = len(n.Name) + len(".srv.hnatekmar.dev")
		}
	}

	var b strings.Builder
	fmt.Fprintf(&b, "    # The %s cluster. Node names keep the class suffix; `%s-k8s` is the alias cluster configs and\n", cfg.ClusterName, cfg.ClusterName)
	fmt.Fprintf(&b, "    # kubeconfigs point at instead of a node.\n")
	for _, n := range cfg.Nodes {
		host := n.Name + ".srv.hnatekmar.dev"
		fmt.Fprintf(&b, "    %-*s = local.dhcp_reservations[%q].address\n", maxName+2, fmt.Sprintf("%q", host), n.Name)
	}
	alias := cfg.ClusterName + "-k8s.srv.hnatekmar.dev"
	fmt.Fprintf(&b, "    %-*s = local.dhcp_reservations[%q].address\n", maxName+2, fmt.Sprintf("%q", alias), cp1)
	b.WriteString("\n")
	return b.String()
}

// ServiceWildcardBlock renders the optional `*.<cluster>-k8s.srv.hnatekmar.dev` regexp record appended to
// dns.tf. The resource label is the cluster name with hyphens turned into underscores.
func ServiceWildcardBlock(cfg *Config) string {
	label := strings.ReplaceAll(cfg.ClusterName, "-", "_")
	return fmt.Sprintf(`
# ---------------------------------------------------------------------------
# The %s cluster's *service* names — one wildcard, so a service gets a name by being deployed rather
# than by an edit here. A REGEXP record, not a plain one: RouterOS has no star wildcard for static DNS,
# and the regex list is matched BEFORE the plain records, so both ends are anchored and the leading label
# is spelled out. The address is this cluster's ingress VIP, the first address of its /24 out of the
# estate's reserved VIP block (172.16.48.0/20).
resource "routeros_ip_dns_record" "%s_cluster_services" {
  regexp  = "^.+\\.%s-k8s\\.srv\\.hnatekmar\\.dev$"
  type    = "A"
  address = "%s.1"
  ttl     = "5m"
  comment = "${local.managed_by} — the %s cluster's service names (ingress VIP)"
}
`, cfg.ClusterName, label, cfg.ClusterName, cfg.VIPBase, cfg.ClusterName)
}

func InsertReservations(filePath string, cfg *Config) error {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	idx := indexOfLine(string(content), reservationSentinel)
	if idx < 0 {
		return fmt.Errorf("dhcp sentinel %q not found in %s — was it removed?", reservationSentinel, filePath)
	}
	if cp1 := firstControlPlane(cfg.Nodes); cp1 != "" && strings.Contains(string(content), fmt.Sprintf("%q =", cp1)) {
		return fmt.Errorf("node %s already has a reservation in %s", cp1, filePath)
	}
	return insertAbove(filePath, content, idx, ReservationBlock(cfg))
}

func InsertDNS(filePath string, cfg *Config) error {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	idx := indexOfLine(string(content), dnsSentinel)
	if idx < 0 {
		return fmt.Errorf("dns sentinel %q not found in %s — was it removed?", dnsSentinel, filePath)
	}
	alias := cfg.ClusterName + "-k8s.srv.hnatekmar.dev"
	if strings.Contains(string(content), fmt.Sprintf("%q", alias)) {
		return fmt.Errorf("alias %s already present in %s", alias, filePath)
	}
	return insertAbove(filePath, content, idx, DNSBlock(cfg))
}

// AppendServiceWildcard appends the wildcard resource to the end of dns.tf. It is idempotent: if the
// resource already exists it does nothing.
func AppendServiceWildcard(filePath string, cfg *Config) error {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	label := fmt.Sprintf("%q %q", "routeros_ip_dns_record", strings.ReplaceAll(cfg.ClusterName, "-", "_")+"_cluster_services")
	if strings.Contains(string(content), label) {
		return nil
	}

	var buf bytes.Buffer
	buf.Write(content)
	if !strings.HasSuffix(string(content), "\n") {
		buf.WriteString("\n")
	}
	buf.WriteString(ServiceWildcardBlock(cfg))
	return os.WriteFile(filePath, buf.Bytes(), 0644)
}

func insertAbove(filePath string, content []byte, lineIdx int, block string) error {
	lines := strings.Split(string(content), "\n")
	if lineIdx > len(lines) {
		return fmt.Errorf("insertion point past end of %s", filePath)
	}
	out := make([]string, 0, len(lines)+2)
	out = append(out, lines[:lineIdx]...)
	out = append(out, strings.TrimRight(block, "\n"))
	out = append(out, "")
	out = append(out, lines[lineIdx:]...)
	return os.WriteFile(filePath, []byte(strings.Join(out, "\n")), 0644)
}

// indexOfLine returns the line index whose trimmed content starts with the marker, or -1.
func indexOfLine(content, marker string) int {
	for i, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), marker) {
			return i
		}
	}
	return -1
}

func firstControlPlane(nodes []Node) string {
	for _, n := range nodes {
		if n.Role == "controlplane" {
			return n.Name
		}
	}
	return ""
}

func countRole(nodes []Node, role string) int {
	count := 0
	for _, n := range nodes {
		if n.Role == role {
			count++
		}
	}
	return count
}
