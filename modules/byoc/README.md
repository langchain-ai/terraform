# LangSmith BYOC reference modules

These modules provision customer-owned resources used with LangSmith Bring Your Own Cloud (BYOC).

| AWS module | Purpose |
| --- | --- |
| [`aws/byoiam`](aws/byoiam/README.md) | Shared customer-managed IAM roles, policies, and Karpenter instance profile. |
| [`aws/byovpc`](aws/byovpc/README.md) | Reference VPC with subnets, optional regional NAT, service endpoints, control-plane PrivateLink, and flow logs. |
| [`aws/langsmith-byoc-role`](aws/langsmith-byoc-role/README.md) | Customer-side IAM roles for LangSmith control-plane reconciliation and optional break-glass access. |
| [`aws/self-hosted-byoc-migration`](aws/self-hosted-byoc-migration/README.md) | Self-hosted side of a self-hosted to BYOC migration: VPC peering to the data plane, SmithDB role access, and an optional KMS grant for run attachments. |

| GCP module | Purpose |
| --- | --- |
| [`gcp/langsmith-byoc-service-account`](gcp/langsmith-byoc-service-account/README.md) | **Beta.** Customer-side service account that the LangSmith control plane impersonates to provision BYOC data planes. Optional customer-managed service accounts (BYOIAM). |

| Azure module | Purpose |
| --- | --- |
| [`azure/langsmith-byoc-access`](azure/langsmith-byoc-access/README.md) | LangSmith service principal, and one resource group, Key Vault, and set of role assignments per data plane. |

Use the BYOVPC module when supplying your own network for a BYOC data plane. You own the network lifecycle, and provide VPC and subnet IDs when creating the data plane in LangSmith.
