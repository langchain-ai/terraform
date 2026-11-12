# metrics-server scrapes CPU and memory usage from every kubelet (cAdvisor,
# port 10250) and serves it through the Metrics API (metrics.k8s.io). That API
# backs `kubectl top` and every HorizontalPodAutoscaler, including SmithDB's.

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_version
  namespace  = var.namespace

  # Wait for the Deployment to be ready so a failed install shows up here,
  # not later as a broken `kubectl top`.
  wait    = true
  timeout = 300

  values = [
    yamlencode({
      # Appended to the chart's defaultArgs (cert-dir, node-status port,
      # 15s resolution). Nodes register with their LAN IP, so prefer it.
      args = concat(
        ["--kubelet-preferred-address-types=InternalIP"],
        var.kubelet_insecure_tls ? ["--kubelet-insecure-tls"] : [],
      )
      resources = var.resources
    })
  ]
}
