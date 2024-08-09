variable "langgraph_role_arn" {
  description = "Role ARN for LangGraph Cloud that will be used to access resources. Needs to be able to assume role in your AWS account."
  type        = string
}
