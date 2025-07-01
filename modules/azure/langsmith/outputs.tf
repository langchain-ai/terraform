output "postgres_connection_url" {
  sensitive = true
  value     = module.postgres.connection_url
}

output "redis_connection_url" {
  sensitive = true
  value     = module.redis.connection_url
}

output "storage_account_name" {
  value = module.blob.storage_account_name
}

output "storage_container_name" {
  value = module.blob.container_name
}

# K8s managed identity for blob access.
# You will need to add annotations that reference this client ID.
# See docs for latest instructions: https://docs.smith.langchain.com/self_hosting/configuration/blob_storage#azure-blob-storage
output "storage_account_k8s_managed_identity_client_id" {
  value = module.blob.k8s_managed_identity_client_id
}
