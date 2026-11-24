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
  assert {
    condition     = output.plan.pods.playground.cpu_m == 50
    error_message = "playground does no per-run work and should sit at the 50m floor."
  }
}

# Past the measured rates the model asks more than the usual 2-CPU limit; Kubernetes refuses a limit
# below its request, so the limit rises with it.
run "a_request_above_its_usual_limit_lifts_the_limit" {
  command = plan
  variables {
    box             = "l"
    machine         = { cpu = 64, memory_gi = 256, disk_gi = 2000 }
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
