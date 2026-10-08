# Engine on GKE

[LangSmith Engine](https://docs.langchain.com/langsmith/engine-overview) watches your
production traces, groups recurring failures into issues, diagnoses each issue
against your code, and proposes a fix. This page covers the Terraform and Helm
setup in this module. For the product setup, see
[Engine on self-hosted](https://docs.langchain.com/langsmith/engine-self-hosted).

Engine runs on the deployment it shares with standalone Insights
(`standalone-insights-api-server` and `standalone-insights-queue`). With Engine
on, the module creates that deployment's Cloud SQL database and Secrets and uses
its Memorystore DB, whether or not `enable_standalone_insights` is on.

## Requirements

- Chart 0.17.0 or newer. Engine on your own model providers needs 0.17. `deploy.sh`
  stops on an older `CHART_VERSION`.
- A LangSmith license that includes the Engine entitlement. Without it,
  `platform-backend` exits at start with "the LangSmith license does not include
  Engine access".
- `enable_sandboxes = true`. Every Engine run executes in a sandbox. Terraform,
  preflight, `init-values.sh`, and `deploy.sh` all reject Engine without Sandboxes.
- `postgres_source` and `redis_source` set to `"external"` (the defaults). Like standalone
  Insights, Engine uses the Insights database on Cloud SQL and a Memorystore DB.
- `langsmith_domain` served through the Gateway with TLS. Engine's sandboxes call
  LangSmith at that address.
- Outbound HTTPS from the cluster to `beacon.langchain.com`, and to your model
  providers' API endpoints, or to `beacon.aws.langchain.com` for LangSmith
  Intelligence. The cluster's Cloud NAT gives this by default.

## Turn on Engine

1. Set the flags in `infra/terraform.tfvars`:

   ```hcl
   enable_sandboxes = true
   enable_engine    = true

   # Optional: run Engine's models on Vertex AI through Workload Identity.
   engine_vertex_workload_identity = true

   # Required when the shared organization has more than one workspace.
   # engine_sandbox_tenant_id = "<workspace-id>"
   ```

2. Load the keys, then apply:

   ```bash
   source infra/scripts/setup-env.sh   # creates the two Engine keys in Secret Manager
   make apply
   make init-values
   make deploy
   ```

3. Finish the setup in LangSmith (see [Finish in LangSmith](#finish-in-langsmith)).

## What the module does

| Step | Engine adds |
|---|---|
| `setup-env.sh` | `engine-encryption-key` (a Fernet key) and `engine-usage-signing-secret` (64 hex characters) in Secret Manager, exported as `TF_VAR_langsmith_engine_encryption_key` and `TF_VAR_langsmith_engine_usage_signing_secret`. `manage-secrets.sh` treats both as stable keys. |
| `terraform apply` | The `langsmith_insights` database and the `langsmith-insights-postgres` and `langsmith-insights-redis` Secrets. With `engine_vertex_workload_identity`: the service account `<name_prefix>-<environment>-engine` with `roles/aiplatform.user`, Workload Identity for `langsmith-standalone-insights-api-server` and `-queue`, and `aiplatform.googleapis.com`. |
| `init-values.sh` | `langsmith-values-engine.yaml`, copied from `helm/values/examples/`: `engine.enabled` and the shared deployment's database wiring and sizing. In `values-overrides.yaml`: the two keys, and with Vertex AI, `engine.workloadIdentityProviders: [vertex]`, the service account annotation, and `GOOGLE_CLOUD_PROJECT` on the API server and queue. |
| `deploy.sh` | Loads `langsmith-values-engine.yaml`, and adds `engine_encryption_key` and `engine_usage_signing_secret` to the `langsmith-config` Secret. |

## Choose how Engine runs its models

An Organization Admin chooses under **Settings > Engine > Model providers**.
Engine starts no runs until this is saved.

- **Vertex AI in your project.** Set `engine_vertex_workload_identity = true`.
  Engine authenticates as `<name_prefix>-<environment>-engine` through Workload
  Identity, so no credentials are stored. Engine uses the `global` Vertex AI
  location. Enable the Claude models it needs in Vertex AI Model Garden, then
  select Google Vertex AI and run **Test connection**.
- **Provider API keys.** Add keys for Anthropic, OpenAI, or the other supported
  providers on the same page. Nothing changes in Terraform.
- **LangSmith Intelligence.** LangChain runs the models. Set
  `engine_intelligence_base_url = "https://beacon.aws.langchain.com/intelligence"`.
  Availability is limited to AWS US; contact LangChain for other clouds.

With your own providers, leave `engine_intelligence_base_url` empty. The chart
default then only records usage. LangChain bills Engine's usage in LSUs with
every option.

## Sandbox workspace

Engine's sandboxes belong to one workspace. If the shared organization has one
workspace, LangSmith uses it. If it has more than one, set
`engine_sandbox_tenant_id` to the workspace ID. Use a workspace reserved for
Engine: Engine's sandboxes count against that workspace's sandbox quotas, and
its members can see and stop them.

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
# With Vertex AI: both pods should report the Engine service account.
kubectl exec -n langsmith deploy/langsmith-standalone-insights-api-server -- \
  python -c "import urllib.request as u; print(u.urlopen(u.Request('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email', headers={'Metadata-Flavor': 'Google'})).read().decode())"
```

## Troubleshooting

- **`platform-backend` crash-loops after `make deploy`** with "the LangSmith license
  does not include Engine access". The license lacks the Engine entitlement. Set
  `enable_engine = false` and run `make init-values && make deploy`, then contact
  LangChain. Once the entitlement is added, the same key works within minutes.
- **The Engine page says Engine isn't enabled for your Organization** and offers
  only a contact form, after the license and Helm values include Engine. Contact
  LangChain support with your organization ID.
- **Test connection fails for Vertex AI.** Check that the Claude models are
  enabled in Model Garden for the `global` location, and that the pods report the
  Engine service account (see [Verify](#verify)).

## Keys

Keep both keys stable. Rotating the encryption key needs the previous key during
the change; see the
[product documentation](https://docs.langchain.com/langsmith/engine-self-hosted#generate-engines-keys).

## Turn off Engine

Set `enable_engine = false`, then run `make apply && make init-values && make deploy`.
`deploy.sh` skips `langsmith-values-engine.yaml` and reports it as present but not
enabled. The Insights database stays while `enable_standalone_insights` is on.
