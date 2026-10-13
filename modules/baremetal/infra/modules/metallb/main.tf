#------------------------------------------------------------------------------
# MetalLB in L2 mode: gives Services of type LoadBalancer a real LAN IP.
#
#   controller  watches LoadBalancer Services and picks an IP from the pool
#   speaker     DaemonSet on every worker; the elected speaker for a Service
#               answers ARP for its IP ("that IP is at my MAC"), so the LAN
#               sends the traffic to that node, where kube-proxy forwards it
#               to the pods. Speakers detect each other's failure over
#               memberlist on 7946/tcp+udp (open it in ufw between nodes).
#------------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = "metallb-system"
    labels = {
      # The speaker needs hostNetwork and NET_RAW to send ARP replies.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.this.metadata[0].name

  # Wait for the controller and its validating webhook, so the pool below
  # isn't rejected by a webhook that isn't serving yet.
  wait    = true
  timeout = 300

  values = [
    yamlencode({
      controller = { resources = var.controller_resources }
      speaker = {
        resources = var.speaker_resources
        # The speaker DaemonSet tolerates control-plane taints in the chart
        # template itself, so without a nodeSelector it lands there too. Only
        # nodes that may announce need a speaker.
        nodeSelector = var.l2_node_selector
      }
      # Chart 0.16 runs BGP through a bundled frr-k8s subchart, enabled by
      # default (the older speaker.frr key no longer controls it). L2 mode
      # needs no BGP, so turn it off: it's 5 pods with no resource requests.
      frrk8s = { enabled = false }
    })
  ]
}

# The pool and advertisement are MetalLB custom resources. They ship as a tiny
# local chart instead of kubernetes_manifest: kubernetes_manifest needs the
# CRDs to exist at plan time, which fails on the first apply (the CRDs come
# from the release above). Helm only needs them at install time.
resource "helm_release" "config" {
  name      = "metallb-config"
  chart     = "${path.module}/charts/metallb-config"
  namespace = kubernetes_namespace_v1.this.metadata[0].name

  values = [
    yamlencode({
      addresses      = var.addresses
      l2NodeSelector = var.l2_node_selector
    })
  ]

  depends_on = [helm_release.metallb]
}
