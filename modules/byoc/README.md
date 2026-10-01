# LangSmith BYOC reference modules

These modules provision customer-owned resources used with LangSmith Bring Your Own Cloud (BYOC).

| AWS module | Purpose |
| --- | --- |
| [`aws/byoiam`](aws/byoiam/README.md) | Shared customer-managed IAM roles, policies, and Karpenter instance profile. |
| [`aws/byovpc`](aws/byovpc/README.md) | Reference VPC with subnets, optional regional NAT, service endpoints, control-plane PrivateLink, and flow logs. |
| [`aws/langsmith-byoc-role`](aws/langsmith-byoc-role/README.md) | Customer-side IAM roles for LangSmith control-plane reconciliation and optional break-glass access. |

| Azure module | Purpose |
| --- | --- |
| [`azure/langsmith-byoc-identity`](azure/langsmith-byoc-identity/README.md) | Customer-managed identity that LangSmith signs in as, with a federated credential bound to your LangSmith organization. |

Use the BYOVPC module when supplying your own network for a BYOC data plane. You own the network lifecycle, and provide VPC and subnet IDs when creating the data plane in LangSmith.
