# Engine on EKS

[LangSmith Engine](https://docs.langchain.com/langsmith/engine-overview) watches your
production traces, groups recurring failures into issues, diagnoses each issue
against your code, and proposes a fix. This page covers the Terraform and Helm
setup in this module. For the product setup, see
[Engine on self-hosted](https://docs.langchain.com/langsmith/engine-self-hosted).

Engine runs on the deployment that it shares with Insights
(`standalone-insights-api-server` and `standalone-insights-queue`). On AWS, Engine
calls Amazon Bedrock with the IRSA role of these two pods, so you store no
model credentials.

## Requirements

- Chart 0.17. `deploy.sh` deploys only the 0.17 chart line.
- A LangSmith license that includes the Engine entitlement. Without it,
  `platform-backend` exits at start with "the LangSmith license does not include
  Engine access".
- `enable_sandboxes = true`. Every Engine run executes in a sandbox. Terraform,
  preflight, `init-values.sh`, and `deploy.sh` all reject Engine without Sandboxes.
- `config.hostname` served with TLS at an address that the sandboxes can reach. Set
  `langsmith_domain`. The chart rejects `localhost` and in-cluster addresses.
- Outbound HTTPS from the cluster to `beacon.langchain.com` and to the Bedrock
  Mantle endpoint of the region that Engine uses (`bedrock-mantle.<region>.api.aws`).
  For LangSmith Intelligence, the cluster also needs `beacon.aws.langchain.com`. The
  NAT gateway gives this access by default. With `create_firewall = true`, add these
  names to `firewall_allowed_fqdns`.
- Access to the Engine models in Amazon Bedrock. See [Amazon Bedrock](#amazon-bedrock).

## Turn on Engine

1. Set the flags in `infra/terraform.tfvars`:

   ```hcl
   enable_sandboxes = true
   enable_engine    = true

   # Required when the shared organization has more than one workspace.
   # engine_sandbox_tenant_id = "<workspace-id>"
   ```

2. Load the keys, then apply and deploy:

   ```bash
   source infra/scripts/setup-env.sh   # creates the two Engine keys in SSM
   make apply
   make init-values
   make deploy
   ```

3. Finish the setup in LangSmith. See [Finish in LangSmith](#finish-in-langsmith).

## What the module does

| Step | Engine adds |
|---|---|
| `setup-env.sh` | `engine-encryption-key` (a Fernet key) and `engine-usage-signing-secret` (64 hex characters) in SSM under `/langsmith/<name_prefix>-<environment>/`, exported as `TF_VAR_langsmith_engine_encryption_key` and `TF_VAR_langsmith_engine_usage_signing_secret`. The script creates each key when it is not in SSM, also while `enable_engine = false`, as it does for the other add-on keys. On later runs, it uses the stored values. `manage-ssm.sh` lists both keys and treats them as stable keys. |
| `terraform apply` | The IAM role `<name_prefix>-<environment>-engine-irsa`. Its trust policy allows only the two Engine service accounts in `langsmith_namespace` (`StringEquals` on `sub` and `aud`). For the default release name, these are `langsmith-standalone-insights-api-server` and `langsmith-standalone-insights-queue`. For another `langsmith_release_name`, Terraform uses the chart's naming rule. [Engine IAM role](#engine-iam-role) lists its policies. The output `engine_irsa_role_arn` holds the role ARN. |
| `init-values.sh` | `langsmith-values-engine.yaml`, copied from `helm/values/examples/`: `engine.enabled`, `engine.workloadIdentityProviders: [bedrock]`, and the sizing of the shared deployment. In `langsmith-values-overrides.yaml`: the `eks.amazonaws.com/role-arn` annotation for the Engine role on `engineInsightsAgent.apiServer` and `engineInsightsAgent.queue`, and `engine.sandboxTenantId` and `engine.intelligenceBaseUrl` when you set them. |
| `apply-eso.sh` | The `engine_encryption_key` and `engine_usage_signing_secret` keys in the `langsmith-config` Secret, from the two SSM parameters. During a key rotation, also `engine_encryption_key_previous` (see [Keys](#keys)). The script adds each key only when its SSM parameter exists. |
| `deploy.sh` | Stops when `langsmith-config` does not have both keys. Stops when `RELEASE_NAME` or `NAMESPACE` is not the same as `langsmith_release_name` or `langsmith_namespace`, because the role trusts only those names. Loads `langsmith-values-engine.yaml` before the Insights values files, so the Insights settings win on the shared deployment. Waits for `standalone-insights-api-server`. |

The keys never go into Helm values. The chart reads them from `langsmith-config`
(`config.existingSecretName`), and it rejects `engine.usageSigningSecret` next to
`config.existingSecretName`.

## Engine IAM role

Engine and Insights share the two service accounts. When `enable_engine = true`,
both run under the Engine role, not the shared LangSmith role. The Engine role
therefore gets these policies:

| Policy | Purpose | Attached when |
|---|---|---|
| `AmazonBedrockMantleInferenceAccess` (AWS managed), or `engine_bedrock_policy_arn` | Engine's model calls through Amazon Bedrock Mantle | `enable_engine = true` |
| `langsmith-s3-access` (inline) | The same LangSmith bucket access as the shared role. The chart gives these pods the blob storage settings with no static keys. | `enable_engine = true` |
| `langsmith-bedrock-access` (inline) | The same Bedrock `InvokeModel` access as the shared role | `enable_engine = true` and `enable_bedrock_access = true` |

The default policy ARN uses the partition of the account. To grant less, create
a customer-managed policy and set `engine_bedrock_policy_arn` to its ARN.
`make preflight` checks that the policy exists. The two inline policies are
copies of the shared role's policies. The S3 policy uses the bucket ARN. The
Bedrock `InvokeModel` policy uses the `aws` partition in its resource ARNs, the
same as on the shared role.

With `s3_kms_key_arn` set, the bucket uses a customer-managed KMS key. Neither
role gets KMS permissions from this module. If the key policy names the shared
role, also allow `<name_prefix>-<environment>-engine-irsa` in the key policy.
Otherwise Insights and Engine cannot read or write objects in the bucket.

## Amazon Bedrock

Engine calls Amazon Bedrock through the Bedrock Mantle API
(`bedrock-mantle.<region>.api.aws`), not through `bedrock:InvokeModel`.
`enable_bedrock_access` alone does not give Engine access to Bedrock.

- **Model access.** Engine uses Anthropic Claude models. Make sure that the account
  can use them in Amazon Bedrock before you run **Test connection**. Anthropic models
  can need a one-time use case submission for the account in the Amazon Bedrock
  console. `AmazonBedrockMantleInferenceAccess` allows `aws-marketplace:Subscribe`
  and `aws-marketplace:ViewSubscriptions` for calls through Bedrock Mantle, so the
  first model call can create the Marketplace subscription. An SCP that denies
  these actions, or denies the region, blocks the first call.
- **Region.** Engine uses `us-east-1` unless an Organization Admin saves another
  region under **Settings > Engine > Model providers > Amazon Bedrock**. Engine does
  not use the cluster region. Save a region that has a Bedrock Mantle endpoint.
- **Credentials.** The chart lists `bedrock` in `engine.workloadIdentityProviders`, so
  LangSmith treats Amazon Bedrock as configured with no saved credentials. Any
  Organization Admin can select it.

## Choose how Engine runs its models

An Organization Admin chooses under **Settings > Engine > Model providers**.
Engine starts no runs until the admin saves this choice.

- **Amazon Bedrock in your account.** Select Amazon Bedrock, save the region, and
  run **Test connection**. Engine authenticates as the Engine role through IRSA.
- **Provider API keys.** Add keys for Anthropic, OpenAI, or the other supported
  providers on the same page. Terraform does not change.
- **LangSmith Intelligence.** LangChain runs the models. Set
  `engine_intelligence_base_url = "https://beacon.aws.langchain.com/intelligence"`,
  run `make init-values && make deploy`, and select LangSmith Intelligence.

With your own providers, leave `engine_intelligence_base_url` empty. The chart
default then only records usage. LangChain bills Engine usage in LSUs with every
option.

## Storage

Engine stores its state in the PostgreSQL and Redis of the shared deployment:

- **Default.** When Insights is off, or `insights_storage = "in-cluster"`, Engine
  uses the chart's in-cluster PostgreSQL and Redis StatefulSets
  (`langsmith-standalone-insights-postgres` and `-redis`). Each has an 8Gi PVC on the
  default StorageClass. With `create_gp3_storage_class = true`, that class is `gp3`.
- **Insights on external storage.** This applies with `insights_storage = "external"`
  or `enable_standalone_insights = true`. Engine then uses the `langsmith_insights`
  database on the shared RDS instance. It also uses Redis DB 3 on the shared
  ElastiCache instance.

A change to `enable_insights`, `enable_standalone_insights`, or `insights_storage`
can move Engine to the other storage. Engine does not copy its data to the new
storage.

## Sandbox workspace

Engine's sandboxes belong to one workspace. An install with Engine must have a
shared organization. If the shared organization has one workspace, LangSmith uses
it. If it has more than one, set `engine_sandbox_tenant_id` to the workspace ID.
Use a workspace reserved for Engine: Engine's sandboxes count against that
workspace's sandbox quotas, and its members can see and stop them.

## Finish in LangSmith

1. An Organization Admin turns on Engine under **Settings > Engine**.
2. The admin chooses the model providers (see above).
3. A user who can update tracing projects turns on Engine in a project's
   **Engine** tab.
4. Optional: to let Engine read code and open pull requests, register a GitHub App.
   See [Engine and GitHub](https://docs.langchain.com/langsmith/engine-github).

## Verify

```bash
kubectl get pods -n langsmith | grep standalone-insights
# Both service accounts must show the Engine role ARN.
kubectl get sa -n langsmith langsmith-standalone-insights-api-server langsmith-standalone-insights-queue \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'
# The pod must run with the Engine role.
kubectl exec -n langsmith deploy/langsmith-standalone-insights-api-server -- printenv AWS_ROLE_ARN
# The Secret must have both keys. This command prints key names only.
kubectl get secret langsmith-config -n langsmith \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' | grep '^engine_'
```

## Troubleshooting

- **`deploy.sh` stops: `langsmith-config` has no Engine key.** The SSM parameters do
  not exist, or ESO has not synced them. Run `source infra/scripts/setup-env.sh`, then
  `make apply-eso`, then `make deploy`.
- **`helm upgrade` fails: "engine.enabled is true but Secret "langsmith-config" has no
  ... key".** The same cause. The chart reads the Secret only during `helm upgrade`
  and `helm install`. `helm template` skips this check.
- **`deploy.sh` stops: the Engine IRSA role trusts another release or namespace.**
  Terraform made the role for `langsmith_release_name` and `langsmith_namespace`.
  Set `RELEASE_NAME` and `NAMESPACE` to the same values. Or change
  `terraform.tfvars`, then run `make apply` and `make init-values`.
- **`platform-backend` crash-loops after `make deploy`** with "the LangSmith license
  does not include Engine access". The license does not have the Engine entitlement.
  Set `enable_engine = false` and run `make init-values && make deploy`, then contact
  LangChain. After LangChain adds the entitlement, the same license key works.
- **The Engine page says that Engine is not enabled for your organization.** The
  page shows only a contact form, but the license and the Helm values include
  Engine. Contact LangChain support with your organization ID.
- **Test connection fails for Amazon Bedrock.** Check that the pods run with the
  Engine role (see [Verify](#verify)). Check model access and the saved region (see
  [Amazon Bedrock](#amazon-bedrock)). With `create_firewall = true`, check that
  `firewall_allowed_fqdns` has the Bedrock Mantle endpoint of that region.

## Keys

Keep both keys stable. ESO owns the `langsmith-config` Secret, so change the keys in
SSM, not in the Secret. ESO removes keys that it does not manage.

To rotate the encryption key:

1. Copy the current value to the SSM parameter `engine-encryption-key-previous`.
   The `&&` stops the second command when the first command cannot read the key:

   ```bash
   prev=$(./infra/scripts/manage-ssm.sh get engine-encryption-key) &&
     ./infra/scripts/manage-ssm.sh set engine-encryption-key-previous "$prev"
   ```

2. Run `make apply-eso`. It adds `engine_encryption_key_previous` to the Secret.
   The Secret now has the previous key before the current key changes.
3. Set a new Fernet key. Then make ESO read the new value now, not at the next
   hourly refresh:

   ```bash
   ./infra/scripts/manage-ssm.sh set engine-encryption-key "$(openssl rand -base64 32 | tr '+/' '-_')"
   kubectl annotate externalsecret langsmith-config -n langsmith force-sync="$(date +%s)" --overwrite
   ```

4. Restart `platform-backend`, `ingest-queue`, `standalone-insights-api-server`, and
   `standalone-insights-queue` with `kubectl rollout restart`. Pods read these keys
   only at start.
5. Wait until the runs that started before the change are complete. Then run
   `./infra/scripts/manage-ssm.sh delete engine-encryption-key-previous` and
   `make apply-eso`.

The previous key does not apply to the usage signing secret. Before you change
`engine-usage-signing-secret`, stop new Engine work and let the running analyses
finish. Then change the value, force the ESO sync as in step 3, and restart the
same four deployments. See the
[product documentation](https://docs.langchain.com/langsmith/engine-self-hosted#generate-engines-keys).

## Turn off Engine

Set `enable_engine = false`, then run `make apply && make init-values && make deploy`.
Terraform deletes the Engine role. `deploy.sh` skips `langsmith-values-engine.yaml`
and reports it as present but not enabled. The two SSM parameters and the two keys
in `langsmith-config` stay. With Insights off, Kubernetes keeps the PVCs of the
in-cluster PostgreSQL and Redis. Delete them when you do not need the data.
