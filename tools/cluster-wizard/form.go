package main

import (
	"fmt"
	"strconv"

	"github.com/charmbracelet/huh"
)

// RunForms walks the user through every input the two PRs need. Each form clears the screen, so a stage
// shows only its own fields.
func RunForms(cfg *Config) error {
	if err := formBasics(cfg); err != nil {
		return err
	}
	if err := formProxmox(cfg); err != nil {
		return err
	}
	if err := formAllocation(cfg); err != nil {
		return err
	}
	if err := formEditNodes(cfg); err != nil {
		return err
	}
	if err := formKarpenterStorage(cfg); err != nil {
		return err
	}
	return formSummary(cfg)
}

func formBasics(cfg *Config) error {
	name := cfg.ClusterName
	class := cfg.ClusterClass
	endpoint := cfg.Endpoint
	vip := cfg.VIPBase
	wildcard := cfg.ServiceWildcard

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Cluster name").
				Description("Lowercase letters, digits and hyphens — e.g. `staging`. Drives every directory, name and state key.").
				Placeholder("staging").
				Value(&name).
				Validate(validateClusterName),
			huh.NewSelect[string]().
				Title("Cluster class").
				Description("The RBAC tier cluster-base binds. `dev` -> sso:k8s-dev-*, `infra` -> sso:k8s-infra-*.").
				Options(
					huh.NewOption("dev   (sso:k8s-dev-viewer / sso:k8s-dev-admin)", "dev"),
					huh.NewOption("infra (sso:k8s-infra-viewer / sso:k8s-infra-admin)", "infra"),
				).
				Value(&class),
			huh.NewInput().
				Title("API endpoint").
				Description("Leave blank to derive https://<cluster>-k8s.srv.hnatekmar.dev:6443").
				Value(&endpoint),
			huh.NewInput().
				Title("VIP base (/24)").
				Description("The cluster's /24 out of the reserved 172.16.48.0/20 — e.g. `172.16.50`. dev owns .48, prod .49.").
				Placeholder("172.16.50").
				Value(&vip).
				Validate(validateVIPBase),
			huh.NewConfirm().
				Title("Publish the cluster's service wildcard?").
				Description("Adds *.<cluster>-k8s.srv.hnatekmar.dev -> ingress VIP to the router's DNS. Needed for in-cluster service names.").
				Affirmative("Yes").
				Negative("No").
				Value(&wildcard),
		).Title("New cluster — identity"),
	)
	if err := form.Run(); err != nil {
		return err
	}

	cfg.ClusterName = name
	cfg.ClusterClass = class
	cfg.Endpoint = endpoint
	cfg.VIPBase = vip
	cfg.ServiceWildcard = wildcard
	if cfg.Endpoint == "" {
		cfg.Endpoint = fmt.Sprintf("https://%s-k8s.srv.hnatekmar.dev:6443", cfg.ClusterName)
	}
	return nil
}

func formProxmox(cfg *Config) error {
	templateVMID := strconv.Itoa(cfg.TemplateVmId)
	vlanID := strconv.Itoa(cfg.VlanId)
	oidc := cfg.OidcEnabled
	health := cfg.CheckHealth

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Proxmox node").
				Description("The PVE host the VMs are cloned onto.").
				Value(&cfg.ProxmoxNode),
			huh.NewInput().
				Title("Template VM ID").
				Description("The PVE template every node is cloned from (must carry the VLAN tag).").
				Value(&templateVMID).
				Validate(validateInt),
			huh.NewInput().
				Title("Template storage").
				Description("Where the template and its clone disks live.").
				Value(&cfg.TemplateStorage),
			huh.NewInput().
				Title("VLAN ID").
				Description("The class VLAN the nodes land on.").
				Value(&vlanID).
				Validate(validateInt),
			huh.NewInput().
				Title("Talos version").
				Description("Pinned on purpose: the version decides upgrade-path and snapshot compatibility.").
				Value(&cfg.TalosVersion),
			huh.NewInput().
				Title("Storage bridge").
				Description("The 10G storage bridge (vmbr2 in this estate).").
				Value(&cfg.StorageBridge),
			huh.NewConfirm().
				Title("OIDC enabled?").
				Description("Structured AuthenticationConfiguration; the legacy --oidc-* flags are gone in 1.14.").
				Affirmative("Yes").
				Negative("No").
				Value(&oidc),
			huh.NewConfirm().
				Title("Run the module's health gate?").
				Description("Set to No: the gate cannot pass on any cluster with a hostname override (7 of 8 checks pass). The bootstrap's own waits still catch a cluster that did not come up.").
				Affirmative("Yes").
				Negative("No").
				Value(&health),
		).Title("New cluster — Proxmox and Talos"),
	)
	if err := form.Run(); err != nil {
		return err
	}

	cfg.TemplateVmId, _ = strconv.Atoi(templateVMID)
	cfg.VlanId, _ = strconv.Atoi(vlanID)
	cfg.OidcEnabled = oidc
	cfg.CheckHealth = health
	return nil
}

func formAllocation(cfg *Config) error {
	cpCount := "1"
	workerCount := "1"
	baseAddr := "172.16.40.140"
	baseMAC := "BC:24:11:0D:00:30"

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Control-plane count").
				Description("etcd wants an odd quorum. One is a dev shape; three is a cluster that survives losing a node.").
				Value(&cpCount).
				Validate(validateInt),
			huh.NewInput().
				Title("Worker count").
				Description("Karpenter covers peaks; a second worker states a steady floor.").
				Value(&workerCount).
				Validate(validateInt),
			huh.NewInput().
				Title("Base address").
				Description("First node's address; the last octet increments per node. Keep it outside the srv pools (.20-.99, .200-.250).").
				Value(&baseAddr).
				Validate(validateIPv4),
			huh.NewInput().
				Title("Base MAC").
				Description("First node's MAC; the last octet increments per node. Clones of the template, so these are ours to pick.").
				Value(&baseMAC).
				Validate(validateMAC),
		).Title("New cluster — node allocation"),
	)
	if err := form.Run(); err != nil {
		return err
	}

	cp, _ := strconv.Atoi(cpCount)
	workers, _ := strconv.Atoi(workerCount)
	if cp < 1 {
		return fmt.Errorf("need at least one control plane")
	}
	if workers < 0 {
		return fmt.Errorf("worker count cannot be negative")
	}
	cfg.Nodes = AllocateNodes(cfg.ClusterName, cp, workers, baseAddr, baseMAC)
	return nil
}

func formEditNodes(cfg *Config) error {
	for i := range cfg.Nodes {
		n := &cfg.Nodes[i]
		cores := strconv.Itoa(n.Cores)
		memory := strconv.Itoa(n.MemoryMb)
		disk := strconv.Itoa(n.DiskGb)

		form := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().Title("Name").Value(&n.Name).Validate(validateNodeName),
				huh.NewSelect[string]().
					Title("Role").
					Options(
						huh.NewOption("controlplane", "controlplane"),
						huh.NewOption("worker", "worker"),
					).
					Value(&n.Role),
				huh.NewInput().Title("MAC").Value(&n.MAC).Validate(validateMAC),
				huh.NewInput().Title("Address").Value(&n.Address).Validate(validateIPv4),
				huh.NewInput().Title("Cores").Value(&cores).Validate(validateInt),
				huh.NewInput().Title("Memory (MB)").Value(&memory).Validate(validateInt),
				huh.NewInput().Title("Disk (GB)").Value(&disk).Validate(validateInt),
				huh.NewSelect[string]().
					Title("Storage").
					Description("Control planes want local storage (etcd is fsync-bound); workers want iscsi for image room.").
					Options(
						huh.NewOption("local-lvm", "local-lvm"),
						huh.NewOption("iscsi", "iscsi"),
					).
					Value(&n.Storage),
			).Title(fmt.Sprintf("Node %d of %d — %s", i+1, len(cfg.Nodes), n.Name)),
		)
		if err := form.Run(); err != nil {
			return err
		}

		n.Cores, _ = strconv.Atoi(cores)
		n.MemoryMb, _ = strconv.Atoi(memory)
		n.DiskGb, _ = strconv.Atoi(disk)
	}
	return nil
}

func formKarpenterStorage(cfg *Config) error {
	nfs := cfg.StorageNfs
	csi := cfg.StorageTruenasCsi

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Karpenter CPU limit").
				Description("The cluster's autoscaling ceiling, in cores.").
				Value(&cfg.KarpenterCpu),
			huh.NewInput().
				Title("Karpenter memory limit").
				Description("The cluster's autoscaling ceiling, e.g. 128Gi.").
				Value(&cfg.KarpenterMemory),
			huh.NewConfirm().
				Title("NFS (RWX) storage enabled?").
				Description("The shared NAS tier for volumes several pods must mount.").
				Affirmative("Yes").Negative("No").
				Value(&nfs),
			huh.NewConfirm().
				Title("TrueNAS NVMe-oF (RWO) storage enabled?").
				Description("The durable block tier for state that must outlive a node.").
				Affirmative("Yes").Negative("No").
				Value(&csi),
		).Title("New cluster — autoscaling and storage"),
	)
	if err := form.Run(); err != nil {
		return err
	}

	cfg.StorageNfs = nfs
	cfg.StorageTruenasCsi = csi
	return nil
}

func formSummary(cfg *Config) error {
	summary := fmt.Sprintf(
		"Cluster:   %s\nClass:     %s\nEndpoint:  %s\nVIP block: %s.0/24 (ingress %s.1)\nWildcard:  %v\n\nNodes:\n%s\n\nPR 1 branch: feat/%s-router-prereqs  (routeros/dhcp.tf + dns.tf)\nPR 2 branch: feat/%s-cluster-root    (stacked on PR 1)",
		cfg.ClusterName, cfg.ClusterClass, cfg.Endpoint, cfg.VIPBase, cfg.VIPBase, cfg.ServiceWildcard,
		nodeTable(cfg.Nodes), cfg.ClusterName, cfg.ClusterName,
	)
	ok := false
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title("Write these two branches?").
				Description(summary).
				Affirmative("Write").
				Negative("Abort").
				Value(&ok),
		),
	)
	if err := form.Run(); err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("aborted by user")
	}
	return nil
}

func nodeTable(nodes []Node) string {
	out := ""
	for _, n := range nodes {
		out += fmt.Sprintf("  %-14s %-13s %-18s %-17s %2dc / %5dMB / %3dGB  %s\n",
			n.Name, n.Role, n.Address, n.MAC, n.Cores, n.MemoryMb, n.DiskGb, n.Storage)
	}
	return out
}
