# cloud = aws: one instance of the preset's type, the data on a volume of its own with daily snapshots,
# ssh from the operator only, HTTPS opened only for the access modes that serve LangSmith on the address,
# and what it costs. No AWS credentials: every call is mocked.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0123456789abcdef0"] }
  }
  mock_data "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0", vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1a" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
}

variables {
  cloud                 = "aws"
  box                   = "s"
  ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test"
  admin_cidrs           = ["203.0.113.7/32"]
  langsmith_license_key = "test"
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.6.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
}

run "each_preset_picks_its_instance" {
  command = plan
  assert {
    condition     = module.aws[0].instance_type == "r7i.xlarge"
    error_message = "box s should run on r7i.xlarge (4 vCPU, 32 GiB)."
  }
}

run "xs_runs_on_two_vcpus_and_sixteen_gib" {
  command = plan
  variables { box = "xs" }
  assert {
    condition     = module.aws[0].instance_type == "r7i.large"
    error_message = "box xs should run on r7i.large (2 vCPU, 16 GiB)."
  }
}

# The data volume holds the plan's volumes at 80% full at most, rounded up to 10 GiB; the system keeps 40.
run "the_data_has_a_volume_of_its_own" {
  command = plan
  assert {
    condition     = output.plan.disks.data_separate && output.plan.disks.system_gi == 40 && output.plan.disks.data_gi * 0.8 >= output.plan.disks.volumes_gi
    error_message = "on AWS the volumes should be on a data volume of their own, at most 80% full."
  }
  assert {
    condition     = output.plan.disks.data_mount == "/var/lib/rancher/k3s/storage" && output.plan.disks.snapshot_days == 7
    error_message = "the data volume should mount at k3s's storage folder, with seven days of daily snapshots."
  }
}

run "snapshots_can_be_turned_off" {
  command = plan
  variables { backup_snapshot_days = 0 }
  assert {
    condition     = output.plan.disks.snapshot_days == 0 && output.plan.cost_usd_a_month.snapshots == 0
    error_message = "backup_snapshot_days = 0 should make no snapshots and cost none."
  }
}

# r7i.xlarge at $0.2646 x 730 h, 40 + 130 GiB of gp3 at $0.08, snapshots of 107 GiB at $0.05, an address.
run "the_cost_is_the_instance_the_disks_the_snapshots_and_the_address" {
  command = plan
  assert {
    condition     = output.plan.cost_usd_a_month.total >= 205 && output.plan.cost_usd_a_month.total <= 225
    error_message = "box s on AWS should cost about $216 a month at list prices; got ${output.plan.cost_usd_a_month.total}."
  }
}

run "a_negotiated_price_replaces_the_list_price" {
  command = plan
  variables { aws_hourly_usd = 0.1 }
  assert {
    condition     = output.plan.cost_usd_a_month.instance == 73
    error_message = "aws_hourly_usd should price the instance at 0.1 x 730 h."
  }
}

run "localhost_opens_only_ssh" {
  command = plan
  variables { access = "localhost" }
  assert {
    condition     = length(module.aws[0].web_rules) == 0 && length(module.aws[0].ssh_rules) == 1
    error_message = "localhost should open ssh from admin_cidrs and nothing else."
  }
}

run "dns_opens_80_and_443_to_access_cidrs" {
  command = plan
  variables {
    access       = "dns"
    domain       = "langsmith.example.com"
    acme_email   = "ops@example.com"
    access_cidrs = ["0.0.0.0/0"]
  }
  assert {
    condition     = toset(module.aws[0].web_rules) == toset(["80-0.0.0.0/0", "443-0.0.0.0/0"])
    error_message = "dns should open 80 (redirect and Let's Encrypt) and 443."
  }
}

run "an_aws_box_needs_an_ssh_source" {
  command = plan
  variables { admin_cidrs = [] }
  expect_failures = [terraform_data.host]
}

run "a_custom_machine_on_aws_needs_its_instance_type" {
  command = plan
  variables {
    machine = { cpu = 32, memory_gi = 128, disk_gi = 512 }
  }
  expect_failures = [terraform_data.host]
}

run "ssh_to_the_instance_trusts_only_its_generated_host_key" {
  command = plan
  variables { admin_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.admin_cidrs]
}

run "aws_ssh_defaults_to_ubuntu" {
  command = plan
  assert {
    condition     = output.ssh.user == "ubuntu" && output.ssh.port == null
    error_message = "an AWS box is reached as ubuntu on ssh's default port."
  }
}
