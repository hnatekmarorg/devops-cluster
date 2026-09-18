# What the factory hands to everything downstream. Three of these are the seams that make a new cluster
# immediately useful rather than a machine you then have to dress by hand.

output "kubeconfig" {
  description = "Kubeconfig for the new cluster. Its certificate-authority-data is also what the vault needs to validate this cluster's tokens."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "client_configuration" {
  description = "Talos client configuration (CA + client cert)."
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "join_config" {
  description = <<-EOT
    The worker machine config, ready to be the `user-data` key of the Secret that Karpenter's
    ProxmoxNodeClass references. This is the seam that makes burst nodes possible: the NodeClass hands it
    to each clone as a cloud-init CD-ROM.

      kubectl --kubeconfig <kubeconfig> -n kube-system create secret generic <name> \
        --from-file=user-data=<file>
  EOT
  value       = data.talos_machine_configuration.worker.machine_configuration
  sensitive   = true
}

output "endpoint" {
  description = "The API endpoint the cluster advertises — use it for ArgoCD's cluster registration."
  value       = var.cluster_endpoint
}

output "nodes" {
  description = "Where the nodes ended up, keyed by name."
  value       = { for n in var.nodes : n.name => { role = n.role, address = n.address, mac = n.mac } }
}

output "cluster_name" {
  value = var.cluster_name
}
