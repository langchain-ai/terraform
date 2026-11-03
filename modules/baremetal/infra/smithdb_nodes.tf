#------------------------------------------------------------------------------
# Optional dedicated SmithDB nodes
#
# Nodes given role = "smithdb-cache" or "smithdb-compute" in cluster_nodes get
# the same label and NoSchedule taint the cloud modules put on their SmithDB
# node pools, so only SmithDB (which tolerates the taint) runs there. Nothing
# is created when no node has those roles.
#
# Bare metal can't create nodes, so these label and taint existing ones. The
# map key must be the node's Kubernetes name.
#------------------------------------------------------------------------------
locals {
  smithdb_node_label = {
    "smithdb-cache"   = "smithdb-local/instance-store"
    "smithdb-compute" = "smithdb-local/compute"
  }
  smithdb_dedicated_nodes = {
    for name, n in var.cluster_nodes : name => local.smithdb_node_label[n.role]
    if contains(keys(local.smithdb_node_label), n.role)
  }
}

resource "kubernetes_labels" "smithdb_node" {
  for_each = local.smithdb_dedicated_nodes

  api_version = "v1"
  kind        = "Node"
  metadata {
    name = each.key
  }
  labels = {
    (each.value) = "true"
  }

  depends_on = [terraform_data.budget]
}

resource "kubernetes_node_taint" "smithdb_node" {
  for_each = local.smithdb_dedicated_nodes

  metadata {
    name = each.key
  }
  taint {
    key    = each.value
    value  = "true"
    effect = "NoSchedule"
  }

  depends_on = [terraform_data.budget]
}
