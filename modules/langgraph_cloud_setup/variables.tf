variable "vpc_id" {
  description = "The VPC ID to deploy LangGraph Cloud into"
  type        = string
}

variable "private_subnet_ids" {
  description = "The subnet ID to deploy LangGraph Cloud into. These will also be used to create a DB subnet."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "The subnet ID to deploy LangGraph Cloud into."
  type        = list(string)
}

variable "langsmith_data_region" {
  description = "The data region of the LangSmith account. Valid values: us, eu."
  type        = string
  default     = "us"
}

variable "langgraph_external_ids" {
  description = "External IDs for LangGraph Cloud that will be used to access resources. Needs to be able to assume role in your AWS account. These will typically be your organization ids."
  type        = list(string)
}
