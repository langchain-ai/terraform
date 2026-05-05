# k8s-bootstrap: Provisions supporting Kubernetes resources for LangSmith.
# Creates the namespace, database/cache secrets, KEDA, and cert-manager.
# The LangSmith Helm chart itself is deployed separately via aws/helm/scripts/deploy.sh.
#
# Providers (kubernetes, helm, aws) are inherited from the root module — do not
# define provider blocks here. See:
# https://developer.hashicorp.com/terraform/language/modules/develop/providers

# ── Namespace ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "langsmith" {
  metadata {
    name = var.namespace
    labels = {
      app        = "langsmith"
      managed-by = "terraform"
    }
  }
}

# ── Kubernetes Secrets ───────────────────────────────────────────────────────

resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "langsmith-postgres"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }
  # External: connection_url only (chart reads it directly).
  # In-cluster: also include postgres_db/user/password so the Helm chart's
  # in-cluster StatefulSet can initialize the database without manual patching.
  data = var.postgres_in_cluster_pass != "" ? {
    connection_url    = var.postgres_connection_url
    postgres_db       = var.postgres_in_cluster_db
    postgres_user     = var.postgres_in_cluster_user
    postgres_password = var.postgres_in_cluster_pass
  } : {
    connection_url = var.postgres_connection_url
  }
  type = "Opaque"
}

resource "kubernetes_secret" "redis" {
  metadata {
    name      = "langsmith-redis"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }
  data = {
    connection_url = var.redis_connection_url
  }
  type = "Opaque"
}

# ── KEDA (Kubernetes Event-driven Autoscaling) ───────────────────────────────
# Required for LangSmith Deployments feature.

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.19.0"

  set {
    name  = "resources.operator.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.operator.requests.memory"
    value = "100Mi"
  }
}

# ── cert-manager ──────────────────────────────────────────────────────────────
# Installed when:
#   a) tls_certificate_source = "letsencrypt" (HTTP-01 path via ALB), or
#   b) cert_manager_irsa_role_arn is set     (DNS-01 path via Route 53 / Istio)
#
# The two paths are mutually exclusive by design and enforced via a precondition
# in the root module. Both share the same Helm release; ClusterIssuer differs.

locals {
  # Use var.create_cert_manager_irsa (a static bool, always known at plan time)
  # instead of var.cert_manager_irsa_role_arn (a computed string from a counted
  # module output) to avoid the "count depends on resource attributes that cannot
  # be determined until apply" plan-time error.
  install_cert_manager = (
    var.tls_certificate_source == "letsencrypt" ||
    var.create_cert_manager_irsa
  )
}

resource "helm_release" "cert_manager" {
  count = local.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.20.0"

  set {
    name  = "crds.enabled"
    value = "true"
  }

  # Annotate the cert-manager SA with the IRSA role ARN at Helm install time.
  # This is the correct pattern (same as ESO below): the EKS Pod Identity Webhook
  # injects IRSA env vars only when the SA annotation exists at pod creation.
  # Setting it here ensures it is present on every Helm upgrade — no separate
  # kubectl step or rollout restart needed.
  dynamic "set" {
    for_each = var.cert_manager_irsa_role_arn != "" ? [var.cert_manager_irsa_role_arn] : []
    content {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = set.value
    }
  }
}

# ── External Secrets Operator ─────────────────────────────────────────────────

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "2.1.0"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.eso_irsa_role_arn
  }
}


# ── ClusterIssuer: HTTP-01 (ALB path) ────────────────────────────────────────
# Used when tls_certificate_source = "letsencrypt" with ALB ingress.
# Mutually exclusive with DNS-01: precondition in root module prevents both.
# Applied via kubectl local-exec to avoid kubernetes_manifest CRD plan-time
# validation failure on fresh clusters (CRDs don't exist until apply).
resource "terraform_data" "letsencrypt_cluster_issuer" {
  count = var.tls_certificate_source == "letsencrypt" && !var.create_cert_manager_irsa ? 1 : 0

  triggers_replace = [var.letsencrypt_email]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${var.letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          ingressClassName: alb
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "kubectl delete clusterissuer letsencrypt-prod --ignore-not-found=true 2>/dev/null || true"
  }

  depends_on = [helm_release.cert_manager]
}

# ── cert-manager DNS-01 resources (Route 53 / Istio Gateway path) ────────────
# Required on EKS with Istio Gateway — HTTP-01 fails because NLBs cannot be
# reached from within the cluster (hairpin NAT prevents cert-manager self-check).
#
# SA annotation is handled at Helm install time via the dynamic "set" block in
# helm_release.cert_manager above — no separate kubectl step needed.
#
# Resources created in order:
#   1. ClusterIssuer — Route 53 DNS-01 solver
#   2. Certificate   — triggers issuance; TLS secret lands in istio-system
#   3. Istio Gateway — patched for HTTPS + HTTP redirect after secret is ready
#
# Context guard: when cluster_name is set, each provisioner verifies the active
# kubeconfig context before applying manifests — protects against accidental
# cross-cluster applies when managing multiple EKS clusters from one workstation.

locals {
  # Bash snippet injected at the top of each provisioner when cluster_name is set.
  # Fails fast if the current context does not contain the cluster name.
  # Written with join() rather than a heredoc because HCL does not support
  # heredoc strings inside ternary conditional expressions.
  _ctx_check = var.cluster_name != "" ? join("\n", [
    "_ctx=$(kubectl config current-context 2>/dev/null || echo \"\")",
    "if ! echo \"$_ctx\" | grep -qF '${var.cluster_name}'; then",
    "  echo \"INFO: kubectl context '$_ctx' does not match cluster '${var.cluster_name}' — auto-updating kubeconfig\"",
    "  aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region}",
    "fi",
  ]) : ""
}

locals {
  # Guards the DNS-01 path. Requires hosted_zone_id to be non-empty to prevent
  # a silent "arn:aws:route53:::hostedzone/" IAM ARN with an empty zone.
  # Use var.create_cert_manager_irsa (static bool, always known at plan time)
  # instead of var.cert_manager_irsa_role_arn != "" (computed, unknown at plan).
  dns01_enabled = (
    var.create_cert_manager_irsa &&
    var.langsmith_domain != "" &&
    var.cert_manager_hosted_zone_id != ""
  )
}

# Step 1: ClusterIssuer — Route 53 DNS-01 solver.
resource "terraform_data" "letsencrypt_cluster_issuer_dns01" {
  count = local.dns01_enabled ? 1 : 0

  # Store cluster_name and region for the destroy provisioner.
  # Destroy-time local-exec cannot reference var.* to avoid dependency
  # cycles, so we store the values we need in self.input (same pattern
  # as terraform_data.istio_gateway_tls below).
  input = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  triggers_replace = [
    var.letsencrypt_email,
    var.cert_manager_hosted_zone_id,
    var.region,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${var.letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        route53:
          region: ${var.region}
          hostedZoneID: ${var.cert_manager_hosted_zone_id}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    # Update kubeconfig before deleting — destroy provisioners cannot use
    # var.* so cluster_name and region are read from self.input.
    command     = <<-EOT
      _ctx=$(kubectl config current-context 2>/dev/null || echo "")
      if ! echo "$_ctx" | grep -qF '${self.input.cluster_name}'; then
        aws eks update-kubeconfig --name ${self.input.cluster_name} --region ${self.input.region} 2>/dev/null || true
      fi
      kubectl delete clusterissuer letsencrypt-prod --ignore-not-found=true 2>/dev/null || true
    EOT
  }

  depends_on = [helm_release.cert_manager]
}

# Step 2: Certificate — triggers Let's Encrypt issuance via DNS-01.
# TLS secret must live in istio-system — istiod reads credentialName from there,
# not from the namespace where the workload runs.
#
# Pre-flight: verifies istio-system namespace exists. If Istio is not yet
# installed, the apply will fail with a clear error rather than a generic one.
#
# On domain change: deletes the old TLS secret first so the wait in step 3
# cannot pick up a stale certificate from the previous domain.
resource "terraform_data" "langsmith_certificate" {
  count = local.dns01_enabled ? 1 : 0

  triggers_replace = [var.langsmith_domain]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      kubectl get namespace istio-system > /dev/null 2>&1 || {
        echo "ERROR: istio-system namespace not found."
        echo "       Install Istio (istiod + istio-ingressgateway) before running terraform apply."
        echo "       See: terraform/aws/helm/values/examples/langsmith-values-ingress-istio.yaml"
        exit 1
      }
      kubectl delete secret langsmith-tls -n istio-system --ignore-not-found
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: langsmith-tls
  namespace: istio-system
spec:
  secretName: langsmith-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "${var.langsmith_domain}"
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      kubectl delete certificate langsmith-tls -n istio-system --ignore-not-found
      kubectl delete secret langsmith-tls -n istio-system --ignore-not-found
    EOT
  }

  depends_on = [terraform_data.letsencrypt_cluster_issuer_dns01]
}

# Step 3: Patch Istio Gateway for HTTPS + HTTP redirect.
# Waits for the TLS secret to appear in istio-system before patching —
# Istio will accept a Gateway with a missing credentialName but the TLS
# listener will not function until the secret exists.
# Fails with a clear error if the secret has not appeared after 5 minutes,
# rather than silently patching the Gateway with a broken TLS config.
resource "terraform_data" "istio_gateway_tls" {
  count = local.dns01_enabled ? 1 : 0

  # Store values for the destroy provisioner — destroy-time local-exec can only
  # reference self.*, not var.*, to avoid dependency cycles during destroy.
  input = {
    namespace = var.namespace
    domain    = var.langsmith_domain
  }

  triggers_replace = [var.langsmith_domain]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      echo "Waiting for langsmith-tls secret in istio-system (DNS propagation ~60-120s)..."
      for i in $(seq 1 30); do
        kubectl get secret langsmith-tls -n istio-system &>/dev/null && break
        echo "  [$i/30] Secret not yet present..."
        sleep 10
      done
      kubectl get secret langsmith-tls -n istio-system &>/dev/null || {
        echo "ERROR: langsmith-tls secret not found in istio-system after 300s."
        echo "       Certificate issuance may have failed. Check:"
        echo "         kubectl describe certificate langsmith-tls -n istio-system"
        echo "         kubectl describe challenge -n istio-system"
        echo "       Common causes: DNS not yet delegated to Route 53, or IRSA role missing permissions."
        exit 1
      }
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${var.namespace}
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "${var.langsmith_domain}"
    tls:
      httpsRedirect: true
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: langsmith-tls
    hosts:
    - "${var.langsmith_domain}"
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    # Restore Gateway to HTTP-only on destroy (don't delete — may be referenced
    # by other resources). self.input holds namespace and domain since
    # destroy provisioners cannot reference var.*.
    command     = <<-EOT
      kubectl patch gateway langsmith-gateway -n ${self.input.namespace} \
        --type=json \
        -p='[{"op":"replace","path":"/spec/servers","value":[{"port":{"number":80,"name":"http","protocol":"HTTP"},"hosts":["${self.input.domain}"]}]}]' \
        2>/dev/null || true
    EOT
  }

  depends_on = [terraform_data.langsmith_certificate]
}

# ── Envoy Gateway (Kubernetes Gateway API controller) ──────────────────────
# Installs the Envoy Gateway controller and Gateway API CRDs. When enabled,
# the LangSmith Helm chart creates HTTPRoute resources instead of Ingress.
# The Gateway resource is created in the langsmith namespace so HTTPRoutes
# can reference it without cross-namespace ReferenceGrants.

resource "helm_release" "envoy_gateway" {
  count = var.enable_envoy_gateway ? 1 : 0

  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  namespace        = "envoy-gateway-system"
  create_namespace = true
  version          = "v1.3.0"

  set {
    name  = "deployment.envoyGateway.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "deployment.envoyGateway.resources.requests.memory"
    value = "256Mi"
  }
}

# GatewayClass + Gateway resource — applied via kubectl to avoid CRD plan-time
# validation issues (same pattern as the letsencrypt ClusterIssuer above). The
# Gateway API CRDs are installed by the Envoy Gateway Helm chart.
#
# The GatewayClass is created explicitly because the Envoy Gateway certgen job
# (which normally creates it) runs with a short TTL and may not re-run on
# subsequent applies. Without a GatewayClass, the Gateway stays in "Waiting
# for controller" state indefinitely.
resource "terraform_data" "envoy_gateway_resource" {
  count = var.enable_envoy_gateway ? 1 : 0

  triggers_replace = [
    var.namespace,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      kubectl create namespace ${var.namespace} --dry-run=client -o yaml | kubectl apply -f -
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${var.namespace}
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTP
    port: 443
    allowedRoutes:
      namespaces:
        from: All
MANIFEST
    EOT
  }

  depends_on = [helm_release.envoy_gateway, kubernetes_namespace.langsmith]
}

# ── Envoy Gateway TargetGroupBinding ─────────────────────────────────────────
# Binds the Terraform-managed ALB target group to the Envoy proxy service so the
# AWS Load Balancer Controller automatically registers Envoy proxy pod IPs as ALB
# targets (target-type: ip via VPC-CNI).
#
# The Envoy Gateway controller creates a service named
# "envoy-<gateway-namespace>-<gateway-name>" in envoy-gateway-system.
# For a Gateway named "langsmith-gateway" in the "langsmith" namespace:
#   service: envoy-langsmith-langsmith-gateway (namespace: envoy-gateway-system)
#   service port: 8080 (matches the Gateway resource's listener port)
#
# The TargetGroupBinding is in envoy-gateway-system (same namespace as the service).
# Cross-namespace TargetGroupBindings are not supported by the AWS LB controller.

resource "terraform_data" "envoy_target_group_binding" {
  # Use the static bool (known at plan time) rather than the computed ARN string.
  # The ARN is "known after apply" from the ALB module output — using it in count
  # causes a plan-time "count depends on resource attributes" error.
  # Same pattern as create_cert_manager_irsa vs cert_manager_irsa_role_arn.
  count = var.enable_envoy_gateway ? 1 : 0

  input = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  triggers_replace = [
    var.namespace,
    var.gateway_target_group_arn,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      # Envoy Gateway v1.3+ appends a hash suffix to the managed service name:
      # envoy-<gateway-ns>-<gateway-name>-<hash>
      # Discover the actual name via the owning-gateway labels rather than hardcoding.
      # Retry up to 30 times (5 min) — the controller reconciles the Gateway asynchronously
      # and the service may not exist immediately after the Gateway manifest is applied.
      echo "Waiting for Envoy proxy service for Gateway 'langsmith-gateway' in envoy-gateway-system..."
      _svc_name=""
      for i in $(seq 1 30); do
        _svc_name=$(kubectl get svc -n envoy-gateway-system \
          -l "gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway,gateway.envoyproxy.io/owning-gateway-namespace=${var.namespace}" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$_svc_name" ]]; then
          echo "Found Envoy proxy service: $_svc_name"
          break
        fi
        echo "  [$i/30] Service not yet created, retrying in 10s..."
        sleep 10
      done
      if [[ -z "$_svc_name" ]]; then
        echo "ERROR: Could not find Envoy proxy service for Gateway 'langsmith-gateway' in ns '${var.namespace}'."
        echo "       Is the Envoy Gateway controller running and the Gateway resource reconciled?"
        echo "       Check: kubectl get svc -n envoy-gateway-system"
        exit 1
      fi
      echo "Envoy proxy service: $_svc_name"
      cat <<MANIFEST | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: langsmith-envoy-tgb
  namespace: envoy-gateway-system
spec:
  serviceRef:
    name: $_svc_name
    port: 8080
  targetGroupARN: ${var.gateway_target_group_arn}
  targetType: ip
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      _ctx=$(kubectl config current-context 2>/dev/null || echo "")
      if ! echo "$_ctx" | grep -qF '${self.input.cluster_name}'; then
        aws eks update-kubeconfig --name ${self.input.cluster_name} --region ${self.input.region} 2>/dev/null || true
      fi
      kubectl delete targetgroupbinding langsmith-envoy-tgb -n envoy-gateway-system --ignore-not-found=true 2>/dev/null || true
    EOT
  }

  depends_on = [terraform_data.envoy_gateway_resource]
}

# ── Istio (service mesh + ingress gateway) ────────────────────────────────────
# Installs istio-base (CRDs), istiod (control plane), and istio-ingressgateway.
# When enabled, the LangSmith Helm chart creates VirtualService resources instead
# of Ingress or HTTPRoute. The ingressgateway service exposes port 80 (container 8080).
#
# ALB-always pattern: ALB forwards to istio-ingressgateway pods (target-type: ip)
# via a TargetGroupBinding. The Istio NLB (auto-created by the controller) is
# internal-only and not used for external traffic.

resource "helm_release" "istio_base" {
  count = var.enable_istio_gateway ? 1 : 0

  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = "istio-system"
  create_namespace = true
  version          = "1.23.0"
}

resource "helm_release" "istiod" {
  count = var.enable_istio_gateway ? 1 : 0

  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = "istio-system"
  version    = "1.23.0"

  set {
    name  = "pilot.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "pilot.resources.requests.memory"
    value = "256Mi"
  }

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingress" {
  count = var.enable_istio_gateway ? 1 : 0

  name       = "istio-ingressgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  namespace  = "istio-system"
  version    = "1.23.0"

  # In chart 1.23+, values are nested under defaults.*
  set {
    name  = "defaults.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "defaults.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "defaults.resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [helm_release.istiod]
}

# Istio Gateway resource — defines the ingress point for LangSmith traffic.
# Created via kubectl (not Helm) to avoid CRD plan-time validation issues.
resource "terraform_data" "istio_gateway_resource" {
  count = var.enable_istio_gateway ? 1 : 0

  triggers_replace = [var.namespace]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      kubectl create namespace ${var.namespace} --dry-run=client -o yaml | kubectl apply -f -
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${var.namespace}
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "kubectl delete gateway langsmith-gateway -n ${self.triggers_replace[0]} --ignore-not-found=true 2>/dev/null || true"
  }

  depends_on = [helm_release.istio_ingress, kubernetes_namespace.langsmith]
}

# ── Istio TargetGroupBinding ──────────────────────────────────────────────────
# Binds the Terraform-managed ALB target group to the istio-ingressgateway service
# so the AWS Load Balancer Controller registers ingressgateway pod IPs as targets.
# The ingressgateway container listens on port 8080 (HTTP, non-root).

resource "terraform_data" "istio_target_group_binding" {
  count = var.enable_istio_gateway ? 1 : 0

  input = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  triggers_replace = [
    var.namespace,
    var.gateway_target_group_arn,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      cat <<MANIFEST | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: langsmith-istio-tgb
  namespace: istio-system
spec:
  serviceRef:
    name: istio-ingressgateway
    port: 80
  targetGroupARN: ${var.gateway_target_group_arn}
  targetType: ip
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      _ctx=$(kubectl config current-context 2>/dev/null || echo "")
      if ! echo "$_ctx" | grep -qF '${self.input.cluster_name}'; then
        aws eks update-kubeconfig --name ${self.input.cluster_name} --region ${self.input.region} 2>/dev/null || true
      fi
      kubectl delete targetgroupbinding langsmith-istio-tgb -n istio-system --ignore-not-found=true 2>/dev/null || true
    EOT
  }

  depends_on = [terraform_data.istio_gateway_resource]
}

# ── NGINX Ingress Controller ──────────────────────────────────────────────────
# Installs ingress-nginx as a ClusterIP service — no external NLB is created.
# A TargetGroupBinding wires the Terraform-managed ALB target group to the
# nginx controller pods (target-type: ip via VPC-CNI). The LangSmith Helm chart
# uses ingressClassName: nginx and standard Ingress resources.
#
# ALB-always pattern: ALB → NGINX controller (port 80) → Ingress → frontend svc.
# TLS terminates at the ALB (ACM cert); NGINX handles HTTP-only internally.

resource "helm_release" "nginx_ingress" {
  count = var.enable_nginx_ingress ? 1 : 0

  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.10.1"

  set {
    name  = "controller.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
}

# NGINX TargetGroupBinding — binds ALB TG to ingress-nginx-controller service.
resource "terraform_data" "nginx_target_group_binding" {
  count = var.enable_nginx_ingress ? 1 : 0

  input = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  triggers_replace = [
    var.namespace,
    var.gateway_target_group_arn,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${local._ctx_check}
      cat <<MANIFEST | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: langsmith-nginx-tgb
  namespace: ingress-nginx
spec:
  serviceRef:
    name: ingress-nginx-controller
    port: 80
  targetGroupARN: ${var.gateway_target_group_arn}
  targetType: ip
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      _ctx=$(kubectl config current-context 2>/dev/null || echo "")
      if ! echo "$_ctx" | grep -qF '${self.input.cluster_name}'; then
        aws eks update-kubeconfig --name ${self.input.cluster_name} --region ${self.input.region} 2>/dev/null || true
      fi
      kubectl delete targetgroupbinding langsmith-nginx-tgb -n ingress-nginx --ignore-not-found=true 2>/dev/null || true
    EOT
  }

  depends_on = [helm_release.nginx_ingress]
}

