{{/*
Mebibytes in a memory limit written in Mi or Gi. Postgres and Redis size their own memory from it:
memory is not compressible, and a process past its limit is OOMKilled.
*/}}
{{- define "datastores.mebibytes" -}}
{{- $q := toString . -}}
{{- if hasSuffix "Mi" $q -}}
{{- trimSuffix "Mi" $q | float64 | floor | int -}}
{{- else if hasSuffix "Gi" $q -}}
{{- mulf (trimSuffix "Gi" $q | float64) 1024 | floor | int -}}
{{- else -}}
{{- fail (printf "memory limit %s: write it in Mi or Gi" $q) -}}
{{- end -}}
{{- end -}}

{{/* The namespace an instance lands in: the top-level namespace when set, else its own. dict: root, ns. */}}
{{- define "datastores.ns" -}}
{{- default .ns .root.Values.namespace -}}
{{- end -}}

{{/* Preferred anti-affinity on the shared datastore label: a node without another datastore first (noisy-neighbour disks). */}}
{{- define "datastores.antiAffinityTerms" -}}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      topologyKey: kubernetes.io/hostname
      labelSelector:
        matchLabels:
          {{- toYaml .Values.datastoreLabel | nindent 10 }}
      namespaceSelector: {}
{{- end -}}

{{/* NetworkPolicy peers that may reach a store: its own namespace, LangSmith's, and the CIDRs given. dict: root, ns, cidrs. */}}
{{- define "datastores.clients" -}}
{{- range (prepend .root.Values.allowedNamespaces .ns | uniq) }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ . }}
{{- end }}
{{- range .cidrs }}
- ipBlock:
    cidr: {{ . }}
{{- end }}
{{- end -}}

{{/*
A StatefulSet's claim template: the one already in the cluster when there is one. volumeClaimTemplates
are immutable, so a new size (another sizing profile, an enabled product) would fail every upgrade; the
size on local-path is a request it does not enforce, so it is set at creation only, as the module's
Terraform did with ignore_changes. A real resize means expanding the claim on a driver that can. Where
lookup sees no cluster (helm template, Argo CD), the values' size is used.
dict: root, ns, name, size.
*/}}
{{- define "datastores.claimSpec" -}}
{{- $sts := lookup "apps/v1" "StatefulSet" .ns .name -}}
{{- if and $sts $sts.spec.volumeClaimTemplates -}}
{{- toYaml (index $sts.spec.volumeClaimTemplates 0).spec -}}
{{- else -}}
accessModes: [ReadWriteOnce]
storageClassName: {{ .root.Values.storageClass }}
resources:
  requests:
    storage: {{ .size }}
{{- end -}}
{{- end -}}
