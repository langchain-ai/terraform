variable "name" {
    description = "The name of the PostgreSQL Flexible Server"
    type = string
}

variable "location" {
    description = "The location of the PostgreSQL Flexible Server"
    type = string
}

variable "resource_group_name" {
    description = "The name of the resource group"
    type = string
}

variable "vnet_id" {
    description = "The ID of the VNet to link to the private DNS zone"
    type = string
}

variable "subnet_id" {
    description = "The ID of the dedicated subnet for the database. Nothing else should be in this subnet."
    type = string
}

variable "max_connections" {
    description = "The maximum number of connections to the database"
    type = number
    default = "200"
}

variable "postgres_version" {
    description = "The version of PostgreSQL to use"
    type = string
    default = "14"
}

variable "storage_mb" {
    description = "The storage size of the database"
    type = number
    default = 32768
}

variable "storage_tier" {
    description = "The storage tier of the database"
    type = string
    default = "P4"
}

variable "sku_name" {
    description = "The SKU name of the database"
    type = string
    default = "GP_Standard_D2ds_v4"
}

variable "admin_username" {
    description = "The username of the PostgreSQL Flexible Server administrator"
    type = string
}

variable "admin_password" {
    description = "The password of the PostgreSQL Flexible Server administrator"
    type = string
}
