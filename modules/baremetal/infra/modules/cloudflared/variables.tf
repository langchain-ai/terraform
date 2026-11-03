#------------------------------------------------------------------------------
# Inputs for the Cloudflare Tunnel connector.
# Covers the tunnel token (sensitive), image, replicas and resources.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "namespace" {
  type        = string
  default     = "cloudflared"
  description = "Namespace created for the connector."
}

variable "image" {
  type        = string
  description = "cloudflared image, exact tag."
}

variable "tunnel_token" {
  type        = string
  sensitive   = true
  description = "Token of a remotely-managed tunnel (Zero Trust → Networks → Tunnels)."
}

variable "replicas" {
  type        = number
  default     = 2
  description = "Connector replicas, one per worker (required anti-affinity)."
}

variable "resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ memory = string })
  })
  description = "Container requests and limits (from the root budget). No CPU limit: the connector is I/O bound and throttling it adds latency to every request."
}
