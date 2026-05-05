# Ingress Module - Envoy Gateway (Gateway API)

#------------------------------------------------------------------------------
# Gateway API CRDs
#------------------------------------------------------------------------------
locals {
  # Use standard-install.yaml (v1.4.1) for production stability
  gateway_api_crds_url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml"
}

resource "null_resource" "install_gateway_api_crds" {
  count = var.ingress_type == "envoy" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for API server to be accessible
      for i in {1..30}; do
        if kubectl cluster-info >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for API server... ($i/30)"
        sleep 2
      done
      
      # Install Gateway API CRDs
      kubectl apply -f ${local.gateway_api_crds_url}
    EOT
  }

}

#------------------------------------------------------------------------------
# Envoy Gateway
#------------------------------------------------------------------------------
resource "helm_release" "envoy_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "v1.2.0"
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
    command = <<-EOT
      # Wait for Gateway API CRDs to be available
      for i in {1..30}; do
        if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for Gateway API CRDs... ($i/30)"
        sleep 2
      done
      
      # Apply the GatewayClass
      kubectl apply -f ${local_file.gateway_class[0].filename}
    EOT
  }

  depends_on = [null_resource.install_gateway_api_crds, helm_release.envoy_gateway, local_file.gateway_class]
}

#------------------------------------------------------------------------------
# Envoy Gateway Resource
#------------------------------------------------------------------------------
locals {
  gateway_yaml = var.ingress_type == "envoy" ? yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = "envoy-gateway-system"
      annotations = var.tls_certificate_source == "letsencrypt" ? {
        "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      } : {}
    }
    spec = {
      gatewayClassName = "envoy-gateway-class"
      listeners = concat(
        # HTTP listener for ACME challenge (required for Let's Encrypt)
        var.tls_certificate_source == "letsencrypt" ? [{
          name     = "http"
          protocol = "HTTP"
          port     = 80
          hostname = var.langsmith_domain
          allowedRoutes = {
            namespaces = {
              from = "All"
            }
          }
        }] : [],
        # HTTPS listener
        [{
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          hostname = var.langsmith_domain
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              name      = var.tls_secret_name
              kind      = "Secret"
              namespace = var.langsmith_namespace
            }]
          }
          allowedRoutes = {
            namespaces = {
              from = "All"
            }
          }
        }]
      )
    }
  }) : ""
}

resource "local_file" "gateway" {
  count    = var.ingress_type == "envoy" ? 1 : 0
  filename = "${path.module}/gateway.yaml"
  content  = local.gateway_yaml
}

resource "null_resource" "apply_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  triggers = {
    gateway_content     = local_file.gateway[0].content
    gateway_class_ready = null_resource.apply_gateway_class[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for Gateway CRD to be available
      for i in {1..30}; do
        if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for Gateway CRD... ($i/30)"
        sleep 2
      done
      
      # Apply the Gateway
      kubectl apply -f ${local_file.gateway[0].filename}
    EOT
  }

  depends_on = [null_resource.apply_gateway_class, local_file.gateway]
}

#------------------------------------------------------------------------------
# ReferenceGrant for cross-namespace secret access
#------------------------------------------------------------------------------
locals {
  reference_grant_yaml = var.ingress_type == "envoy" && var.tls_certificate_source == "letsencrypt" ? yamlencode({
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
  count    = var.ingress_type == "envoy" && var.tls_certificate_source == "letsencrypt" ? 1 : 0
  filename = "${path.module}/reference-grant.yaml"
  content  = local.reference_grant_yaml
}

resource "null_resource" "apply_reference_grant" {
  count = var.ingress_type == "envoy" && var.tls_certificate_source == "letsencrypt" ? 1 : 0

  triggers = {
    reference_grant_content = local_file.reference_grant[0].content
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for ReferenceGrant CRD to be available
      for i in {1..30}; do
        if kubectl get crd referencegrants.gateway.networking.k8s.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for ReferenceGrant CRD... ($i/30)"
        sleep 2
      done
      
      # Apply the ReferenceGrant
      kubectl apply -f ${local_file.reference_grant[0].filename}
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
    command = <<-EOT
      # Wait for Envoy proxy service to have external IP
      # The Envoy proxy service is created by Envoy Gateway for each Gateway resource
      for i in {1..60}; do
        # Find the Envoy proxy service using label selector
        IP=$(kubectl get svc -n envoy-gateway-system \
          -l gateway.envoyproxy.io/owning-gateway-name=${var.gateway_name},app.kubernetes.io/component=proxy \
          -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$IP" ] && [ "$IP" != "null" ]; then
          echo "$IP" > ${path.module}/external-ip.txt
          exit 0
        fi
        echo "Waiting for external IP... ($i/60)"
        sleep 5
      done
      echo "WARNING: External IP not available yet" > ${path.module}/external-ip.txt
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
# HTTPRoute - Managed by Helm
#------------------------------------------------------------------------------
# HTTPRoute is created by the LangSmith Helm chart when gateway.enabled=true
# Terraform only manages the Gateway resource (infrastructure-level)
