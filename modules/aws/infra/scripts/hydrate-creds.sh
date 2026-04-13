#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.

# hydrate-creds.sh — Push fresh AWS credentials to the central location.
#
# All parallel test workers read from ~/.aws/credentials [default].
# Run this whenever your SSO session rotates (typically every hour).
#
# Usage:
#   # Auto-mode: reads from the SSO profile configured in ~/.aws/config
#   ./infra/scripts/hydrate-creds.sh
#
#   # Explicit: paste key/secret/token directly (e.g. from AWS console)
#   ./infra/scripts/hydrate-creds.sh KEY SECRET TOKEN
#
#   # From env (if awslogin already exported them):
#   ./infra/scripts/hydrate-creds.sh --from-env
#
# After running, all agents using _aws()/_kubectl()/_helm() from _common.sh
# will automatically pick up the fresh credentials on their next call.

set -euo pipefail

CREDS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
SSO_PROFILE="${AWS_SSO_PROFILE:-804792415534_AdministratorAccessTraining}"

_write_creds() {
  local key="$1" secret="$2" token="$3"

  # Validate they look like real AWS creds
  [[ "$key" =~ ^(ASIA|AKIA|AROA) ]] || { echo "ERROR: key doesn't look like an AWS access key: $key" >&2; exit 1; }
  [[ ${#secret} -ge 20 ]]           || { echo "ERROR: secret too short" >&2; exit 1; }

  # Write atomically via temp file
  local tmp
  tmp=$(mktemp "${CREDS_FILE}.XXXXXX")
  cat > "$tmp" << EOF
[default]
aws_access_key_id = ${key}
aws_secret_access_key = ${secret}
aws_session_token = ${token}
EOF
  mv "$tmp" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
}

_verify() {
  local identity
  if identity=$(env -u AWS_CREDENTIAL_EXPIRATION -u AWS_ACCESS_KEY_ID \
                    -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
                    aws sts get-caller-identity --query 'Arn' --output text 2>&1); then
    echo "  ✔  Verified: $identity"
  else
    echo "  ✘  Credentials written but verification failed: $identity" >&2
    exit 1
  fi
}

# ── Mode selection ────────────────────────────────────────────────────────────

if [[ $# -eq 3 ]]; then
  # Explicit key/secret/token passed as args
  echo "Hydrating credentials from arguments..."
  _write_creds "$1" "$2" "$3"
  _verify

elif [[ "${1:-}" == "--from-env" ]]; then
  # Read from currently exported env vars
  : "${AWS_ACCESS_KEY_ID:?--from-env requires AWS_ACCESS_KEY_ID to be set}"
  : "${AWS_SECRET_ACCESS_KEY:?--from-env requires AWS_SECRET_ACCESS_KEY to be set}"
  : "${AWS_SESSION_TOKEN:?--from-env requires AWS_SESSION_TOKEN to be set}"
  echo "Hydrating credentials from environment..."
  _write_creds "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN"
  _verify

elif [[ $# -eq 0 ]]; then
  # Auto-mode: pull from SSO profile
  echo "Hydrating credentials from SSO profile '${SSO_PROFILE}'..."
  eval "$(aws configure export-credentials --profile "$SSO_PROFILE" --format env 2>&1)" || {
    echo "ERROR: aws configure export-credentials failed. Try: aws sso login --profile $SSO_PROFILE" >&2
    exit 1
  }
  : "${AWS_ACCESS_KEY_ID:?SSO export did not produce AWS_ACCESS_KEY_ID}"
  _write_creds "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN"
  # Unset stale vars so this shell also works cleanly after running
  unset AWS_CREDENTIAL_EXPIRATION
  _verify

else
  echo "Usage:" >&2
  echo "  hydrate-creds.sh                    # auto from SSO profile" >&2
  echo "  hydrate-creds.sh KEY SECRET TOKEN   # explicit" >&2
  echo "  hydrate-creds.sh --from-env         # from exported env vars" >&2
  exit 1
fi

echo "  ✔  ~/.aws/credentials [default] updated"
echo "     All agents using _aws()/_kubectl()/_helm() will use these on next call."
