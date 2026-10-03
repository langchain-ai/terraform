# Ingress Module - Envoy Gateway (default) or GKE Gateway, both via Gateway API

#------------------------------------------------------------------------------
# Gateway API CRDs
#------------------------------------------------------------------------------
locals {
  # Every kubectl provisioner in this module starts with this. Without it kubectl
  # uses whatever context the operator's kubeconfig happens to have selected,
  # which may be an unrelated cluster in another cloud, or nothing at all on a
  # first run - and it applies these resources there instead of failing. The
  # credentials go to a temp file that dies with the provisioner's shell, so the
  # operator's ~/.kube/config and current context are left untouched.
  # Deliberately no `set -e`: the scripts below tolerate some non-zero exits, so
  # only the credential fetch itself is fail-fast.
  kubectl_creds = <<-EOT
    KUBECONFIG="$(mktemp -t ls-kubeconfig.XXXXXX)"
    export KUBECONFIG
    trap 'rm -f "$KUBECONFIG"' EXIT
    gcloud container clusters get-credentials "$LS_CLUSTER_NAME" \
      --region "$LS_REGION" --project "$LS_PROJECT_ID" --quiet || exit 1
  EOT

  # Input values reach these scripts only through the environment, never as
  # script text, so the shell cannot run a value as a command. Each provisioner
  # that uses kubectl_creds sets environment = local.kubectl_env, and each
  # destroy provisioner builds the same names from self.triggers.
  kubectl_env = {
    LS_CLUSTER_NAME = var.cluster_name
    LS_REGION       = var.region
    LS_PROJECT_ID   = var.project_id
    LS_GATEWAY_NAME = var.gateway_name
  }
}

resource "null_resource" "install_gateway_api_crds" {
  count = var.ingress_type == "envoy" ? 1 : 0

  provisioner "local-exec" {
    environment = merge(local.kubectl_env, { LS_GATEWAY_API_CRDS_URL = var.gateway_api_crds_url })
    command     = <<-EOT
      ${local.kubectl_creds}
      # Wait for API server to be accessible
      for i in {1..30}; do
        if kubectl cluster-info >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for API server... ($i/30)"
        sleep 2
      done
      
      # Install Gateway API CRDs
      kubectl apply -f "$LS_GATEWAY_API_CRDS_URL"
    EOT
  }

}

#------------------------------------------------------------------------------
# Envoy Gateway
#------------------------------------------------------------------------------
# v1.2.8 is the last v1.2 patch release. v1.2.6 fixes CVE-2025-24030 and v1.2.7
# fixes CVE-2025-25294. The v1.2 line is end of life, so a later change must
# move to a supported line.
resource "helm_release" "envoy_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "v1.2.8"
  namespace        = "envoy-gateway-system"
  create_namespace = true

  # Control plane service (internal management only)
  set {
    name  = "service.type"
    value = "ClusterIP"
  }

  wait    = true
  timeout = 600

  depends_on = [null_resource.install_gateway_api_crds]
}

#------------------------------------------------------------------------------
# Envoy Gateway Class
#------------------------------------------------------------------------------
locals {
  gateway_class_yaml = var.ingress_type == "envoy" ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "envoy-gateway-class"
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
    }
  }) : ""
}

resource "local_file" "gateway_class" {
  count    = var.ingress_type == "envoy" ? 1 : 0
  filename = "${path.module}/gateway-class.yaml"
  content  = local.gateway_class_yaml
}

resource "null_resource" "apply_gateway_class" {
  count = var.ingress_type == "envoy" ? 1 : 0

  triggers = {
    gateway_class_content = local_file.gateway_class[0].content
    envoy_gateway_ready   = helm_release.envoy_gateway[0].status
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      # Wait for Gateway API CRDs to be available
      for i in {1..30}; do
        if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for Gateway API CRDs... ($i/30)"
        sleep 2
      done
      
      # Apply the GatewayClass
      kubectl apply -f "${local_file.gateway_class[0].filename}"
    EOT
  }

  depends_on = [null_resource.install_gateway_api_crds, helm_release.envoy_gateway, local_file.gateway_class]
}

#------------------------------------------------------------------------------
# Envoy Gateway Resource
#------------------------------------------------------------------------------
locals {
  # Gateway API rejects hostname: "" but treats an absent hostname as "match any
  # host", which is what a deployment reached by IP needs. Merge the key in only
  # when there is a domain to put in it.
  gateway_listener_hostname = var.langsmith_domain != "" ? { hostname = var.langsmith_domain } : {}

  tls_enabled        = var.tls_certificate_source != "none"
  tls_google_managed = var.tls_certificate_source == "google-managed"

  # Every TLS source except google-managed terminates in the Gateway from the
  # Secret named by tls_secret_name, in the LangSmith namespace. A
  # Google-managed certificate stays on the load balancer, which reads it from
  # the certificate map in the Gateway annotation.
  tls_from_secret = local.tls_enabled && !local.tls_google_managed

  # The HTTP listener is always there. With no TLS it serves LangSmith. With TLS
  # it only redirects to HTTPS (https_redirect below), and for Let's Encrypt it
  # also carries the HTTP-01 challenge, whose exact-path route takes precedence
  # over the redirect's prefix match.
  gateway_http_listener = merge({
    name     = "http"
    protocol = "HTTP"
    port     = 80
    allowedRoutes = {
      namespaces = {
        from = "All"
      }
    }
  }, local.gateway_listener_hostname)

  # With no TLS there is nothing to terminate with, so the HTTPS listener is
  # omitted rather than declared unprogrammable.
  gateway_https_listener = merge(
    {
      name     = "https"
      protocol = "HTTPS"
      port     = 443
      allowedRoutes = {
        namespaces = {
          from = "All"
        }
      }
    },
    local.tls_from_secret ? {
      tls = {
        mode = "Terminate"
        certificateRefs = [{
          name      = var.tls_secret_name
          kind      = "Secret"
          namespace = var.langsmith_namespace
        }]
      }
    } : {},
    local.gateway_listener_hostname,
  )

  # Listeners shared by the Envoy and GKE Gateways. Both attach routes from any
  # namespace.
  gateway_listeners = concat(
    [local.gateway_http_listener],
    local.tls_enabled ? [local.gateway_https_listener] : [],
  )

  gateway_yaml = var.ingress_type == "envoy" ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    # No cert-manager.io/cluster-issuer annotation: k8s-bootstrap creates the
    # Certificate explicitly, in the LangSmith namespace. The annotation would
    # have cert-manager's gateway-shim manage a second one for the same Secret.
    metadata = {
      name      = var.gateway_name
      namespace = "envoy-gateway-system"
    }
    spec = {
      gatewayClassName = "envoy-gateway-class"
      listeners        = local.gateway_listeners
    }
  }) : ""
}

resource "local_file" "gateway" {
  count    = var.ingress_type == "envoy" ? 1 : 0
  filename = "${path.module}/gateway.yaml"
  content  = local.gateway_yaml

  lifecycle {
    precondition {
      condition     = !local.tls_google_managed
      error_message = "tls_certificate_source = \"google-managed\" requires ingress_type = \"gke\". Envoy Gateway terminates TLS in the cluster from a Secret: use \"existing\" or \"cert-manager\"."
    }
  }
}

resource "null_resource" "apply_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  triggers = {
    gateway_content     = local_file.gateway[0].content
    gateway_class_ready = null_resource.apply_gateway_class[0].id
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      # Wait for Gateway CRD to be available
      for i in {1..30}; do
        if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for Gateway CRD... ($i/30)"
        sleep 2
      done
      
      # Apply the Gateway
      kubectl apply -f "${local_file.gateway[0].filename}"
    EOT
  }

  depends_on = [null_resource.apply_gateway_class, local_file.gateway]
}

#------------------------------------------------------------------------------
# Gateway delete on destroy
#------------------------------------------------------------------------------
# Envoy Gateway gives the Gateway a LoadBalancer Service. Without this step,
# terraform destroy removes the Envoy Gateway release and the GKE cluster while
# that Service still holds a Google Cloud load balancer, and GKE can leave load
# balancer resources and k8s-* firewall rules on the VPC. GKE recommends that
# you delete LoadBalancer Services before the cluster. This step deletes the
# Gateway and waits for the Service to go, before the release and the cluster
# are destroyed. GKE can still leave the shared k8s-<cluster-id>-node-http-hc
# rule, so TEARDOWN.md tells the operator to check for it.
#
# The step is not on apply_gateway, because a Gateway change replaces that
# resource. A destroy step there would delete the Gateway and release its IP on
# each change. These triggers change only with the project, the region, the
# cluster name, or the Gateway name.
#
# A destroy provisioner can read only self, so the triggers hold the cluster
# coordinates. The step exits 0 when the cluster is already gone, and
# on_failure = continue stops a kubectl error from blocking the destroy.
resource "null_resource" "delete_gateway_on_destroy" {
  count = var.ingress_type == "envoy" ? 1 : 0

  triggers = {
    project_id   = var.project_id
    region       = var.region
    cluster_name = var.cluster_name
    gateway_name = var.gateway_name
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    environment = {
      LS_CLUSTER_NAME = self.triggers.cluster_name
      LS_REGION       = self.triggers.region
      LS_PROJECT_ID   = self.triggers.project_id
      LS_GATEWAY_NAME = self.triggers.gateway_name
    }
    command = <<-EOT
      KUBECONFIG="$(mktemp -t ls-kubeconfig.XXXXXX)"
      export KUBECONFIG
      trap 'rm -f "$KUBECONFIG"' EXIT
      if ! gcloud container clusters get-credentials "$LS_CLUSTER_NAME" \
        --region "$LS_REGION" --project "$LS_PROJECT_ID" --quiet; then
        echo "Cluster $LS_CLUSTER_NAME is not reachable. Skipping the Gateway delete."
        exit 0
      fi
      kubectl delete gateway "$LS_GATEWAY_NAME" -n envoy-gateway-system \
        --ignore-not-found --timeout=120s || true
      # Envoy Gateway deletes the proxy Service. GKE removes the Service only
      # after it deletes the load balancer.
      i=0
      while [ "$i" -lt 60 ]; do
        if ! SVC=$(kubectl get svc -n envoy-gateway-system \
          -l "gateway.envoyproxy.io/owning-gateway-name=$LS_GATEWAY_NAME" \
          -o name 2>/dev/null); then
          echo "WARNING: cannot list the Gateway Services. See TEARDOWN.md."
          exit 0
        fi
        if [ -z "$SVC" ]; then
          exit 0
        fi
        i=$((i + 1))
        echo "Waiting for the Gateway LoadBalancer Service to go... ($i/60)"
        sleep 5
      done
      echo "WARNING: the Gateway LoadBalancer Service is still present. See TEARDOWN.md."
    EOT
  }

  depends_on = [helm_release.envoy_gateway, null_resource.apply_gateway]
}

#------------------------------------------------------------------------------
# ReferenceGrant for cross-namespace secret access
#------------------------------------------------------------------------------
# The Envoy Gateway sits in envoy-gateway-system and its certificate Secret in the
# LangSmith namespace, so every Secret-based source needs this grant, not only
# Let's Encrypt. Without it the HTTPS listener reports RefNotPermitted.
locals {
  reference_grant_enabled = var.ingress_type == "envoy" && local.tls_from_secret

  reference_grant_yaml = local.reference_grant_enabled ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-tls-secret-from-envoy-gateway"
      namespace = var.langsmith_namespace
    }
    spec = {
      from = [{
        group     = "gateway.networking.k8s.io"
        kind      = "Gateway"
        namespace = "envoy-gateway-system"
      }]
      to = [{
        group = ""
        kind  = "Secret"
        name  = var.tls_secret_name
      }]
    }
  }) : ""
}

resource "local_file" "reference_grant" {
  count    = local.reference_grant_enabled ? 1 : 0
  filename = "${path.module}/reference-grant.yaml"
  content  = local.reference_grant_yaml
}

resource "null_resource" "apply_reference_grant" {
  count = local.reference_grant_enabled ? 1 : 0

  triggers = {
    reference_grant_content = local_file.reference_grant[0].content
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      # Wait for ReferenceGrant CRD to be available
      for i in {1..30}; do
        if kubectl get crd referencegrants.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for ReferenceGrant CRD... ($i/30)"
        sleep 2
      done
      
      # Apply the ReferenceGrant
      kubectl apply -f "${local_file.reference_grant[0].filename}"
    EOT
  }

  depends_on = [null_resource.install_gateway_api_crds, local_file.reference_grant, null_resource.apply_gateway]
}

#------------------------------------------------------------------------------
# Get external IP from data plane service
#------------------------------------------------------------------------------
resource "null_resource" "get_external_ip" {
  count = var.ingress_type == "envoy" ? 1 : 0

  triggers = {
    gateway_ready = null_resource.apply_gateway[0].id
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      # Wait for Envoy proxy service to have external IP
      # The Envoy proxy service is created by Envoy Gateway for each Gateway resource
      for i in {1..60}; do
        # Find the Envoy proxy service using label selector
        IP=$(kubectl get svc -n envoy-gateway-system \
          -l "gateway.envoyproxy.io/owning-gateway-name=$LS_GATEWAY_NAME,app.kubernetes.io/component=proxy" \
          -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$IP" ] && [ "$IP" != "null" ]; then
          echo "$IP" > "${path.module}/external-ip.txt"
          exit 0
        fi
        echo "Waiting for external IP... ($i/60)"
        sleep 5
      done
      echo "WARNING: External IP not available yet" > "${path.module}/external-ip.txt"
    EOT
  }

  depends_on = [null_resource.apply_gateway]
}

data "local_file" "external_ip" {
  count      = var.ingress_type == "envoy" ? 1 : 0
  filename   = "${path.module}/external-ip.txt"
  depends_on = [null_resource.get_external_ip]
}

#------------------------------------------------------------------------------
# GKE Gateway (ingress_type = "gke")
#------------------------------------------------------------------------------
# The GKE Gateway controller is built into the cluster (enable_gateway_api on the
# k8s-cluster module), so there are no CRDs or Helm releases to install here. The
# Gateway lives in the LangSmith namespace, which is also where k8s-bootstrap
# creates the TLS secret, so no ReferenceGrant is needed.
locals {
  gke_gateway_enabled = var.ingress_type == "gke"

  # Only global classes can use a global static IP. Regional classes (for example
  # gke-l7-rilb) need a regional address and a proxy-only subnet, which this
  # module does not create.
  gke_gateway_global_ip    = local.gke_gateway_enabled && startswith(var.gke_gateway_class, "gke-l7-global")
  gke_gateway_address_name = "${var.gateway_name}-ip"

  # A Google-managed certificate is attached through its certificate map. GKE
  # rejects a Gateway that sets this annotation and listener certificateRefs
  # together, so the HTTPS listener carries no tls block in that case.
  gke_gateway_annotations = local.tls_google_managed ? {
    "networking.gke.io/certmap" = var.tls_certificate_map_name
  } : {}

  gke_gateway_yaml = local.gke_gateway_enabled ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = merge({
      name      = var.gateway_name
      namespace = var.langsmith_namespace
      }, length(local.gke_gateway_annotations) > 0 ? {
      annotations = local.gke_gateway_annotations
    } : {})
    spec = merge({
      gatewayClassName = var.gke_gateway_class
      listeners        = local.gateway_listeners
      }, local.gke_gateway_global_ip ? {
      addresses = [{
        type  = "NamedAddress"
        value = local.gke_gateway_address_name
      }]
    } : {})
  }) : ""
}

# A static IP lets DNS point at the Gateway before, and after, it is recreated.
resource "google_compute_global_address" "gke_gateway" {
  count   = local.gke_gateway_global_ip ? 1 : 0
  name    = local.gke_gateway_address_name
  project = var.project_id
}

resource "local_file" "gke_gateway" {
  count    = local.gke_gateway_enabled ? 1 : 0
  filename = "${path.module}/gke-gateway.yaml"
  content  = local.gke_gateway_yaml

  lifecycle {
    precondition {
      condition     = var.tls_certificate_source != "letsencrypt"
      error_message = "ingress_type = \"gke\" supports tls_certificate_source = \"none\", \"google-managed\", \"existing\", or \"cert-manager\". The Let's Encrypt HTTP-01 solver is wired to Envoy Gateway only."
    }
    # Regional classes take regional Certificate Manager certificates, which
    # this module does not create yet.
    precondition {
      condition     = !local.tls_google_managed || (local.gke_gateway_global_ip && var.tls_certificate_map_name != "")
      error_message = "tls_certificate_source = \"google-managed\" requires a global gke_gateway_class (gke-l7-global-*) and a certificate map."
    }
  }
}

resource "null_resource" "apply_gke_gateway" {
  count = local.gke_gateway_enabled ? 1 : 0

  triggers = {
    gateway_content = local_file.gke_gateway[0].content
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      # GKE installs the Gateway API CRDs after the cluster update that enables
      # the controller, which can take a few minutes.
      for i in {1..60}; do
        if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for Gateway CRD... ($i/60)"
        sleep 5
      done

      # Apply the Gateway
      kubectl apply -f "${local_file.gke_gateway[0].filename}"
    EOT
  }

  depends_on = [local_file.gke_gateway, google_compute_global_address.gke_gateway]
}

# Same reasoning as delete_gateway_on_destroy, which is Envoy-only. The GKE
# controller holds a finalizer on the Gateway until it has removed the load
# balancer, so a blocking delete waits for that cleanup. It is not on
# apply_gke_gateway, because a Gateway change replaces that resource and would
# delete the Gateway on each edit. It depends on the address so that, in reverse
# on destroy, the Gateway is gone before Terraform tries to release the IP.
resource "null_resource" "delete_gke_gateway_on_destroy" {
  count = local.gke_gateway_enabled ? 1 : 0

  triggers = {
    project_id   = var.project_id
    region       = var.region
    cluster_name = var.cluster_name
    gateway_name = var.gateway_name
    namespace    = var.langsmith_namespace
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    environment = {
      LS_CLUSTER_NAME = self.triggers.cluster_name
      LS_REGION       = self.triggers.region
      LS_PROJECT_ID   = self.triggers.project_id
      LS_GATEWAY_NAME = self.triggers.gateway_name
      LS_NAMESPACE    = self.triggers.namespace
    }
    command = <<-EOT
      KUBECONFIG="$(mktemp -t ls-kubeconfig.XXXXXX)"
      export KUBECONFIG
      trap 'rm -f "$KUBECONFIG"' EXIT
      if ! gcloud container clusters get-credentials "$LS_CLUSTER_NAME" \
        --region "$LS_REGION" --project "$LS_PROJECT_ID" --quiet; then
        echo "Cluster $LS_CLUSTER_NAME is not reachable. Skipping the Gateway delete."
        exit 0
      fi
      if ! kubectl delete gateway "$LS_GATEWAY_NAME" -n "$LS_NAMESPACE" \
        --ignore-not-found --timeout=300s; then
        echo "WARNING: the Gateway is still present. See TEARDOWN.md."
      fi
    EOT
  }

  depends_on = [null_resource.apply_gke_gateway, google_compute_global_address.gke_gateway]
}

#------------------------------------------------------------------------------
# HTTP to HTTPS redirect (any TLS source, either ingress_type)
#------------------------------------------------------------------------------
# With TLS on, the LangSmith HTTPRoute attaches only to the https listener
# (init-values.sh sets gateway.sectionName), and this route answers every
# request on the http listener with a 301 to the same URL over HTTPS. It lives
# beside the Gateway, so it needs no ReferenceGrant.
locals {
  https_redirect_enabled = local.tls_enabled && contains(["envoy", "gke"], var.ingress_type)
  gateway_namespace      = var.ingress_type == "gke" ? var.langsmith_namespace : "envoy-gateway-system"

  https_redirect_yaml = local.https_redirect_enabled ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "${var.gateway_name}-https-redirect"
      namespace = local.gateway_namespace
    }
    spec = merge({
      parentRefs = [{
        name        = var.gateway_name
        namespace   = local.gateway_namespace
        sectionName = "http"
      }]
      rules = [{
        filters = [{
          type = "RequestRedirect"
          requestRedirect = {
            scheme     = "https"
            statusCode = 301
          }
        }]
      }]
      }, var.langsmith_domain != "" ? {
      hostnames = [var.langsmith_domain]
    } : {})
  }) : ""
}

resource "local_file" "https_redirect" {
  count    = local.https_redirect_enabled ? 1 : 0
  filename = "${path.module}/https-redirect.yaml"
  content  = local.https_redirect_yaml
}

resource "null_resource" "apply_https_redirect" {
  count = local.https_redirect_enabled ? 1 : 0

  triggers = {
    route_content = local_file.https_redirect[0].content
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      for i in {1..60}; do
        if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for HTTPRoute CRD... ($i/60)"
        sleep 5
      done

      kubectl apply -f "${local_file.https_redirect[0].filename}"
    EOT
  }

  depends_on = [null_resource.apply_gateway, null_resource.apply_gke_gateway, local_file.https_redirect]
}

#------------------------------------------------------------------------------
# HTTPRoute - Managed by Helm
#------------------------------------------------------------------------------
# HTTPRoute is created by the LangSmith Helm chart when gateway.enabled=true
# Terraform only manages the Gateway resource (infrastructure-level)
