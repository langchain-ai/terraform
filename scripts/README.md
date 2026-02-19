# Scripts

This directory contains automation and validation scripts used with the Terraform and Helm-based deployments.

## Post-install validation (`validate_install.py`)

A **post-apply validation** CLI that confirms a Kubernetes deployment is healthy after `terraform apply` (and any Helm releases) have completed. It is read-only, idempotent, and does not mutate cluster state.

### Requirements

- Python 3.11+
- Dependencies: `click`, `PyYAML`, `kubernetes`

Activate a virtual environment:

```bash
python -m venv .venv
source .venv/bin/activate
```

Install with:

```bash
pip install click pyyaml kubernetes
```

Or from a requirements file (create one if needed):

```bash
pip install -r scripts/requirements.txt
```

Example `scripts/requirements.txt`:

```
click>=8.0
PyYAML>=6.0
kubernetes>=28.0
```

### Usage

**Basic (required: config file and kubeconfig/context):**

```bash
python scripts/validate_install.py --config scripts/validate_config.yaml
```

**With explicit kubeconfig and context:**

```bash
export KUBECONFIG=/path/to/kubeconfig
python scripts/validate_install.py --config scripts/validate_config.yaml --context my-context
```

**Restrict to a single namespace:**

```bash
python scripts/validate_install.py --config scripts/validate_config.yaml --namespace langsmith
```

**Require LoadBalancer addresses and Ingress/Gateway addresses:**

```bash
python scripts/validate_install.py --config scripts/validate_config.yaml \
  --require-loadbalancer-addresses \
  --require-ingress-addresses
```

**Faster feedback (fail on first failure, shorter timeout):**

```bash
python scripts/validate_install.py --config scripts/validate_config.yaml \
  --fail-fast \
  --timeout-seconds 120 \
  --poll-seconds 5
```

**Show passing checks and JSON logs (e.g. for CI):**

```bash
python scripts/validate_install.py --config scripts/validate_config.yaml \
  --show-passing \
  --json-logs
```

**Skip specific checks:**

```bash
python scripts/validate_install.py --config scripts/validate_config.yaml \
  --skip-helm-release-checks \
  --skip-jobs \
  --skip-ingress \
  --skip-services
```

### CLI reference

| Flag | Default | Description |
|------|--------|-------------|
| `--config` | (required) | Path to validation config YAML |
| `--kubeconfig` | `KUBECONFIG` env or `~/.kube/config` | Kubeconfig file path |
| `--context` | (default context) | Kubernetes context name |
| `--timeout-seconds` | 900 | Max time to run validations (retries until then) |
| `--poll-seconds` | 10 | Seconds between poll rounds when checks fail |
| `--fail-fast` | false | Stop on first failure (no retries) |
| `--json-logs` | false | Emit log lines as JSON |
| `--show-passing` | false | Include passing checks in output (otherwise only failures + summary) |
| `--namespace` | (from config) | Override: only check this namespace |
| `--require-loadbalancer-addresses` | false | Require LoadBalancer Services to have an address |
| `--require-ingress-addresses` | false | Require Ingress/Gateway resources to have addresses |
| `--skip-helm-release-checks` | false | Skip Helm release presence checks |
| `--skip-jobs` | false | Skip Job completion checks |
| `--skip-ingress` | false | Skip Ingress/Gateway checks |
| `--skip-services` | false | Skip Service checks |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All validations passed |
| 1 | One or more validations failed, or timeout reached |
| 2 | Configuration or cluster connection error (missing config, invalid kubeconfig, etc.) |

### Config file

Copy the example and edit for your deployment:

```bash
cp scripts/validate_config.example.yaml scripts/validate_config.yaml
```

Config schema (YAML):

- **namespaces**: list of namespaces to check (ignored if `--namespace` is set).
- **helm_releases**: list of releases; each can have:
  - `name`, `namespace`
  - `selector_labels` (optional): labels to find resources (e.g. `app.kubernetes.io/instance: <name>`).
  - `required_kinds`: list of kinds that must exist (Deployment, StatefulSet, DaemonSet, Job, Service, Ingress, Gateway).
  - `allow_no_resources`: if true, release is considered OK even when no matching resources are found.
- **resource_checks**: options for deployments, statefulsets, daemonsets, pods, jobs, services, ingress (see example).
- **exclusions**: namespaces, label_selectors, or resource_names to skip (e.g. Helm test pods).

### Integration with Terraform / CI

**After Terraform apply (local or CI):**

```bash
terraform apply -auto-approve
python scripts/validate_install.py --config scripts/validate_config.yaml
if [ $? -ne 0 ]; then
  echo "Validation failed"
  exit 1
fi
```

**With kubeconfig from Terraform output:**

If your Terraform module outputs a kubeconfig path or command (e.g. `gcloud container clusters get-credentials ...`), run that first, then validate:

```bash
terraform output -raw kubeconfig_command | bash
python scripts/validate_install.py --config scripts/validate_config.yaml
```

**CI (e.g. GitHub Actions) with JSON logs and fail-fast:**

```yaml
- name: Validate install
  run: |
    python scripts/validate_install.py --config scripts/validate_config.yaml \
      --timeout-seconds 600 \
      --poll-seconds 15 \
      --fail-fast \
      --json-logs
```

**Idempotency:** The script only reads from the Kubernetes API. Safe to run repeatedly; no cluster state is changed.

### What is validated

1. **Cluster connectivity** – API reachable, list namespaces works.
2. **Helm release presence** – For each configured release, resources with the given labels (or Helm release secrets) exist.
3. **Workloads** – Deployments (available replicas, generation), StatefulSets (ready/updated replicas), DaemonSets (number ready).
4. **Pods** – Phase Running (or Succeeded if allowed), Ready condition; hard failure on CrashLoopBackOff / ImagePullBackOff / ErrImagePull.
5. **Jobs** – Succeeded count meets completions; failed count zero when `forbid_failed` is true.
6. **Services** – Present; optionally that LoadBalancer services have ingress addresses.
7. **Ingress / Gateway API** – Optionally that Ingress or Gateway resources have addresses and (for Gateway) Programmed condition.

Validation runs in a loop until all checks pass or the timeout is reached (or `--fail-fast` on first failure). Output is human-readable by default; use `--json-logs` for machine parsing.
