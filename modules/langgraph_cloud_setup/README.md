# LangGraph Cloud BYOC Setup
This module sets up the LangGraph Cloud BYOC (Bring Your Own Cloud) environment.
It will provision the necessary resources in your account and also grant the necessary permissions to the LangSmith Role.
This role will be used by the LangSmith service to interact with your cloud environment.

## Usage
```hcl
module "langgraph_cloud_setup" {
  source = "github.com/langchain-ai/terraform//modules/langgraph_cloud_setup"

  vpc_id                 = "YOUR VPC ID"
  private_subnet_ids     = ["YOUR PRIVATE SUBNET IDS"]
  public_subnet_ids      = ["YOUR PUBLIC SUBNET IDS"]
  langgraph_role_arn     = "arn:aws:iam::640174622193:role/HostBackendRoleProd"
  langgraph_external_ids = ["Your Organization ID"]
}
```
