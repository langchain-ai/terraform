# LangGraph Cloud BYOC Setup
This module sets up the LangGraph Cloud BYOC (Bring Your Own Cloud) environment.
It will provision the necessary resources in your account and also grant the necessary permissions to the LangSmith Role.
This role will be used by the LangSmith service to interact with your cloud environment.

- For `langsmith_data_region`, specify `"us"` or `"eu"` based on your LangSmith account's data region.
- For `langgraph_external_ids`, specify your LangSmith Organization ID(s).
- For `create_elb_service_linked_role`, specify `true` to create the Elastic Load Balancing service-linked role. Specify `false` if the Elastic Load Balancing service-linked role already exists. Note: the service-linked role may have been created by some other AWS service/workflow outside of this Terraform module.

For license checking, services deployed on the ECS cluster must have access to the public internet (i.e. egress). This Terraform module does not set up the required infrastructure to enable this. A NAT gateway or other alternative may be required and should be configured outside the scope of this module.

## Usage
```hcl
module "langgraph_cloud_setup" {
  source = "github.com/langchain-ai/terraform//modules/langgraph_cloud_setup"

  vpc_id                         = "YOUR VPC ID"
  private_subnet_ids             = ["YOUR PRIVATE SUBNET IDS"]
  public_subnet_ids              = ["YOUR PUBLIC SUBNET IDS"]
  langsmith_data_region          = "us"
  langgraph_external_ids         = ["Your LangSmith Organization ID"]
  create_elb_service_linked_role = true
}
```

**Note**: The resources defined in the Terraform module must be created exactly as specified. For example, resource names must be specified exactly as they are in the Terraform module (e.g. case sensitive).
