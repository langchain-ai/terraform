# Migrating from chart 0.15 to chart 0.16

These modules wrap the LangSmith Helm chart, so a chart minor bump changes the
values files the modules ship. This note covers what changed, what you have to do,
and what the modules now do for you.

Chart 0.16 rejects the removed and renamed keys with a template error instead of
ignoring them, so an un-migrated values file fails at `helm upgrade` rather than
deploying something subtly wrong. Every change below is enforced by the chart's
`templates/validate.yaml`.

## Status of the 0.16 line

Chart `0.16.0` is not GA yet. The latest published version is `0.16.0-rc.29`, so
the four `deploy.sh` chart-line pins deliberately stay at `~0.15.1` on this branch.
`~0.16.0` would match nothing, because Helm tilde ranges skip prereleases.

Until GA, pass the release candidate explicitly:

```bash
cd modules/aws && make apply && make init-values && CHART_VERSION="0.16.0-rc.29" make deploy
```

The `CHART_VERSION=... make deploy` prefix matters. `CHART_VERSION=... && make deploy`
sets a shell variable that `make` never sees.

Because the values on this branch are 0.16-only, each `deploy.sh` now refuses to run
against a chart older than 0.16. Chart 0.15 ignores unknown keys rather than rejecting
them, so without the guard a 0.15 deploy would render cleanly while silently dropping
the external Insights Postgres and Redis wiring and falling back to in-cluster
StatefulSets. Failing loudly is the point.

## 1) `backend.agentBootstrap` is gone

Chart `0.16.0-rc.17` deleted the bundled agent-bootstrap Job. Standalone agents now
run as the top-level `fleet`, `insights`, and `polly` deployments, which the modules
already use.

Nothing to do if you deploy from these modules - the key has been removed from every
values file they ship. If you keep your own overlay, delete the block:

```yaml
# Remove this. Chart 0.16 fails the release if the key is present at all.
backend:
  agentBootstrap:
    enabled: true
```

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
| `images.insightsAgentImage` | `images.engineInsightsAgentImage` |

These modules never set `images.*`, so there is nothing to change here. It matters
only for private-registry installs: from LangSmith `0.16.21` you no longer need to
mirror `langsmith-go-backend`, `langsmith-playground`, `hosted-langserve-backend`,
`agent-builder-tool-server`, or `agent-builder-trigger-server`, or their `-fips`
variants. See
[Mirroring the images](https://docs.langchain.com/langsmith/self-host-mirroring-images)
and [FIPS images](https://docs.langchain.com/langsmith/self-host-fips).

## Upgrade path

1) Take a database backup. Chart downgrades are not supported, so 0.16 to 0.15 is not
   a rollback path - see [Self-host upgrades](https://docs.langchain.com/langsmith/self-host-upgrades).
2) Check out this branch and re-run `make init-values` so the generated overrides file
   is regenerated in the 0.16 shape.
3) Deploy against the pinned RC: `CHART_VERSION="0.16.0-rc.29" make deploy`.
4) Confirm Insights still points at the external databases rather than a new in-cluster
   StatefulSet:

```bash
kubectl get statefulset -n langsmith | grep standalone-insights   # expect no output
kubectl get pods -n langsmith | grep standalone-insights          # api-server + queue only
```

5) Delete the orphaned bootstrap Job if your provider's `deploy.sh` did not.

## Known gaps on the 0.15 line

These are not caused by the 0.16 cutover - they already fail on chart 0.15.1 and later,
and are tracked as 0.15-compatible fixes to land on `main` before this branch merges.

- AWS and GCP `langsmith-values-insights.yaml` (the `enable_insights` path) still set
  `config.insights`, which the chart has rejected since 0.15.1. Use the standalone path
  (`enable_standalone_insights`) instead, which is migrated and verified.
- AWS and GCP `langsmith-values-polly.yaml` (the `enable_polly` path) still set
  `config.polly`, rejected for the same reason. Use `enable_standalone_polly`.
- GCP `init-values.sh` never writes `insights.enabled: false` when standalone Insights
  is off, so the chart default (`true`) applies with no encryption key and the release
  fails validation. AWS writes the disable explicitly; GCP needs the same.
