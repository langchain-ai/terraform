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
resource "kubernetes_labels" "smithdb_node" {
  for_each = module.values.smithdb_dedicated_nodes

  api_version = "v1"
  kind        = "Node"
  metadata {
    name = each.key
  }
  labels = {
    (each.value) = "true"
  }
  # Its own field manager, as sandboxes.tf's: under the provider's default the label and the taint were
  # one owner of the Node, and each apply dropped the other's field, so no plan converged (Dzmitry
  # Dubarau's review of #488).
  field_manager = "langsmith-smithdb-label"

  depends_on = [terraform_data.budget]
}

data "kubernetes_nodes" "smithdb_node" {
  count = length(module.values.smithdb_dedicated_nodes) > 0 ? 1 : 0
}

locals {
  # Every taint on a SmithDB node but ours, as key:effect: the force below writes the whole taint list.
  smithdb_node_other_taints = {
    for n in try(data.kubernetes_nodes.smithdb_node[0].nodes, []) : n.metadata[0].name => [
      for t in n.spec[0].taints : "${t.key}:${t.effect}" if t.key != module.values.smithdb_dedicated_nodes[n.metadata[0].name]
    ] if contains(keys(module.values.smithdb_dedicated_nodes), n.metadata[0].name)
  }
}

resource "kubernetes_node_taint" "smithdb_node" {
  for_each = module.values.smithdb_dedicated_nodes

  # A Node's taints are one atomic list owned by the kubelet that registered it (field manager k3s on
  # k3s, rke2 on RKE2). Without force the apply stops on that conflict and the pool is never tainted
  # (Dzmitry Dubarau's review of #488; the same failure as sandboxes.tf, reed-lab, 2026-10-29).
  force         = true
  field_manager = "langsmith-smithdb-taint"
  metadata {
    name = each.key
  }
  taint {
    key    = each.value
    value  = "true"
    effect = "NoSchedule"
  }

  lifecycle {
    precondition {
      condition     = length(lookup(local.smithdb_node_other_taints, each.key, [])) == 0
      error_message = "SmithDB node ${each.key} carries other taints (${join(", ", lookup(local.smithdb_node_other_taints, each.key, []))}). The SmithDB taint replaces the node's whole taint list, and removing it clears the list, so a dedicated SmithDB node carries no other taint: remove them, or choose another node. A node.kubernetes.io taint means the node is cordoned or not ready: uncordon it or wait, then plan again."
    }
  }

  depends_on = [terraform_data.budget]
}
