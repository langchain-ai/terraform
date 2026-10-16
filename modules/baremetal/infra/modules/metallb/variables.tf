#------------------------------------------------------------------------------
# Inputs for MetalLB in L2 mode.
# Covers chart version, the IP pool and controller/speaker sizing.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "chart_version" {
  type        = string
  description = "MetalLB Helm chart version (exact pin)."
}

variable "gateway_ip" {
  type        = string
  description = "The LangSmith gateway's IP, in its own pool with autoAssign off. Must not be in addresses."
}

variable "addresses" {
  type        = list(string)
  description = "LAN addresses MetalLB may hand to LoadBalancer Services: ranges (a.b.c.d-a.b.c.e) or CIDRs. Must be outside the router's DHCP pool."
}

variable "l2_node_selector" {
  type        = map(string)
  description = "Nodes that run a speaker and may answer ARP for LoadBalancer IPs (speaker nodeSelector and L2Advertisement nodeSelectors)."
}

variable "controller_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Controller requests and limits (from the root budget)."
}

variable "speaker_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Speaker (one per node) requests and limits (from the root budget)."
}
