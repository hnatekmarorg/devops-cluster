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
  value       = data.talos_machine_configuration.join.machine_configuration
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

# A kubeconfig that contains NO CREDENTIAL — which is the point. Endpoint + public CA + a kubelogin
# exec block: safe to publish, commit, or hand to anyone, because the credential is a Keycloak session
# and the authorisation is RBAC on realm roles.
#
# Only meaningful when oidc_enabled is true; otherwise it points at a cluster that will reject it.
output "oidc_kubeconfig" {
  description = "Credential-free (OIDC) kubeconfig. Requires oidc_enabled and the kubelogin plugin."
  value = var.oidc_enabled ? yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = var.cluster_name
      cluster = {
        server = var.cluster_endpoint
        # The CA comes from the generated kubeconfig (the secrets object has no `ca` attribute). It is a
        # PUBLIC certificate — showing it is exactly what makes this kubeconfig safe to publish.
        "certificate-authority-data" = yamldecode(talos_cluster_kubeconfig.this.kubeconfig_raw).clusters[0].cluster["certificate-authority-data"]
      }
    }]
    users = [{
      name = "${var.oidc_claim_prefix}${var.oidc_client_id}"
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1"
          command    = "kubelogin"
          # Required in practice: without it kubectl (depending on the client-go version) refuses or
          # misbehaves on an exec credential that may prompt. Found by using the kubeconfig, not by
          # reading the docs.
          interactiveMode    = "IfAvailable"
          provideClusterInfo = false
          args = [
            "get-token",
            "--oidc-issuer-url=${var.oidc_issuer_url}",
            "--oidc-client-id=${var.oidc_client_id}",
            "--oidc-extra-scope=email",
          ]
        }
      }
    }]
    contexts = [{
      name    = var.cluster_name
      context = { cluster = var.cluster_name, user = "${var.oidc_claim_prefix}${var.oidc_client_id}" }
    }]
    "current-context" = var.cluster_name
  }) : null
  sensitive = false
}
