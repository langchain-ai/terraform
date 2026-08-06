# Migrating from chart 0.15 to chart 0.16

These modules wrap the LangSmith Helm chart, so a chart minor bump changes the
values files the modules ship. This note covers what changed, what you have to do,
and what the modules now do for you.

Chart 0.16 rejects the removed and renamed keys with a template error instead of
ignoring them, so an un-migrated values file fails at `helm upgrade` rather than
deploying something subtly wrong. Every change below is enforced by the chart's
`templates/validate.yaml`.

## Status of the 0.16 line

Chart `0.16.0` is GA. All four `deploy.sh` chart-line pins and the three Terraform
`app` modules are on `~0.16.0`, so a deploy takes the newest `0.16.x` patch and never
crosses into `0.17`.

Because the values here are 0.16-only, every entry point now refuses anything off that
line. `deploy.sh` rejects the version before contacting the repository, and the
Terraform `chart_version` variable rejects it at plan time. Chart 0.15 ignores unknown
keys rather than rejecting them, so without the guard a 0.15 deploy would render
cleanly while silently dropping the external Insights Postgres and Redis wiring and
falling back to in-cluster StatefulSets. Failing loudly is the point.

`CHART_VERSION` can still narrow the pin to an exact 0.16 patch:

```bash
cd modules/aws && make apply && make init-values && CHART_VERSION="0.16.0" make deploy
```

The `CHART_VERSION=... make deploy` prefix matters. `CHART_VERSION=... && make deploy`
sets a shell variable that `make` never sees.

Release candidates older than `0.16.0-rc.24` are rejected too: `engineInsightsAgent`
did not exist yet, so they would drop the same wiring as 0.15 without saying so.

## 1) `backend.agentBootstrap` is gone

Chart `0.16.0-rc.17` deleted the bundled agent-bootstrap Job. Standalone agents now
run as the top-level `fleet`, `insights`, and `polly` deployments, which the modules
already use.

The key has been removed from every values file these modules ship. If you keep your
own overlay, delete the block:

```yaml
# Remove this. Chart 0.16 fails the release if the key is present at all.
backend:
  agentBootstrap:
    enabled: true
```

There is one behavioural consequence. `config.agentBuilder.enabled` survives and still
gates the Agent Builder nav item, the OAuth wiring, and the `fleetToolServer` /
`fleetTriggerServer` pods - but the Job that used to register the agent itself is gone,
so that path alone now gives you a UI with no runtime behind it. Fleet is the
replacement. On every provider `enable_fleet` and `enable_agent_builder` are now
mutually exclusive and the scripts fail rather than deploy the half of the feature that
still renders; AWS and GCP additionally warn when `enable_agent_builder` is set on its
own. Move to `enable_fleet = true`.

Helm no longer owns the Job, so upgrading from 0.15 leaves the old Completed
`langsmith-agent-bootstrap` job behind in the namespace. It blocks nothing. The AWS
and GCP `deploy.sh` delete it on the first 0.16 deploy; on Azure and OCP, remove it
by hand if you want the namespace clean:

```bash
kubectl delete job langsmith-agent-bootstrap -n langsmith --ignore-not-found
```

## 2) Insights workload settings moved to `engineInsightsAgent`

Chart `0.16.0-rc.24` put the Engine and Insights agents on one shared deployment, so
its scaling, database, and resource settings moved out of `insights` into a new
top-level `engineInsightsAgent` block.

`insights.enabled` and `insights.encryptionKey` stay where they are. These five move:

| chart 0.15 | chart 0.16 |
|---|---|
| `insights.namePrefix` | `engineInsightsAgent.namePrefix` |
| `insights.apiServer.*` | `engineInsightsAgent.apiServer.*` |
| `insights.queue.*` | `engineInsightsAgent.queue.*` |
| `insights.postgres.*` | `engineInsightsAgent.postgres.*` |
| `insights.redis.*` | `engineInsightsAgent.redis.*` |

The Kubernetes object names do not change: `namePrefix` still defaults to
`standalone-insights`, so the existing `langsmith-standalone-insights-api-server`
and `-queue` deployments roll in place rather than being replaced.

This is a rename, not a data migration. The external Postgres and Redis for Insights
are still referenced by `existingSecretName`, pointing at the same
`langsmith-insights-postgres` and `langsmith-insights-redis` secrets that Terraform
creates, so Insights keeps reading and writing the same databases.

On AWS the IRSA annotations for the Insights service accounts moved with the workload
settings. `init-values.sh` generates the new shape, so re-run `make init-values`
before deploying - a stale `langsmith-values-overrides.yaml` from a 0.15 checkout
still has them under `insights` and the chart will reject it.

## 3) Fewer images to mirror

Chart `0.16.0-rc.17` consolidated five services onto the single `langsmith-backend`
image, and `0.16.0-rc.24` renamed the Insights agent image key. Setting any of the
removed keys is now a hard failure.

| removed | replacement |
|---|---|
| `images.hostBackendImage` | `images.backendImage` |
| `images.platformBackendImage` | `images.backendImage` |
| `images.playgroundImage` | `images.backendImage` |
| `images.fleetToolServerImage` | `images.backendImage` |
| `images.fleetTriggerServerImage` | `images.backendImage` |
| `images.agentBuilderToolServerImage` | `images.backendImage` |
| `images.agentBuilderTriggerServerImage` | `images.backendImage` |
| `images.insightsAgentImage` | `images.engineInsightsAgentImage` |
| `images.insightsEngineImage` | `images.engineInsightsAgentImage` |

`images.engineInsightsAgentImage.repository` must also point at
`langsmith-insights-engine`; the chart rejects a `langsmith-clio` repository outright,
because the combined image serves both the `insights` and `engine` graphs.

These modules never set `images.*`, so there is nothing to change here. It matters
only for private-registry installs: from LangSmith `0.16.21` you no longer need to
mirror `langsmith-go-backend`, `langsmith-playground`, `hosted-langserve-backend`,
`agent-builder-tool-server`, or `agent-builder-trigger-server`, or their `-fips`
variants. See
[Mirroring the images](https://docs.langchain.com/langsmith/self-host-mirroring-images)
and [FIPS images](https://docs.langchain.com/langsmith/self-host-fips).

## 4) Insights and Polly now default to on

Chart 0.16 ships `insights.enabled` and `polly.enabled` as `true`. What that does to an
un-migrated install depends on whether you set `config.existingSecretName`:

- Without it (GCP, OCP) the chart hard-fails on the encryption key it cannot find, so a
  plain base install stops at validation.
- With it (AWS, Azure) the chart finds a key and deploys both agents plus their own
  in-cluster Postgres and Redis StatefulSets - four extra pods nobody asked for.

The modules make the Terraform `enable_*` flags authoritative instead. `init-values.sh`
writes an explicit `enabled: false` for whichever feature is off, the Terraform `app`
path sets the same keys through `yamlencode`, and OCP carries them in its tracked
`values.yaml`. The addon overlays load after the overrides file, so an enabled feature
still turns itself back on. If you maintain your own overlay, set both keys explicitly
rather than relying on the chart default.

## 5) `config.insights` and `config.polly` are rejected

Chart 0.15.1 removed the bundled agent path for both, and the validator fails on the
presence of either key even when it is set to `false`. Every values file and generated
overrides block in these modules now uses the top-level `insights` and `polly` blocks,
so the legacy `enable_insights` and `enable_polly` flags work again on 0.16 - they set
the same top-level keys the standalone flags do, and the two compose rather than
conflict.

If you carry your own overlay, move the keys up a level:

```yaml
# Rejected by chart 0.16, even with enabled: false.
config:
  insights:
    enabled: true

# Use this instead.
insights:
  enabled: true
```

## Upgrade path

1) Take a database backup. Chart downgrades are not supported, so 0.16 to 0.15 is not
   a rollback path - see [Self-host upgrades](https://docs.langchain.com/langsmith/self-host-upgrades).
2) Check out a `v0.16.*` tag and re-run `make init-values` so the generated overrides
   file is regenerated in the 0.16 shape.
3) If you were on `enable_agent_builder`, switch to `enable_fleet = true` first - the
   scripts now refuse to run with both set.
4) Deploy: `make deploy`.
5) Confirm Insights still points at the external databases rather than a new in-cluster
   StatefulSet:

```bash
kubectl get statefulset -n langsmith | grep standalone-insights   # expect no output
kubectl get pods -n langsmith | grep standalone-insights          # api-server + queue only
```

6) Delete the orphaned bootstrap Job if your provider's `deploy.sh` did not.
