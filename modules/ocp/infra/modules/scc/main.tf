# OCP SCC module
# Configures a SecurityContextConstraints policy and RBAC binding for LangSmith on OpenShift.

resource "kubernetes_manifest" "langsmith_scc" {
  manifest = {
    apiVersion = "security.openshift.io/v1"
    kind       = "SecurityContextConstraints"
    metadata = {
      name = "langsmith-scc"
    }
    allowPrivilegedContainer = false
    allowPrivilegeEscalation = false
    runAsUser = {
      type = "MustRunAsNonRoot"
    }
    seLinuxContext = {
      type = "MustRunAs"
    }
    fsGroup = {
      type = "RunAsAny"
    }
    supplementalGroups = {
      type = "RunAsAny"
    }
    volumes = [
      "configMap",
      "emptyDir",
      "projected",
      "secret",
      "persistentVolumeClaim",
    ]
    users  = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    groups = []
  }
}

resource "kubernetes_cluster_role" "langsmith_scc" {
  metadata {
    name = "langsmith-scc-use"
  }
  rule {
    api_groups     = ["security.openshift.io"]
    resources      = ["securitycontextconstraints"]
    resource_names = ["langsmith-scc"]
    verbs          = ["use"]
  }
}

resource "kubernetes_cluster_role_binding" "langsmith_scc" {
  metadata {
    name = "langsmith-scc-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.langsmith_scc.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = var.service_account_name
    namespace = var.namespace
  }
}
