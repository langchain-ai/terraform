# Sizing (SIZING.md): every preset fits its machine at its design load; the measured model sizes the
# services; each store is sized from the load and the TTLs; a box that cannot hold its pods, its volumes
# or a stalled ingest is refused at plan time, before any machine exists; past l is a full deployment.

variables {
  cloud                 = "baremetal"
  ssh_host              = "box.example.com"
  langsmith_license_key = "test"
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.6.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
}

run "xs_fits_without_observability_or_mission_control" {
  command = plan
  variables { box = "xs" }
  assert {
    condition     = output.plan.used_pct.cpu <= 100 && output.plan.used_pct.memory <= 100 && !output.plan.features.observability && !output.plan.features.mission_control
    error_message = "xs should fit its 2 vCPU with observability and Mission Control off: ${jsonencode(output.plan.used_pct)}."
  }
}

run "s_fits" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.used_pct.cpu <= 100 && output.plan.used_pct.memory <= 100 && output.plan.disks.used_pct <= 80
    error_message = "box s does not fit at its design load: ${jsonencode(output.plan.used_pct)}, disk ${output.plan.disks.used_pct}%."
  }
}

run "m_fits" {
  command = plan
  variables { box = "m" }
  assert {
    condition     = output.plan.used_pct.cpu <= 100 && output.plan.used_pct.memory <= 100 && output.plan.disks.used_pct <= 80
    error_message = "box m does not fit at its design load."
  }
}

run "l_fits_at_the_single_machine_limit" {
  command = plan
  variables { box = "l" }
  assert {
    condition     = output.plan.runs_per_second == 50 && output.plan.used_pct.cpu <= 100 && output.plan.disks.used_pct <= 80
    error_message = "box l should be designed for 50 runs/s and fit."
  }
}

run "past_l_is_a_full_deployment" {
  command = plan
  variables {
    box             = "l"
    machine         = { cpu = 64, memory_gi = 256, disk_gi = 8000 }
    runs_per_second = 80
  }
  expect_failures = [terraform_data.fit]
}

# ingest-queue at 5 runs/s: (0.025 + 0.035 x 5) x 1.5 = 300m; its sampled peak of 1126 MiB x 1.2 = 1352 MiB.
run "the_model_sizes_the_services_from_the_rate" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.pods.ingestQueue.cpu_m == 300 && output.plan.pods.backend.cpu_m == 50
    error_message = "ingestQueue should ask 300m at 5 runs/s, and backend sit at the 50m floor."
  }
  assert {
    condition     = output.plan.pods.ingestQueue.mem_mi == 1352 && output.plan.pods.ingestQueue.lim_mem_mi == 2704
    error_message = "a service's memory request should be its sampled peak x 1.2, its limit twice that."
  }
}

# 5 runs/s at the peak is 144,000 runs a day at the average, each about 12 KB in SmithDB's bucket kept
# 19.8 days (95% x (14 + 5) + 5% x (30 + 5)) and 13.7 KB of blobs kept 14.8 days: 59 GiB, 71 with headroom.
run "the_object_store_holds_the_traffic_for_its_ttls" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.data.runs_a_day == 144000 && output.plan.volumes_gi.object_store == 71
    error_message = "box s should keep 144,000 runs a day in 71 GiB; got ${output.plan.data.runs_a_day} and ${output.plan.volumes_gi.object_store}."
  }
}

run "longer_ttls_and_more_extended_retention_need_more" {
  command = plan
  variables {
    box                    = "s"
    machine                = { cpu = 4, memory_gi = 32, disk_gi = 4000 }
    short_ttl_days         = 30
    long_ttl_days          = 400
    extended_retention_pct = 50
  }
  assert {
    condition     = output.plan.volumes_gi.object_store > 10 * 71
    error_message = "30/400-day TTLs with half the runs extended should need many times the default's object store."
  }
}

run "attachments_go_to_the_blob_bucket" {
  command = plan
  variables {
    box                    = "s"
    machine                = { cpu = 4, memory_gi = 32, disk_gi = 4000 }
    attachment_kib_per_run = 100
  }
  assert {
    condition     = output.plan.data.kb_a_run.blob > 100 && output.plan.volumes_gi.object_store > 71
    error_message = "100 KiB of attachments a run should add to the blob bucket's bytes a run and the object store."
  }
}

# SmithDB's bytes a day x 7 hot days x 1.2: box m writes about 8.6 GB a day, 56 GiB for a week.
run "the_query_cache_holds_the_hot_window" {
  command = plan
  variables { box = "m" }
  assert {
    condition     = output.plan.volumes_gi.smithdb_cache >= 55 && output.plan.volumes_gi.smithdb_cache <= 70
    error_message = "box m's cache should hold about a week of SmithDB's data; got ${output.plan.volumes_gi.smithdb_cache} GiB."
  }
}

# 25 runs/s x 8.1 KB x 6 h x 1.3 = 5.3 GiB maxmemory; Redis's memory request equals its limit (reserved).
run "redis_is_reserved_for_a_stalled_ingest" {
  command = plan
  variables { box = "m" }
  assert {
    condition     = output.plan.data.redis_maxmemory_mi >= 5200 && output.plan.pods.redis.mem_mi == output.plan.pods.redis.lim_mem_mi
    error_message = "Redis should hold six hours of runs at 25 runs/s, with its memory reserved."
  }
}

# 2 API pods x 50 + 2 workers x 3 + 20 = 126, within 80%: 158, rounded up to 200.
run "postgres_connections_from_the_pods_pools" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.data.postgres_max_connections == 200 && output.plan.pods.postgres.mem_mi == output.plan.pods.postgres.lim_mem_mi
    error_message = "max_connections should be 200, and Postgres's memory reserved."
  }
}

run "a_box_too_small_is_refused" {
  command = plan
  variables {
    box     = "s"
    machine = { cpu = 2, memory_gi = 8, disk_gi = 160 }
  }
  expect_failures = [terraform_data.fit]
}

run "a_disk_too_small_for_the_ttls_is_refused" {
  command = plan
  variables {
    box            = "s"
    short_ttl_days = 90
  }
  expect_failures = [terraform_data.fit]
}

run "a_data_path_needs_its_size" {
  command = plan
  variables {
    box       = "s"
    data_path = "/srv/data"
  }
  expect_failures = [terraform_data.fit]
}

run "a_data_path_holds_the_volumes_apart_from_the_system" {
  command = plan
  variables {
    box       = "s"
    data_path = "/srv/data"
    machine   = { cpu = 4, memory_gi = 32, disk_gi = 40, data_disk_gi = 200 }
  }
  assert {
    condition     = output.plan.disks.data_separate && output.plan.disks.data_mount == "/srv/data"
    error_message = "with data_path, the volumes should go on that disk and the system keep its own."
  }
}

run "a_measured_size_replaces_a_modelled_one" {
  command = plan
  variables {
    box       = "m"
    resources = { queue = { cpu_m = 150, mem_mi = 1200, lim_cpu_m = 1000, lim_mem_mi = 2400 } }
  }
  assert {
    condition     = output.plan.pods.queue.cpu_m == 150 && output.values.langsmith.values.queue.deployment.resources.requests.memory == "1200Mi"
    error_message = "the override should replace queue's size and reach the chart."
  }
}

run "an_override_for_a_pod_lite_does_not_run_is_refused" {
  command = plan
  variables {
    box       = "m"
    resources = { clickhouse = { cpu_m = 100, mem_mi = 100, lim_cpu_m = 0, lim_mem_mi = 100 } }
  }
  expect_failures = [terraform_data.fit]
}

run "retention_left_at_its_defaults_is_said_so" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = !output.plan.retention.set_by_person && output.plan.retention.short_days == 14
    error_message = "unset TTLs should plan at 14 and 30 days and be flagged as the defaults."
  }
}

run "retention_set_is_said_so" {
  command = plan
  variables {
    box            = "s"
    short_ttl_days = 7
    long_ttl_days  = 14
  }
  assert {
    condition     = output.plan.retention.set_by_person && output.plan.volumes_gi.object_store < 71
    error_message = "set TTLs should be marked as set, and 7/14 days need less than the default's 71 GiB."
  }
}

run "tracing_runs_no_playground_or_code_evaluators" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = !contains(keys(output.plan.pods), "playground") && output.values.langsmith.values.playground.deployment.replicas == 0 && output.values.langsmith.values.aceBackend.deployment.replicas == 0
    error_message = "playground should never run, and ace-backend not unless code_evaluators is set."
  }
}

run "code_evaluators_turned_on_is_sized_and_runs" {
  command = plan
  variables {
    box             = "l"
    code_evaluators = true
  }
  assert {
    condition     = contains(keys(output.plan.pods), "aceBackend") && output.values.langsmith.values.aceBackend.deployment.replicas == 1
    error_message = "code_evaluators on should size ace-backend and run one replica."
  }
}

run "bare_metal_ssh_leaves_user_and_port_to_the_ssh_config" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.ssh.user == null && output.ssh.port == null
    error_message = "an unset ssh_user or ssh_port must not override ~/.ssh/config's."
  }
}

run "emulate_machine_caps_the_pods_at_the_machine_less_its_reservation" {
  command = plan
  variables {
    box             = "m"
    emulate_machine = true
  }
  assert {
    condition     = local.lite_env.POD_CPU_M == "7250" && local.lite_env.POD_MEM_MI == "63488"
    error_message = "an emulated m box should hold its pods to 8 vCPU less 750m reserved and 64 GiB less 2,048 MiB."
  }
}

run "without_emulate_machine_the_pods_have_no_cap" {
  command = plan
  variables {
    box = "m"
  }
  assert {
    condition     = local.lite_env.POD_CPU_M == "0" && local.lite_env.POD_MEM_MI == "0"
    error_message = "the pods should not be capped unless emulate_machine is set."
  }
}
