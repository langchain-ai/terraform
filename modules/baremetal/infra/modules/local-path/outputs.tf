#------------------------------------------------------------------------------
# What the local-path provisioner and its two StorageClasses exposes to the
# root module:
# the StorageClass names (Delete and Retain) and the node directory.
#------------------------------------------------------------------------------

output "storage_class_delete" {
  description = "Default StorageClass (reclaimPolicy Delete) for caches and rebuildable data."
  value       = kubernetes_storage_class_v1.delete.metadata[0].name
}

output "storage_class_retain" {
  description = "StorageClass with reclaimPolicy Retain for datastores."
  value       = kubernetes_storage_class_v1.retain.metadata[0].name
}

output "node_path" {
  description = "Where volume directories live on each node."
  value       = var.node_path
}
