#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# teardown-byo-sg.sh — Delete explicitly supplied security groups so
# Terraform can finish deleting a VPC it created.
#
# Usage (from aws/):
#   make teardown-byo-sg BYO_SECURITY_GROUP_IDS="sg-0123 sg-0456"
#
# Run only after `make destroy` has removed the attached resources but cannot
# delete the VPC. Refuses to run when the VPC is customer-owned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_common.sh"

if [[ -z "${BYO_SECURITY_GROUP_IDS:-}" ]]; then
  fail "BYO_SECURITY_GROUP_IDS is required."
  info 'Example: make teardown-byo-sg BYO_SECURITY_GROUP_IDS="sg-0123 sg-0456"'
  exit 1
fi

_create_vpc=$(_parse_tfvar "create_vpc") || _create_vpc="true"
if [[ "$_create_vpc" != "true" ]]; then
  fail "Terraform does not own this VPC; refusing to delete customer security groups."
  exit 1
fi

# A partial destroy can remove root outputs while leaving the VPC in state.
if ! _vpc_state=$(_terraform -chdir="$INFRA_DIR" state show -no-color 'module.vpc[0].module.vpc.aws_vpc.this[0]' 2>&1); then
  fail "Could not read the Terraform-created VPC from state; refusing to delete security groups."
  printf '  %s\n' "$_vpc_state" >&2
  exit 1
fi

VPC_ID=$(awk '$1 == "id" && $2 == "=" { gsub(/"/, "", $3); print $3 }' <<<"$_vpc_state")
if [[ ! "$VPC_ID" =~ ^vpc-[0-9a-f]+$ ]]; then
  fail "Terraform state does not contain a valid VPC ID; refusing to delete security groups."
  exit 1
fi

# terraform.tfvars takes precedence over TF_VAR_region, then the root default.
REGION=$(_parse_tfvar "region") || REGION="${TF_VAR_region:-us-west-2}"

read -r -a _group_ids <<<"$BYO_SECURITY_GROUP_IDS"
if [[ ${#_group_ids[@]} -eq 0 ]]; then
  fail "BYO_SECURITY_GROUP_IDS must contain at least one security group ID."
  exit 1
fi

_validated_group_ids=()
for _group_id in "${_group_ids[@]}"; do
  # Bash 3.2 treats an empty array as unset under nounset.
  for _validated_group_id in ${_validated_group_ids[@]+"${_validated_group_ids[@]}"}; do
    if [[ "$_group_id" == "$_validated_group_id" ]]; then
      fail "Security group $_group_id was listed more than once."
      exit 1
    fi
  done

  if ! _group_vpc_id=$(_aws ec2 describe-security-groups \
    --group-ids "$_group_id" \
    --region "$REGION" \
    --query 'SecurityGroups[0].VpcId' \
    --output text 2>&1); then
    fail "Could not find security group $_group_id."
    printf '  %s\n' "$_group_vpc_id" >&2
    exit 1
  fi

  if [[ "$_group_vpc_id" != "$VPC_ID" ]]; then
    fail "Security group $_group_id is not in Terraform's VPC ($VPC_ID)."
    exit 1
  fi

  _validated_group_ids+=("$_group_id")
done

header "Delete supplied security groups"
info "VPC: $VPC_ID"
info "Region: $REGION"
for _group_id in "${_group_ids[@]}"; do
  info "Will delete: $_group_id"
done
info "References between these groups will be removed before deletion."

printf '  Type the VPC ID (%s) to delete these groups: ' "$VPC_ID"
read -r _confirm
if [[ "$_confirm" != "$VPC_ID" ]]; then
  echo "  Aborted."
  exit 0
fi

# Separate revocation from deletion to break circular references. Both ends
# must be approved; rules involving groups outside this list remain untouched.
for _group_id in "${_group_ids[@]}"; do
  _referencing_rules=$(_aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$_group_id" \
    --region "$REGION" \
    --query 'SecurityGroupRules[?ReferencedGroupInfo.GroupId != null].[SecurityGroupRuleId,IsEgress,ReferencedGroupInfo.GroupId]' \
    --output text)
  while IFS=$'\t' read -r _rule_id _is_egress _referenced_group_id; do
    [[ -n "$_rule_id" ]] || continue
    for _approved_group_id in "${_group_ids[@]}"; do
      [[ "$_referenced_group_id" == "$_approved_group_id" ]] || continue
      _direction="ingress"
      if [[ "$_is_egress" == "True" || "$_is_egress" == "true" ]]; then
        _direction="egress"
      fi
      _aws ec2 "revoke-security-group-$_direction" \
        --group-id "$_group_id" \
        --security-group-rule-ids "$_rule_id" \
        --region "$REGION"
      break
    done
  done <<<"$_referencing_rules"
done

for _group_id in "${_group_ids[@]}"; do
  _aws ec2 delete-security-group --group-id "$_group_id" --region "$REGION"
  pass "Deleted: $_group_id"
done
