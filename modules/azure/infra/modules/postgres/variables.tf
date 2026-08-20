variable "name" {
  description = "The name of the PostgreSQL Flexible Server"
  type        = string
}

variable "location" {
  description = "The location of the PostgreSQL Flexible Server"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "vnet_id" {
  description = "The ID of the VNet to link to the private DNS zone"
  type        = string
}

variable "subnet_id" {
  description = "The ID of the dedicated subnet for the database. Nothing else should be in this subnet."
  type        = string
}

variable "max_connections" {
  description = "The maximum number of connections to the database"
  type        = number
  default     = "200"
}

variable "postgres_version" {
  description = "The version of PostgreSQL to use"
  type        = string
  default     = "14"
}

variable "storage_mb" {
  description = "The storage size of the database"
  type        = number
  default     = 32768
}

variable "storage_tier" {
  description = "The storage tier of the database"
  type        = string
  default     = "P4"
}

variable "backup_retention_days" {
  description = "The backup retention period in days"
  type        = number
  default     = 7
}

variable "sku_name" {
  description = "The SKU name of the database"
  type        = string
  default     = "GP_Standard_D2ds_v4"
}

variable "admin_username" {
  description = "The username of the PostgreSQL Flexible Server administrator"
  type        = string
}

variable "admin_password" {
  description = "The password of the PostgreSQL Flexible Server administrator"
  type        = string
}

variable "database_name" {
  description = "The name of the LangSmith database to create and connect to"
  type        = string
  default     = "langsmith"
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}

variable "availability_zone" {
  type        = string
  description = "Primary availability zone for the Postgres server (\"1\", \"2\", or \"3\"). The default, empty, lets Azure choose, which is required for SKUs that are not offered in every zone of the region."
  default     = ""
}

variable "high_availability" {
  type        = bool
  description = "Enable ZoneRedundant HA. Azure places the standby unless standby_availability_zone names a zone. Requires a GeneralPurpose or MemoryOptimized SKU."
  default     = false
}

variable "standby_availability_zone" {
  type        = string
  description = "Pin the HA standby to a zone. Empty lets Azure choose. A non-empty value also enables HA on its own, so a configuration written before high_availability existed keeps its standby."
  default     = ""
}

variable "geo_redundant_backup_enabled" {
  type        = bool
  description = "Enable geo-redundant backups. Requires paired Azure region support."
  default     = false
}

variable "enable_fleet" {
  type        = bool
  description = "Create a dedicated 'langsmith_fleet' database for standalone Fleet (chart v0.15+)."
  default     = false
}
