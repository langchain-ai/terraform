# ── Firewall subnet ───────────────────────────────────────────────────────────
# Sits in the same AZ as the single NAT gateway so egress traffic flows:
#   private subnet → firewall endpoint → NAT gateway → internet gateway
resource "aws_subnet" "firewall" {
  vpc_id            = var.vpc_id
  cidr_block        = var.firewall_subnet_cidr
  availability_zone = var.nat_gateway_az

  tags = merge(var.tags, { Name = "${var.name}-firewall" })
}

# ── Firewall subnet route table ───────────────────────────────────────────────
# Traffic that clears the firewall policy exits via the NAT gateway.
resource "aws_route_table" "firewall" {
  vpc_id = var.vpc_id
  tags   = merge(var.tags, { Name = "${var.name}-firewall-rt" })
}

resource "aws_route" "firewall_to_nat" {
  route_table_id         = aws_route_table.firewall.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_gateway_id
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

# ── Domain allowlist rule group ───────────────────────────────────────────────
# Uses AWS Network Firewall's built-in domain list type which inspects TLS SNI
# for HTTPS and the Host header for HTTP — no Suricata rule authoring needed.
resource "aws_networkfirewall_rule_group" "egress_allow" {
  capacity = 100
  name     = "${var.name}-egress-allow"
  type     = "STATEFUL"
  tags     = var.tags

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = var.allowed_fqdns
      }
    }
  }
}

# ── Firewall policy ───────────────────────────────────────────────────────────
# Stateless layer forwards everything to the stateful engine.
# Stateful engine: apply the allowlist, then drop all remaining established flows.
resource "aws_networkfirewall_firewall_policy" "this" {
  name = "${var.name}-egress-policy"
  tags = var.tags

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.egress_allow.arn
    }

    # Drop any established connection not matched by the allowlist above.
    stateful_default_actions = ["aws:drop_established"]
  }
}

# ── Firewall ──────────────────────────────────────────────────────────────────
resource "aws_networkfirewall_firewall" "this" {
  name                = "${var.name}-egress"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn
  vpc_id              = var.vpc_id
  tags                = var.tags

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }
}

# ── Firewall endpoint ID ──────────────────────────────────────────────────────
# The endpoint is available only after the firewall reaches READY state.
# sync_states is a set; with one subnet there is exactly one entry.
locals {
  firewall_endpoint_id = [
    for ss in aws_networkfirewall_firewall.this.firewall_status[0].sync_states :
    ss.attachment[0].endpoint_id
  ][0]
}

# ── Private route table update ────────────────────────────────────────────────
# Redirect 0.0.0.0/0 in every private route table from NAT GW to the firewall.
# The vpc module no longer owns this route when firewall_enabled = true
# (it writes 100.64.0.0/10 → NAT GW instead, which is effectively a no-op route).
resource "aws_route" "private_to_firewall" {
  for_each = toset(var.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoint_id
}
