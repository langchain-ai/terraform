# Engine on bare metal

[LangSmith Engine](https://docs.langchain.com/langsmith/engine-overview) watches your production traces, groups
recurring failures into issues, diagnoses each issue against your code, and proposes a fix. This page covers the
Terraform and Helm setup in this module. For the product setup, see
[Engine on self-hosted](https://docs.langchain.com/langsmith/engine-self-hosted).

Engine runs on the deployment that it shares with Insights (`standalone-insights-api-server` and
`standalone-insights-queue`), and every Engine run executes in a sandbox. On bare metal there is no cloud identity for
Engine to call a model provider with, so it uses provider API keys, your own LLM gateway, or LangSmith Intelligence
(see [Choose how Engine runs its models](#choose-how-engine-runs-its-models)).

## Requirements

- Chart 0.17. A model gateway needs chart 0.17.31 or later.
- A LangSmith license that includes the Engine entitlement. Without it, `platform-backend` exits at start with "the
  LangSmith license does not include Engine access".
- Sandboxes: `enable_sandboxes = true` with `sandbox_hosts` (see the README, "Sandboxes and Engine"). `make plan`
  refuses Engine without them.
- `langsmith_url_scheme = "https"` and `langsmith_domain`: the sandboxes call LangSmith at that name. It must resolve
  from inside the cluster and from the sandboxes, and they must trust its certificate. A certificate from a private CA
  needs that CA in the chart's `config.customCa` (see
  [custom TLS certificates](https://docs.langchain.com/langsmith/self-host-custom-tls-certificates)), with the public
  roots kept, or the calls to `beacon.langchain.com` and to model providers stop verifying.
- Outbound HTTPS from the cluster to `beacon.langchain.com`, and to the model providers or gateway Engine uses. The
  sandboxes also need public PyPI and npm, or mirrors of them.

## Turn on Engine

1. Set the flags in `infra/terraform.tfvars`:

   ```hcl
   enable_sandboxes = true
   enable_engine    = true

   # Required when the shared organization has more than one workspace.
   # engine_sandbox_tenant_id = "<workspace-id>"
   ```

2. Make the keys, then apply and deploy:

   ```bash
   make setup-env      # creates the two Engine keys in infra/.secrets.env
   make apply
   make init-values
   make deploy
   ```

3. Finish the setup in LangSmith. See [Finish in LangSmith](#finish-in-langsmith).

## What the module does

| Step | Engine adds |
|---|---|
| `make plan`, `make apply` | Refuses Engine without Sandboxes, or without `https` and a domain. Sizes the Insights deployment Engine runs on in the budget, whether or not Insights is on. |
| `make setup-env` | `ENGINE_ENCRYPTION_KEY` (a Fernet key) and `ENGINE_USAGE_SIGNING_SECRET` (64 hex characters) in `infra/.secrets.env`, made once and kept. With a gateway URL set, it also asks for `ENGINE_GATEWAY_API_KEY`. |
| `make init-values` | `engine.enabled`, `engine.intelligenceBaseUrl` and, when set, `engine.sandboxTenantId`; with a gateway, its settings on both Engine workloads and `ENGINE_GATEWAY_APIS` in `commonEnv`. |
| `make deploy` | The keys `engine_encryption_key` and `engine_usage_signing_secret` in the `langsmith-config` Secret. With a gateway, the `engine-model-gateway` Secret, which both Engine workloads mount. |

The keys never go into Helm values. The chart reads them from `langsmith-config` (`config.existingSecretName`).

## Choose how Engine runs its models

An Organization Admin chooses under **Settings > Engine > Model providers**. Engine starts no runs until the admin
saves this choice. See [Engine model providers](https://docs.langchain.com/langsmith/engine-self-hosted-model-providers).

- **Provider API keys.** Add keys for Anthropic, OpenAI or another listed provider on that page, and run **Test
  connection**. Terraform does not change.
- **Your LLM gateway.** Set the URL of each API it serves, then run `make setup-env` (it asks the gateway's key),
  `make apply`, `make init-values` and `make deploy`:

  ```hcl
  engine_gateway_anthropic_base_url = "https://<gateway-host>/anthropic"   # Engine calls <url>/v1/messages
  engine_gateway_openai_base_url    = "https://<gateway-host>/openai/v1"   # Engine calls <url>/responses
  # engine_gateway_auth_header      = "x-api-key"   # default: Authorization: Bearer <key>
  ```

  Set one or both. The gateway must serve the Anthropic Messages API, the OpenAI Responses API or both, forward the
  `anthropic-beta` header and the body unchanged, return token usage on every response, and answer at the URL itself:
  Engine follows no redirect, so `make plan` refuses a URL that is not `https://`. Then select **Model gateway** on
  the Model providers page and run **Test connection**. Engine reads the key file at the start of each run: to rotate
  the key, change `ENGINE_GATEWAY_API_KEY` in `infra/.secrets.env` and run `make deploy`, with no restart.
- **LangSmith Intelligence.** LangChain runs the models. Set
  `engine_intelligence_base_url = "https://beacon.aws.langchain.com/intelligence"`, run
  `make init-values && make deploy`, and select LangSmith Intelligence. With your own providers or gateway, keep the
  default, which only records usage. Air-gapped, set it to `""`.

LangChain bills Engine usage in LSUs with every option.

## Sandbox workspace

Engine's sandboxes belong to one workspace. If the shared organization has one workspace, LangSmith uses it. If it has
more than one, set `engine_sandbox_tenant_id` to the workspace ID. Use a workspace reserved for Engine: its sandboxes
count against that workspace's sandbox quotas, and its members can see and stop them.

## Finish in LangSmith

1. An Organization Admin turns on Engine under **Settings > Engine**.
2. The admin chooses the model providers (see above).
3. A user who can update tracing projects turns on Engine in a project's **Engine** tab.
4. Optional: to let Engine read code and open pull requests, register a GitHub App. See
   [Engine and GitHub](https://docs.langchain.com/langsmith/engine-github).

## Verify

```bash
kubectl --context <ctx> -n langsmith get pods | grep standalone-insights
# The Secret must have both keys. This prints key names only.
kubectl --context <ctx> -n langsmith get secret langsmith-config \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' | grep '^engine_'
# With a gateway: the Secret exists, and both workloads have its URL.
kubectl --context <ctx> -n langsmith get secret engine-model-gateway -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
kubectl --context <ctx> -n langsmith exec deploy/langsmith-standalone-insights-queue -- printenv | grep '^ENGINE_GATEWAY_'
```

Then start an Engine analysis on a project with traces.

## Troubleshooting

- **`platform-backend` crash-loops after `make deploy`** with "the LangSmith license does not include Engine access".
  The license does not have the Engine entitlement. Set `enable_engine = false`, run `make init-values && make
  deploy`, then contact LangChain. After LangChain adds the entitlement, the same license key works.
- **The Engine page says that Engine is not enabled for your organization.** The license and the Helm values include
  Engine, but the page shows only a contact form. Contact LangChain support with your organization ID.
- **Model gateway is not on the Model providers page.** `ENGINE_GATEWAY_APIS` is not set: no gateway URL in
  `terraform.tfvars`, or the chart is older than 0.17.31.
- **Engine runs fail with a TLS or name error from the sandbox.** The sandboxes cannot resolve `langsmith_domain` or do
  not trust its certificate. See [Requirements](#requirements).
- **`make deploy` stops: `ENGINE_GATEWAY_API_KEY` is not set.** Run `make setup-env`, then `make deploy`.

## Keys

Keep `ENGINE_ENCRYPTION_KEY` and `ENGINE_USAGE_SIGNING_SECRET` stable, and back them up with `infra/.secrets.env`. To
rotate either, follow the [product documentation](https://docs.langchain.com/langsmith/engine-self-hosted#generate-engines-keys):
change the value in `infra/.secrets.env`, run `make deploy`, and restart `platform-backend`, `ingest-queue`,
`standalone-insights-api-server` and `standalone-insights-queue`, which read the keys only at start.

## Turn off Engine

Set `enable_engine = false` and run `make apply`, `make init-values` and `make deploy`. The keys stay in
`infra/.secrets.env`, so turning Engine on again keeps its data readable.
