# Ingress for LangSmith Self-Hosted on AWS (P0) — ALB Only

**P0 Reference Requirement:** Use **AWS Application Load Balancer (ALB)** via the **AWS Load Balancer Controller**.

This requirement is intentionally opinionated. Ingress configuration is a common source of deployment challenges due to the many valid options available. The reference architecture standardizes on ALB to provide a clear, well-tested path.

If you are not using ALB, you are operating **outside the P0 reference path**.

---

## Supported Ingress (P0)

### ✅ Supported
- **AWS Load Balancer Controller** + **ALB**
- TLS termination using **ACM**
- DNS via **Route53** (or equivalent, but Route53 is assumed for P0 examples)
- Optional but strongly recommended:
  - **AWS WAF** attached to ALB
  - Private-only exposure (internal ALB + VPN/PrivateLink)

### ❌ Explicitly Out of Scope (P0)
- NGINX Ingress Controller
- Traefik
- Istio / service mesh gateways
- API Gateway “fronting” Kubernetes as a substitute for ingress
- CloudFront as a substitute for ingress (can be layered later, but not P0)
- Custom gateways / reverse proxies

These may work. We do not support them in the reference enablement path.

---

## Why We Require ALB

- The ALB path is the **lowest-friction**, most reproducible option for AWS customers.
- It provides a standardized approach that avoids controller complexity and configuration variations.
- It aligns with what most platform teams already deploy and secure.
- It makes debugging straightforward: ALB target health metrics and Kubernetes events provide clear diagnostic information.

This requirement exists to reduce:
- install failures
- support escalations
- time-to-first-trace delays

---

## Required Components

You must have the following working before you install LangSmith:

1. **EKS cluster** running and reachable with `kubectl`
2. **AWS Load Balancer Controller** installed and healthy
3. **IAM permissions** for the controller (IRSA strongly recommended)
4. **Subnet tagging** correct for ALB discovery
5. **ACM certificate** for your DNS name
6. **Route53 record** (or other DNS) pointing to the created ALB

If any of these are missing, Helm installation may succeed, but the product will be unreachable.

---

## Preflight Checks (Ingress-Specific)

### Controller Health
- [ ] The AWS Load Balancer Controller pods are running
- [ ] No CrashLoopBackOff
- [ ] Controller has permission to create:
  - ALBs
  - Target groups
  - Listeners
  - Security group rules

### Subnet Tagging (Common Failure)
- [ ] Subnets are tagged so the controller can discover them for ALB creation
- [ ] You know which subnets should be:
  - public-facing ALB
  - internal-only ALB (if private)

### TLS
- [ ] ACM cert exists in the **same region** as the ALB
- [ ] Cert covers the intended DNS name (`langsmith.<domain>`)

### DNS
- [ ] You can create DNS records for the LangSmith hostname

---

## Mandatory Validation Step: Prove ALB Ingress Works Before LangSmith

Complete this validation **before** installing LangSmith. This step helps isolate ingress configuration issues from application-level problems, making troubleshooting more efficient.

### Step 1: Deploy a tiny test service
Pick one lightweight HTTP echo service (example shown conceptually):

- Create a deployment + service that listens on HTTP (port 80)
- Confirm:
  - `kubectl get pods` shows it running
  - `kubectl get svc` shows endpoints

### Step 2: Create a test Ingress that provisions an ALB
Create an Ingress resource targeting the test service.

What must happen:
- An ALB is created
- A target group is created
- Targets become **healthy**
- You can curl the endpoint and receive a response

### Step 3: If the test Ingress fails, stop
Do not proceed to LangSmith until:
- ALB provisioning works
- target health becomes green
- HTTPS works with your cert

---

## Common Failure Modes (and Where to Look First)

### ALB never gets created
**Likely causes**
- Controller not installed
- Missing IAM permissions
- Subnet discovery fails

**Look at**
- Kubernetes events on the Ingress
- Controller logs
- AWS console: whether any ALB attempt exists

---

### ALB created but targets unhealthy
**Likely causes**
- Wrong service port / targetPort
- Pods not ready
- Health check path mismatch
- Security group blocks node-to-target traffic

**Look at**
- ALB target group health reason
- `kubectl describe ingress ...`
- `kubectl describe svc ...`
- Pod readiness probe status

---

### HTTPS broken / cert issues
**Likely causes**
- Wrong ACM cert
- Cert in wrong region
- DNS mismatch

**Look at**
- ALB listener config
- ACM cert validity and SANs
- DNS record points to the right ALB

---

## Security Recommendations (P0 Baseline)

Minimum expected posture for P0:
- HTTPS only (no plaintext)
- WAF or equivalent rate limiting at the edge
- Prefer private exposure for enterprise deployments
- Least privilege IAM for the controller and application
- No public DB endpoints

---

## What to Document When You Deviate (Off-Reference)

If a customer insists on non-ALB ingress, require them to capture:
- ingress controller type/version
- config manifests
- load balancer / gateway config
- health check settings
- network policies / SG rules

Note: this configuration is **not supported by P0 enablement**.

---

## Done Criteria (Ingress)

Ingress is “done” when:
- [ ] AWS Load Balancer Controller is healthy
- [ ] A test Ingress provisions an ALB successfully
- [ ] Targets are healthy
- [ ] HTTPS works with your DNS name

Only then install LangSmith.
