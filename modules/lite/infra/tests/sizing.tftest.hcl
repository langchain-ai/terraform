# Sizing: every preset fits its machine at its design load, the measured model sizes LangSmith's pods,
# and a box too small for its pods is refused at plan time, before any machine exists.

variables {
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.5.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
  cloud                 = "baremetal"
  ssh_host              = "box.example.com"
  langsmith_license_key = "test"
}

run "each_preset_fits_at_its_design_load_s" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.used_pct.cpu <= 100 && output.plan.used_pct.memory <= 100 && output.plan.used_pct.disk <= 100
    error_message = "box s does not fit at its own design load: ${jsonencode(output.plan.used_pct)}."
  }
}

run "each_preset_fits_at_its_design_load_m" {
  command = plan
  variables { box = "m" }
  assert {
    condition     = output.plan.used_pct.cpu <= 100 && output.plan.used_pct.memory <= 100 && output.plan.used_pct.disk <= 100
    error_message = "box m does not fit at its own design load: ${jsonencode(output.plan.used_pct)}."
  }
}

run "each_preset_fits_at_its_design_load_l" {
  command = plan
  variables { box = "l" }
  assert {
    condition     = output.plan.used_pct.cpu <= 100 && output.plan.used_pct.memory <= 100 && output.plan.used_pct.disk <= 100
    error_message = "box l does not fit at its own design load: ${jsonencode(output.plan.used_pct)}."
  }
}

# ingest-queue at 5 runs/s: (0.025 + 0.035 x 5) x 1.5 = 0.3 cores, the lab model's fit.
run "the_model_sizes_ingest_from_the_rate" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.pods.ingestQueue.cpu_m == 300
    error_message = "ingestQueue asks ${output.plan.pods.ingestQueue.cpu_m}m at 5 runs/s; the model gives 300m."
  }
  # backend at 2 readers: (0.013 + 0.0012 x 2) x 1.5 = 23m, under the floor.
  assert {
    condition     = output.plan.pods.backend.cpu_m == 50
    error_message = "backend at 2 readers should sit at the 50m floor."
  }
}

# Past the measured rates the model asks more than the usual 2-CPU limit; Kubernetes refuses a limit
# below its request, so the limit rises with it.
run "a_request_above_its_usual_limit_lifts_the_limit" {
  command = plan
  variables {
    box             = "l"
    machine         = { cpu = 64, memory_gi = 256, disk_gi = 6000 }
    runs_per_second = 200
  }
  assert {
    condition     = output.plan.pods.ingestQueue.lim_cpu_m >= output.plan.pods.ingestQueue.cpu_m && output.plan.pods.ingestQueue.cpu_m > 2000
    error_message = "ingestQueue at 200 runs/s: request ${output.plan.pods.ingestQueue.cpu_m}m, limit ${output.plan.pods.ingestQueue.lim_cpu_m}m."
  }
}

run "a_box_too_small_is_refused" {
  command = plan
  variables {
    box     = "s"
    machine = { cpu = 2, memory_gi = 8, disk_gi = 128 }
  }
  expect_failures = [terraform_data.fit]
}

run "volumes_count_against_the_disk" {
  command = plan
  variables {
    box     = "s"
    volumes = { object_store_gi = 500 }
  }
  expect_failures = [terraform_data.fit]
}

run "an_override_replaces_a_pods_whole_size" {
  command = plan
  variables {
    box       = "m"
    resources = { queue = { cpu_m = 150, mem_mi = 1200, lim_cpu_m = 1000, lim_mem_mi = 2400 } }
  }
  assert {
    condition     = output.plan.pods.queue.cpu_m == 150 && output.plan.pods.queue.lim_mem_mi == 2400
    error_message = "the queue override did not replace its size."
  }
  assert {
    condition     = output.values.langsmith.values.queue.deployment.resources.requests.memory == "1200Mi"
    error_message = "the override did not reach the chart's values."
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

run "the_tunnel_pod_counts_only_with_a_tunnel" {
  command = plan
  variables { box = "m" }
  assert {
    condition     = !contains(keys(output.plan.pods), "cloudflared")
    error_message = "cloudflared is counted without access = tunnel."
  }
}

run "bare_metal_ssh_leaves_user_and_port_to_the_ssh_config" {
  command = plan
  assert {
    condition     = output.ssh.user == null && output.ssh.port == null
    error_message = "an unset ssh_user or ssh_port must not override ~/.ssh/config's."
  }
}

# 5 runs/s at the peak is 144,000 runs a day at the average (a third), each about 12 KB in SmithDB's
# bucket kept 19.8 days and 13.7 KB in the blob bucket kept 14.8 days: 59 GiB, 71 with headroom.
run "the_object_store_is_sized_from_the_traffic_it_keeps" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = output.plan.data.runs_per_day == 144000 && output.plan.volumes_gi.object_store == 71
    error_message = "box s should keep 144000 runs a day in 71 GiB; got ${output.plan.data.runs_per_day} and ${output.plan.volumes_gi.object_store}."
  }
}

run "payloads_that_compress_worse_need_more_disk" {
  command = plan
  variables {
    box            = "s"
    machine        = { cpu = 4, memory_gi = 16, disk_gi = 1000 }
    storage_factor = 3
  }
  assert {
    condition     = output.plan.volumes_gi.object_store >= 3 * 70
    error_message = "storage_factor 3 should triple the object store."
  }
}

run "redis_holds_a_stalled_ingest_for_the_whole_expiry" {
  command = plan
  variables { box = "m" }
  assert {
    condition     = output.plan.pods.redis.lim_mem_mi >= 25 * 8.1 * 6 * 3600 * 1000 / 1048576 / 0.75
    error_message = "Redis's limit should hold six hours of runs at 25 runs/s."
  }
}

run "tracing_runs_no_playground_or_code_evaluators" {
  command = plan
  variables { box = "s" }
  assert {
    condition     = !contains(keys(output.plan.pods), "playground") && !contains(keys(output.plan.pods), "aceBackend")
    error_message = "playground and ace-backend should not be sized when their features are off."
  }
  assert {
    condition     = output.values.langsmith.values.playground.deployment.replicas == 0 && output.values.langsmith.values.aceBackend.deployment.replicas == 0
    error_message = "playground and ace-backend should run no pod when their features are off."
  }
}

run "a_feature_turned_on_is_sized_and_runs" {
  command = plan
  variables {
    box        = "m"
    playground = true
  }
  assert {
    condition     = contains(keys(output.plan.pods), "playground") && output.values.langsmith.values.playground.deployment.resources.requests.memory == "922Mi"
    error_message = "playground on should be sized and given its resources."
  }
}
