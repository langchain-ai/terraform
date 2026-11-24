# cloud = aws: one instance of the preset's size, ssh from the operator only, and HTTPS opened only for
# the access modes that serve LangSmith on the address. No AWS credentials: every call is mocked.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0123456789abcdef0"] }
  }
  mock_data "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0", vpc_id = "vpc-0123456789abcdef0" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
}

variables {
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.5.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
  cloud                 = "aws"
  box                   = "s"
  ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test"
  admin_cidrs           = ["203.0.113.7/32"]
  langsmith_license_key = "test"
}

run "the_preset_picks_the_instance" {
  command = plan
  assert {
    condition     = module.aws[0].instance_type == "m7i.xlarge"
    error_message = "box s should run on m7i.xlarge (4 vCPU, 16 GiB)."
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

run "aws_ssh_defaults_to_ubuntu" {
  command = plan
  assert {
    condition     = output.ssh.user == "ubuntu" && output.ssh.port == null
    error_message = "an AWS box is reached as ubuntu on ssh's default port."
  }
}
