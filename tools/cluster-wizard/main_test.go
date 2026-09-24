package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sampleConfig() *Config {
	return &Config{
		ClusterName:       "staging",
		ClusterClass:      "dev",
		Endpoint:          "https://staging-k8s.srv.hnatekmar.dev:6443",
		VIPBase:           "172.16.50",
		ProxmoxNode:       "balteus",
		TemplateVmId:      9000,
		TemplateStorage:   "iscsi",
		VlanId:            40,
		TalosVersion:      "v1.14.1",
		StorageBridge:     "vmbr2",
		OidcEnabled:       true,
		CheckHealth:       false,
		ServiceWildcard:   true,
		KarpenterCpu:      "64",
		KarpenterMemory:   "256Gi",
		StorageNfs:        true,
		StorageTruenasCsi: true,
		Nodes: []Node{
			{Name: "staging-cp1", Role: "controlplane", Address: "172.16.40.150", MAC: "BC:24:11:0D:00:50", Cores: 4, MemoryMb: 8192, DiskGb: 40, Storage: "local-lvm"},
			{Name: "staging-w1", Role: "worker", Address: "172.16.40.151", MAC: "BC:24:11:0D:00:51", Cores: 8, MemoryMb: 16384, DiskGb: 80, Storage: "iscsi"},
		},
	}
}

func TestAllocateNodes(t *testing.T) {
	nodes := AllocateNodes("test", 3, 1, "172.16.40.100", "BC:24:11:0D:00:10")
	if len(nodes) != 4 {
		t.Fatalf("expected 4 nodes, got %d", len(nodes))
	}
	if nodes[0].Name != "test-cp1" || nodes[0].Address != "172.16.40.100" || nodes[0].MAC != "BC:24:11:0D:00:10" {
		t.Errorf("node 0 mismatch: %+v", nodes[0])
	}
	if nodes[3].Name != "test-w1" || nodes[3].Address != "172.16.40.103" || nodes[3].MAC != "BC:24:11:0D:00:13" {
		t.Errorf("node 3 mismatch: %+v", nodes[3])
	}
	if nodes[3].Storage != "iscsi" || nodes[0].Storage != "local-lvm" {
		t.Errorf("storage defaults wrong: %+v", nodes)
	}
}

func TestValidate(t *testing.T) {
	cfg := sampleConfig()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("sample config should be valid: %v", err)
	}
	cfg.VIPBase = "10.0.0"
	if err := cfg.Validate(); err == nil {
		t.Error("VIP base outside 172.16.48.0/20 should fail")
	}
}

func TestRender(t *testing.T) {
	files, err := RenderAll(sampleConfig())
	if err != nil {
		t.Fatal(err)
	}

	mainTf, ok := files["terraform/clusters/staging/main.tf"]
	if !ok {
		t.Fatal("main.tf not rendered")
	}
	for _, want := range []string{
		`cluster_name     = "staging"`,
		`cluster_endpoint = "https://staging-k8s.srv.hnatekmar.dev:6443"`,
		`"staging-cp1"`,
		`address   = "172.16.40.150"`,
		`"172.16.40.151",`,
		`"staging-w1.srv.hnatekmar.dev",`,
	} {
		if !strings.Contains(mainTf, want) {
			t.Errorf("main.tf missing %q", want)
		}
	}

	for _, f := range []string{"versions.tf", "providers.tf", "backend.tf"} {
		path := "terraform/clusters/staging/" + f
		if _, ok := files[path]; !ok {
			t.Errorf("%s not rendered", path)
		}
	}
	if !strings.Contains(files["terraform/clusters/staging/backend.tf"], "cluster-staging/terraform.tfstate") {
		t.Error("backend.tf missing the cluster state key")
	}

	base := files["bootstrap/argocd/staging/cluster-base.yaml"]
	for _, want := range []string{
		"clusterClass: dev",
		"clusterName: staging",
		"storeName: local-staging",
		"mountPath: kubernetes-staging",
		"vaultRole: local-staging",
		"172.16.50.1-172.16.50.254",
		"ingressVIP: 172.16.50.1",
		`cpu: "64"`,
		"memory: 256Gi",
	} {
		if !strings.Contains(base, want) {
			t.Errorf("cluster-base.yaml missing %q", want)
		}
	}
	// cluster-base must not accidentally pull in custom resources from PR 1.
	if strings.Contains(base, "routeros_ip_dns_record") {
		t.Error("cluster-base.yaml should not contain router resources")
	}
}

func TestMultiControlPlaneNote(t *testing.T) {
	cfg := sampleConfig()
	cfg.Nodes = []Node{
		{Name: "staging-cp1", Role: "controlplane", Address: "172.16.40.150", MAC: "BC:24:11:0D:00:50", Cores: 4, MemoryMb: 8192, DiskGb: 40, Storage: "local-lvm"},
		{Name: "staging-cp2", Role: "controlplane", Address: "172.16.40.151", MAC: "BC:24:11:0D:00:51", Cores: 4, MemoryMb: 8192, DiskGb: 40, Storage: "local-lvm"},
	}
	files, err := RenderAll(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(files["terraform/clusters/staging/main.tf"], "single\n  # point of failure") {
		t.Error("multi-control-plane main.tf should warn about the non-VIP endpoint")
	}
}

func TestRouterInsertion(t *testing.T) {
	dir := t.TempDir()
	dhcpFile := filepath.Join(dir, "dhcp.tf")
	content := "locals {\n  dhcp_reservations = {\n" +
		"    \"existing\" = { mac = \"AA:BB:CC:DD:EE:FF\", address = \"172.16.40.10\", class = \"srv\" }\n" +
		"    # cluster-wizard:insert-reservations — new cluster node reservations go ABOVE this line,\n" +
		"  }\n}\n"
	if err := os.WriteFile(dhcpFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := sampleConfig()
	if err := InsertReservations(dhcpFile, cfg); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dhcpFile)
	text := string(got)
	if !strings.Contains(text, `"staging-cp1"`) || !strings.Contains(text, `address = "172.16.40.150"`) {
		t.Errorf("reservation not inserted correctly:\n%s", text)
	}
	if !strings.Contains(text, "# cluster-wizard:insert-reservations") {
		t.Error("sentinel should be preserved")
	}
	if strings.Index(text, `"staging-cp1"`) > strings.Index(text, "# cluster-wizard:insert-reservations") {
		t.Error("entries must land ABOVE the sentinel")
	}

	// Second insertion must abort rather than duplicate.
	if err := InsertReservations(dhcpFile, cfg); err == nil {
		t.Error("expected an error on a second insertion")
	}
}

func TestDNSInsertionAndWildcard(t *testing.T) {
	dir := t.TempDir()
	dnsFile := filepath.Join(dir, "dns.tf")
	content := "locals {\n  dns_records = {\n" +
		"    \"existing.srv.hnatekmar.dev\" = \"172.16.40.10\"\n" +
		"    # cluster-wizard:insert-dns-records — new cluster DNS records go ABOVE this line,\n" +
		"  }\n}\n"
	if err := os.WriteFile(dnsFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := sampleConfig()
	if err := InsertDNS(dnsFile, cfg); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dnsFile)
	text := string(got)
	for _, want := range []string{
		`"staging-cp1.srv.hnatekmar.dev" = local.dhcp_reservations["staging-cp1"].address`,
		`"staging-k8s.srv.hnatekmar.dev" = local.dhcp_reservations["staging-cp1"].address`,
	} {
		if !strings.Contains(text, want) {
			t.Errorf("dns record missing %q", want)
		}
	}

	if err := AppendServiceWildcard(dnsFile, cfg); err != nil {
		t.Fatal(err)
	}
	if err := AppendServiceWildcard(dnsFile, cfg); err != nil {
		t.Fatalf("wildcard append should be idempotent: %v", err)
	}
	got, _ = os.ReadFile(dnsFile)
	text = string(got)
	if !strings.Contains(text, `resource "routeros_ip_dns_record" "staging_cluster_services"`) {
		t.Errorf("wildcard resource missing:\n%s", text)
	}
	if got := strings.Count(text, `"staging_cluster_services"`); got != 1 {
		t.Errorf("wildcard resource should appear once, got %d", got)
	}
}

func TestCollisionDetection(t *testing.T) {
	dir := t.TempDir()
	dhcpFile := filepath.Join(dir, "dhcp.tf")
	content := "locals {\n  dhcp_reservations = {\n" +
		"    \"existing\" = { mac = \"BC:24:11:0D:00:50\", address = \"172.16.40.150\", class = \"srv\" }\n" +
		"  }\n}\n"
	if err := os.WriteFile(dhcpFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	if err := CheckCollisions(dhcpFile, sampleConfig()); err == nil {
		t.Error("expected a collision on address 172.16.40.150")
	}
}
