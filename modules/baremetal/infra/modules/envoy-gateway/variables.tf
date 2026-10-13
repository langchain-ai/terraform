#------------------------------------------------------------------------------
# Inputs for Envoy Gateway and the LangSmith Gateway.
# Covers chart version, controller and proxy sizing, the LoadBalancer IP,
# Gateway names, route timeout and the optional LAN catch-all route.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "chart_version" {
  type        = string
  description = "Envoy Gateway Helm chart version (exact pin, e.g. v1.9.2)."
}

variable "controller_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Envoy Gateway controller requests and limits (from the root budget)."
}

variable "proxy_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Envoy proxy (data plane) requests and limits (from the root budget)."
}

variable "proxy_replicas" {
  type        = number
  default     = 1
  description = "Envoy proxy replicas."
}

variable "route_timeout" {
  type        = string
  default     = "60s"
  description = "Request timeout for every route on the Gateway (BackendTrafficPolicy). Envoy Gateway's default is 15 s, which returns 504 on slow trace reads. Empty string keeps the default."

  validation {
    condition     = var.route_timeout == "" || can(regex("^[0-9]+(ms|s|m|h)$", var.route_timeout))
    error_message = "route_timeout must be a duration like \"60s\" or \"2m\", or \"\" for the Envoy default."
  }
}

variable "load_balancer_ip" {
  type        = string
  description = "MetalLB IP pinned to the Envoy proxy Service (must be in the MetalLB pool)."
}

variable "gateway_namespace" {
  type        = string
  description = "Namespace of the Gateway; HTTPRoutes must live here (allowedRoutes: Same)."
}

variable "gateway_name" {
  type        = string
  default     = "langsmith-gateway"
  description = "Gateway name the LangSmith chart's gateway.name points at."
}

variable "gateway_class_name" {
  type        = string
  default     = "langsmith-eg"
  description = "GatewayClass name."
}

variable "envoy_proxy_name" {
  type        = string
  default     = "langsmith-proxy"
  description = "EnvoyProxy (proxy settings) name, in envoy-gateway-system."
}

variable "lan_route" {
  type = object({
    enabled         = bool
    backend_service = string
    backend_port    = number
  })
  default = {
    enabled         = false
    backend_service = "langsmith-frontend"
    backend_port    = 80
  }
  description = <<-EOT
    Catch-all HTTPRoute (no hostnames) to the LangSmith frontend. Needed once
    config.hostname is a domain: the chart's HTTPRoute then matches only that
    Host, and requests to the bare gateway IP would 404. The chart's more
    specific route still wins for the domain.
  EOT
}
