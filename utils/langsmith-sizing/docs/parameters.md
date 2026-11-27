# Parameters and citations

> **Status:** current, and generated: `make reference` writes both tables from `params.yaml` and
> `citations.yaml`, and a test fails when they drift.

## Every citation

Each figure the plan takes from the public docs, with the page it is quoted from. `make citations` fetches
each page at the commit in `citations.yaml` and fails a quote that is gone; CI also runs it weekly against
the docs' main branch, so a docs change shows up as a failing check before anyone quotes a stale number.

<!-- generated:citations -->
| Citation | Docs page | Values it gives |
|:--|:--|:--|
| `blob_storage.required_from` | `self-hosted-changelog.mdx` | {line: 0.18, unit: chart line} |
| `blob_storage.attachments` | `self-host-blob-storage.mdx` | {holds: attachments, unit: -} |
| `scale.read_anchors` | `self-host-scale.mdx` | {low: 5, medium: 20, high: 50, unit: concurrent frontend users, rps: {low: 10, medium: 40, high: 100}} |
| `scale.write_anchors` | `self-host-scale.mdx` | {low: 10, medium: 100, high: 1000, unit: traces/s} |
| `scale.replicas.frontend` | `self-host-scale.mdx` | {ll: 1, lh: 4, hl: 2, mm: 2, hh: 4} |
| `scale.replicas.platform_backend` | `self-host-scale.mdx` | {ll: 3, lh: 20, hl: 3, mm: 3, hh: 20} |
| `scale.replicas.ingest_queue` | `self-host-scale.mdx` | {ll: 3, lh: 24, hl: 3, mm: 6, hh: 24} |
| `scale.replicas.backend` | `self-host-scale.mdx` | {ll: 2, lh: 5, hl: 40, mm: 16, hh: 50} |
| `scale.redis_gib` | `self-host-scale.mdx` | {ll: 8, lh: 26, hl: 8, mm: 13, hh: 26} |
| `scale.clickhouse` | `self-host-scale.mdx` | {cpu: {ll: 4, lh: 10, hl: 8, mm: 16, hh: 14}, mem_gib: {ll: 16, lh: 32, hl: 16, mm: 24, hh: 24}, per_replica: [hl, hh]} |
| `scale.clickhouse_setup` | `self-host-scale.mdx` | {single: 1, replicated: 3, replicated_in: [hl, hh]} |
| `scale.postgres` | `self-host-scale.mdx` | {cpu: 2, memory_gb: 8, storage_gb: 10} |
| `scale.clickhouse_disk.medium` | `self-host-scale.mdx` | {traces_per_second: 100, gi_per_day: 60} |
| `scale.clickhouse_disk.high` | `self-host-scale.mdx` | {traces_per_second: 1000, gi_per_day: 600} |
| `scale.min_replicas.frontend.lh` | `self-host-scale.mdx` | 2 |
| `scale.min_replicas.platform_backend.lh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.ingest_queue.lh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.backend.lh` | `self-host-scale.mdx` | 3 |
| `scale.min_replicas.ingest_queue.hl` | `self-host-scale.mdx` | 2 |
| `scale.min_replicas.backend.hl` | `self-host-scale.mdx` | 16 |
| `scale.min_replicas.ingest_queue.mm` | `self-host-scale.mdx` | 3 |
| `scale.min_replicas.backend.mm` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.frontend.hh` | `self-host-scale.mdx` | 2 |
| `scale.min_replicas.platform_backend.hh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.ingest_queue.hh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.backend.hh` | `self-host-scale.mdx` | 20 |
| `smithdb.tested_qps` | `self-host-smithdb-scale.mdx` | {small: {ingest: 10, query: 10}, medium: {ingest: 100, query: 40}, large: {ingest: 1000, query: 100}} |
| `smithdb.replicas.ingestion` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 2} |
| `smithdb.replicas.query` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 4} |
| `smithdb.replicas.compaction` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 1} |
| `smithdb.replicas.compaction-worker` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 4} |
| `smithdb.replicas.cluster-manager` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 1} |
| `smithdb.metastore` | `self-host-smithdb-scale.mdx` | {small: {cpu: 2, memory_gib: 16}, medium: {cpu: 4, memory_gib: 32}, large: {cpu: 8, memory_gib: 64}} |
| `smithdb.metastore_postgres` | `self-host-smithdb-infrastructure.mdx` | {min_major_version: 18} |
| `smithdb.cache_volume` | `self-host-smithdb-infrastructure.mdx` | {min_iops: 7000, min_mib_per_second: 1000} |
| `smithdb.backfill` | `self-host-smithdb-migrate.mdx` | {runs_per_vcpu_day: 5000000} |
| `smithdb.backfill_pod_memory` | `self-host-smithdb-migrate.mdx` | {min_memory_gib: 32} |
| `agent_server.load_levels` | `agent-server-scale.mdx` | {low: 5, medium: 50, high: 500, unit: requests/s a deployment} |
| `agent_server.api_servers` | `agent-server-scale.mdx` | {cpu: 1, memory_gib: 2, replicas: {ll: 1, lh: 6, hl: 10, mm: 3, hh: 15}} |
| `agent_server.queue_workers` | `agent-server-scale.mdx` | {cpu: 1, memory_gib: 2, replicas: {ll: 1, lh: 10, hl: 1, mm: 5, hh: 10}} |
| `agent_server.n_jobs_per_worker` | `agent-server-scale.mdx` | {ll: 10, lh: 50, hl: 10, mm: 10, hh: 50} |
| `agent_server.redis` | `agent-server-scale.mdx` | {cpu: 1, memory_gib: 2} |
| `agent_server.postgres` | `agent-server-scale.mdx` | {cpu: {ll: 2, lh: 4, hl: 4, mm: 4, hh: 8}, memory_gib: {ll: 8, lh: 16, hl: 16, mm: 16, hh: 32}} |
| `agent_server.limit_default` | `data-plane.mdx` | {limit_over_request: 2} |
| `agent_server.requires` | `enable-self-hosted-agent-server.mdx` | {requires: [KEDA, an ingress with config.hostname]} |
| `gateway.streams_per_replica` | `llm-gateway-self-hosted.mdx` | {streams: 100} |
| `gateway.stores` | `llm-gateway-self-hosted.mdx` | {stores: [postgres, redis]} |
| `engine.requires_sandboxes` | `engine-self-hosted.mdx` | {requires: [sandboxes]} |
| `engine.shares_insights` | `engine-self-hosted.mdx` | {shares: insights} |
| `fleet.own_stores` | `enable-self-hosted-fleet.mdx` | {postgres: own, redis: own} |
| `insights_chat.keys` | `self-host-insights-chat.mdx` | {key: Fernet} |
| `sandboxes.hosts` | `self-host-sandbox-scaling.mdx` | {formula: ceil(committed_vcpu / (host_vcpu * target)) + headroom} |
| `sandboxes.target` | `self-host-sandbox-scaling.mdx` | {pct: 70} |
| `sandboxes.headroom` | `self-host-sandbox-scaling.mdx` | {hosts: 1} |
| `sandboxes.min_hosts` | `self-host-sandbox-scaling.mdx` | {hosts: 2} |
| `sandboxes.memory` | `self-host-sandbox-scaling.mdx` | {memory_gib_each: 2} |
| `sandboxes.cpu_only` | `self-host-sandbox-scaling.mdx` | {signal: committed vCPU} |
| `sandboxes.host_memory` | `self-host-sandbox-scaling.mdx` | {rule: host memory request covers its guests} |
| `sandboxes.cache` | `enable-self-hosted-sandboxes.mdx` | {cache_gib: 50} |
| `sandboxes.juicefs_redis` | `enable-self-hosted-sandboxes.mdx` | {maxmemory_policy: noeviction} |
| `sandboxes.nodes` | `enable-self-hosted-sandboxes.mdx` | {requires: [dedicated KVM nodes]} |
| `sandboxes.node_arch` | `enable-self-hosted-sandboxes.mdx` | {requires: [x86-64]} |
| `sandboxes.node_cgroup` | `enable-self-hosted-sandboxes.mdx` | {requires: [cgroup v2 with the cpu controller]} |
| `sandboxes.node_devices` | `enable-self-hosted-sandboxes.mdx` | {requires: [/dev/net/tun, /dev/fuse]} |
| `sandboxes.node_nftables` | `enable-self-hosted-sandboxes.mdx` | {requires: [nftables]} |
| `sandboxes.one_host_per_node` | `self-host-sandbox-architecture.mdx` | {host_pods_per_node: 1} |
| `sandboxes.privileged` | `self-host-sandbox-architecture.mdx` | {requires: [privileged pods]} |
| `sandboxes.node_label` | `enable-self-hosted-sandboxes.mdx` | {label: sandbox.langsmith.com/host=true} |
| `gateway.tested_requests` | `llm-gateway-self-hosted.mdx` | {cpu: 1, memory_gib: 1} |
<!-- /generated:citations -->

## Every parameter

The model's own constants. The full entry for each, with its reason and the evidence behind it, is in
[`params.yaml`](../params.yaml); a source of `lab` or `load-test` names the runs, and `field` means seen on
self-hosted installs and never named. How each is used: [how-it-sizes.md](how-it-sizes.md).

<!-- generated:params -->
| Parameter | Value | Unit | Source | By |
|:--|:--|:--|:--|:--|
| `load.peak_factor` | 3 | x | field | Dzmitry Dubarau |
| `load.runs_per_trace` | 10 | runs/trace | measurement | Dzmitry Dubarau |
| `time.seconds_per_month` | 2,626,560 | s | derived | Dzmitry Dubarau |
| `time.seconds_per_year` | 31,536,000 | s | derived | Dzmitry Dubarau |
| `grid.blend` | {ll_mm: 0.5, ll_hl: 0.4, mm_hh: 0.5, hl_hh: 0.5} | ratio | decision | Dzmitry Dubarau |
| `inputs.limits` | (a table: see params.yaml) | per field (KiB, KiB, runs/trace, x, x) | decision | Dzmitry Dubarau |
| `defaults.blob_storage` | on | flag | decision | Dzmitry Dubarau |
| `defaults.redis_expiry_tuned` | on | flag | decision | Dzmitry Dubarau |
| `defaults.compression` | 1 | x | measurement | Dzmitry Dubarau |
| `payload.mix_default` | {small: 70, medium: 25, large: 5} | % of runs | measurement | Dzmitry Dubarau |
| `payload.bucket_kib` | (a table: see params.yaml) | KiB per field | decision | Dzmitry Dubarau |
| `payload.smithdb_kb_per_run` | {small: 3.75, medium: 15, large: 112} | KB per run (decimal) | load-test | Dzmitry Dubarau |
| `payload.blob_kb_per_run` | {small: 0, medium: 38, large: 84} | KB per run (decimal) | load-test | Dzmitry Dubarau |
| `payload.redis_kb_per_run` | {small: 9.7, medium: 2.9, large: 12} | KB per run (decimal) | load-test | Dzmitry Dubarau |
| `payload.partial_inline_share` | 0.5 | share of runs held in Redis | decision | Dzmitry Dubarau |
| `payload.platform_backend_pods_at_reference` | {small: 3, medium: 6, large: 10} | pods | measurement | Dzmitry Dubarau |
| `payload.reference_traces_per_year` | 10,000,000,000 | traces/year | measurement | Dzmitry Dubarau |
| `payload.tested_traces_per_second` | 300 | traces/s | load-test | Dzmitry Dubarau |
| `retention.extended_share_default_pct` | 5 | % of runs | decision | Dzmitry Dubarau |
| `retention.smithdb_delete_lag_days` | 5 | days | measurement | Dzmitry Dubarau |
| `headroom.storage` | 1.2 | x | measurement | Dzmitry Dubarau |
| `headroom.redis` | 1.3 | x | measurement | Dzmitry Dubarau |
| `headroom.redis_untuned_expiry` | 1.3 | x | measurement | Dzmitry Dubarau |
| `keda.max_factor` | 1.5 | x | decision | Dzmitry Dubarau |
| `keda.round_to` | 5 | replicas | decision | Dzmitry Dubarau |
| `ingest.runs_per_core_points` | [[8, 55], [190, 12.6]] | [KB per run, runs/s per core] | field | Dzmitry Dubarau |
| `ingest.cpu_headroom` | 1.25 | x | field | Dzmitry Dubarau |
| `ingest.pod_cpu` | 2 | vCPU | lab | Dzmitry Dubarau |
| `ingest.pod_memory_gib` | 4 | GiB | field | Dzmitry Dubarau |
| `ingest.min_pods` | 2 | pods | decision | Dzmitry Dubarau |
| `go.min_cpu_limit` | 2 | vCPU | lab | Dzmitry Dubarau |
| `availability.min_replicas` | 2 | replicas | decision | Dzmitry Dubarau |
| `redis.alarm_pct` | 70 | % of maxmemory | field | Dzmitry Dubarau |
| `redis.runs_per_shard` | {inline: 850, offloaded: 1700} | runs/s per shard | load-test | Dzmitry Dubarau |
| `redis.cluster_shard_cap` | 250 | shards | decision | Dzmitry Dubarau |
| `redis.single_node_max_gb` | 300 | GB | decision | Dzmitry Dubarau |
| `redis.expiry_retry_hours` | 3.5 | hours | field | Dzmitry Dubarau |
| `redis.payload_trimmed_from` | 0.18 | chart line | field | Reed Bender |
| `redis.trimmed_kb_per_run` | 2.5 | KB per run (decimal) | load-test | Reed Bender |
| `redis.stall_hours` | 1 | hours | decision | Reed Bender |
| `redis.queue_partitions` | {runs_per_partition: 12000, min_on_cluster: 2} | runs/s per partition | field | Dzmitry Dubarau |
| `postgres.pool_api_pod` | 50 | connections per pod | measurement | Dzmitry Dubarau |
| `postgres.connection_budget` | 0.8 | share of max_connections | decision | Dzmitry Dubarau |
| `postgres.max_connections_in_cluster` | 100 | connections | decision | Dzmitry Dubarau |
| `postgres.bytes_per_connection` | 9,531,392 | bytes | derived | Dzmitry Dubarau |
| `postgres.max_connections_cap` | 5,000 | connections | derived | Dzmitry Dubarau |
| `smithdb.peak_runs_bands` | {small: 100, medium: 1000, large: 10000} | peak runs/s | field | Dzmitry Dubarau |
| `smithdb.small_ingestion_runs_per_pod` | 86 | peak runs/s a pod | lab | Reed Bender |
| `smithdb.query_floor_replicas` | 2 | replicas | field | Dzmitry Dubarau |
| `smithdb.mutations_replicas` | 2 | replicas | field | Dzmitry Dubarau |
| `smithdb.splits_from_tier` | large | tier | field | Dzmitry Dubarau |
| `clickhouse.inline_payload_factor` | 5 | x | decision | Dzmitry Dubarau |
| `clickhouse.floor_gi_per_day` | 5 | GiB per TTL day | decision | Dzmitry Dubarau |
| `clickhouse.floor_up_to_traces_per_second` | 20 | traces/s | decision | Dzmitry Dubarau |
| `load.feedback_per_trace` | 0.5 | feedback writes per trace | decision | Hari Narayan |
| `load.payload_shape` | (a table: see params.yaml) | simple (runs_per_trace runs in a flat tree, each a size from the mix) or agent (load.agent_trace); fields an input and an output each split into; text, json or base64; post_then_patch or post_once; projects and the Zipf exponent of their spread; metadata keys a run; the most runs a request | decision | Reed Bender |
| `load.agent_trace` | (a table: see params.yaml) | agentic_share: the share of traces that call tools; tool_turns: the mean model calls past the first in such a trace (1 plus a geometric count); tools_per_turn: the weights of 1, 2 and 3 calls a turn; wrappers and history_messages: geometric means; *_kib: lognormal sizes (median KiB, the sigma of the log, an optional max) | decision | Reed Bender |
| `load.read_mix` | (a table: see params.yaml) | relative weight per read | decision | Reed Bender |
| `load.heavy_window_days` | 30 | days | field | Reed Bender |
| `slo.stored_within_seconds` | {p99: 30} | s from send to readable | field | Ben Nagengast |
| `slo.trace_load_seconds` | {p99: 5} | s | field | Ben Nagengast |
| `regimes` | (a table: see params.yaml) | regime bands, first match wins: peak_runs_per_second_above (peak runs/s strictly above), peak_band_min (peak runs/s at or above that SmithDB band's upper edge), peak_traces_per_second_max (the busiest rate at or below; the low regimes' figures are busiest rates), requires (input facts that must hold: one replica cannot survive a node's loss) | decision | Reed Bender |
| `scale.signals` | (a table: see params.yaml) | signal -> the autoscaling field that expresses it (null: none does) | decision | Reed Bender |
| `scale.fallback` | {mechanism: hpa, signal: cpu} | mechanism and signal | decision | Reed Bender |
| `scale.workloads` | (a table: see params.yaml) | workload -> chart values key, where the plan sizes it, recommended mechanism and signals | decision | Reed Bender |
| `configure.queue_priorities` | (a table: see params.yaml) | asynq queue weight (higher runs first) | decision | Reed Bender |
| `configure.partition_env` | (a table: see params.yaml) | environment variable names | decision | Reed Bender |
| `watch.metrics_smithdb` | (a table: see params.yaml) | metric names, by export mode | lab | Reed Bender |
| `watch.metrics_other` | (a table: see params.yaml) | metric names | lab | Reed Bender |
| `watch.items` | (a table: see params.yaml) | items: id, workload, metric, where, threshold, meaning, action | decision | Reed Bender |
| `pools.overhead` | 1.2 | x | decision | Dzmitry Dubarau |
| `pools.app_node` | {cpu: 8, memory_gib: 32} | vCPU, GiB per node | decision | Dzmitry Dubarau |
| `pools.smithdb_node` | (a table: see params.yaml) | vCPU, GiB per node, by SmithDB tier | decision | Dzmitry Dubarau |
| `pools.app_min_nodes` | 2 | nodes | decision | Dzmitry Dubarau |
| `pools.smithdb_min_nodes` | 2 | nodes | decision | Dzmitry Dubarau |
| `pools.datastores_min_nodes` | 1 | nodes | decision | Reed Bender |
| `pools.clickhouse_node_shapes` | [{cpu: 16, memory_gib: 64}, {cpu: 32, memory_gib: 128}] | vCPU, GiB per node, smallest first | decision | Dzmitry Dubarau |
| `datastores.operator_instances` | {survives_node_loss: 3, otherwise: 1} | instances | decision | Dzmitry Dubarau |
| `datastores.limit_factor` | 2 | x requests | lab | Reed Bender |
| `datastores.redis_maxmemory_share` | 0.75 | share of the container's memory limit | lab | Reed Bender |
| `datastores.redis_sentinel` | {replicas: 3, cpu: 0.1, memory_gib: 0.125} | pods, vCPU and GiB each | lab | Reed Bender |
| `datastores.object_store_pod` | (a table: see params.yaml) | vCPU and GiB, by SmithDB tier | lab | Reed Bender |
| `datastores.object_store_measured_traces_per_second` | 80 | traces/s | lab | Reed Bender |
| `smithdb.metastore_disk_gib` | 50 | GiB | decision | Dzmitry Dubarau |
| `products.pods` | (a table: see params.yaml) | vCPU, GiB requested a pod | decision | Dzmitry Dubarau |
| `products.limit_over_request` | 2 | x | decision | Reed Bender |
| `agent_server.load_default` | ll | read/write column of the docs' Agent Server table | decision | Reed Bender |
| `sandboxes.concurrent_default` | 10 | sandboxes running at once | decision | Reed Bender |
| `sandboxes.vcpu_each` | 1 | vCPU a sandbox | decision | Reed Bender |
| `pools.sandbox_node` | {cpu: 16, memory_gib: 64} | vCPU, GiB per node | decision | Reed Bender |
| `sandboxes.juicefs_redis` | {cpu: 2, memory_gib: 5} | vCPU, GiB | decision | Dzmitry Dubarau |
| `scale_out.measured` | (a table: see params.yaml) | requested vCPU per 1,000 runs/s; runs/s per pod or partition; connections per pod; runs/s | load-test | Ben Nagengast |
| `lite.measured` | (a table: see params.yaml) | cores idle (base) and per unit of work (offered or processed runs/s, concurrent readers); GiB a pod at its sampled peak; headroom and memory_headroom x | lab | Reed Bender |
<!-- /generated:params -->
