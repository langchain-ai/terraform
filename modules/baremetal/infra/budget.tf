#------------------------------------------------------------------------------
# Budget gate
#
# Fails `terraform plan` when the sizing profile can't be scheduled on the
# declared cluster_nodes, before anything is created. Without this, an
# oversized profile shows up much later as pods stuck in Pending.
#
# Each node pool (workers, and the optional smithdb-cache / smithdb-compute)
# is checked on its own: its pods against its nodes. Disk only with local-path:
# on the cluster's own StorageClass, volumes live on its storage, not a node's. Every datastore, add-on,
# and Helm-dependent step depends on this resource, so nothing is built on a
# cluster that can't hold it.
#------------------------------------------------------------------------------
resource "terraform_data" "budget" {
  input = local.budget_summary

  lifecycle {
    precondition {
      condition     = var.object_store_source == "in-cluster" || (!var.enable_sandboxes && var.object_store_endpoint != "" && var.object_store_buckets.smithdb != var.object_store_buckets.blobs)
      error_message = "object_store_source = external needs object_store_endpoint and two different buckets, and cannot run with enable_sandboxes: the sandboxes' JuiceFS bucket stays on the in-cluster RustFS."
    }

    precondition {
      condition     = length(local.app_requests_missing) == 0
      error_message = "The ${var.sizing_profile} app sizing file sets no requests for: ${join(", ", local.app_requests_missing)}. The budget can't account for them."
    }

    precondition {
      condition     = alltrue([for st in values(local.pool_stats) : st.largest_pod_cpu <= st.largest_node_cpu])
      error_message = "${join("; ", [for pool, st in local.pool_stats : "${st.largest_cpu_pod} requests ${st.largest_pod_cpu} CPU, but the largest ${pool} node has ${st.largest_node_cpu}" if st.largest_pod_cpu > st.largest_node_cpu])}. It would stay Pending. Choose a smaller sizing_profile or add bigger nodes."
    }

    precondition {
      condition     = alltrue([for st in values(local.pool_stats) : st.largest_pod_mem <= st.largest_node_mem])
      error_message = "${join("; ", [for pool, st in local.pool_stats : "${st.largest_mem_pod} requests ${st.largest_pod_mem} Gi memory, but the largest ${pool} node has ${st.largest_node_mem} Gi" if st.largest_pod_mem > st.largest_node_mem])}. It would stay Pending."
    }

    precondition {
      condition     = !var.install_local_path || alltrue([for st in values(local.pool_stats) : st.largest_pod_disk <= st.largest_node_dsk])
      error_message = "${join("; ", [for pool, st in local.pool_stats : "${st.largest_disk_pod} needs a ${st.largest_pod_disk} Gi volume, but the largest ${pool} node has ${st.largest_node_dsk} Gi of disk" if st.largest_pod_disk > st.largest_node_dsk])}. local-path volumes live on one node."
    }

    precondition {
      condition     = alltrue([for st in values(local.pool_stats) : st.requested_cpu <= st.ceiling_cpu])
      error_message = "${join("; ", [for pool, st in local.pool_stats : "${pool} pool requests ${format("%.2f", st.requested_cpu)} CPU; ceiling ${format("%.2f", st.ceiling_cpu)}" if st.requested_cpu > st.ceiling_cpu])} (ceiling = (node CPU - node_reserved) x max_request_ratio)."
    }

    precondition {
      condition     = alltrue([for st in values(local.pool_stats) : st.requested_mem_gi <= st.ceiling_mem_gi])
      error_message = "${join("; ", [for pool, st in local.pool_stats : "${pool} pool requests ${format("%.1f", st.requested_mem_gi)} Gi memory; ceiling ${format("%.1f", st.ceiling_mem_gi)} Gi" if st.requested_mem_gi > st.ceiling_mem_gi])}."
    }

    precondition {
      condition     = !var.install_local_path || alltrue([for st in values(local.pool_stats) : st.requested_disk <= st.ceiling_disk])
      error_message = "${join("; ", [for pool, st in local.pool_stats : "${pool} pool needs ${format("%.0f", st.requested_disk)} Gi of volumes and cache; ceiling ${format("%.0f", st.ceiling_disk)} Gi" if st.requested_disk > st.ceiling_disk])}."
    }
  }
}
