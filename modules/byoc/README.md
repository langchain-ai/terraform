# LangSmith BYOC reference modules

These modules provision customer-owned resources used with LangSmith Bring Your Own Cloud (BYOC).

| AWS module | Purpose |
| --- | --- |
| [`aws/byovpc`](aws/byovpc/README.md) | Reference VPC with subnets, optional regional NAT, service endpoints, control-plane PrivateLink, and flow logs. |
| [`aws/langsmith-byoc-role`](aws/langsmith-byoc-role/README.md) | Customer-side IAM roles for LangSmith control-plane reconciliation and optional break-glass access. |

Use the BYOVPC module when supplying your own network for a BYOC data plane. You own the network lifecycle, and provide VPC and subnet IDs when creating the data plane in LangSmith.
