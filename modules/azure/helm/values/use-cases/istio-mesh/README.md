# Use Case: Istio Mesh (Azure Service Mesh / ASM addon)

Manifests for configuring the Azure Service Mesh (ASM) addon as the ingress controller for LangSmith.

ASM is required for multi-dataplane deployments — it enables VirtualServices to route traffic across namespaces, which standard Ingress cannot do.

---

## Files

| File | Purpose |
|---|---|
| `istio-gateway.yaml` | Gateway CR — configures the ASM external ingress gateway to accept traffic for LangSmith |

---

## How ASM differs from standalone Istio

| | Standalone Istio | ASM addon |
|---|---|---|
| Install | Helm charts (`istio/gateway`) | `az aks mesh enable` |
| Namespace | `istio-system` | `aks-istio-ingress` (gateway), `aks-istio-system` (istiod) |
| Gateway selector | `istio: ingressgateway` | `istio: aks-istio-ingressgateway-external` |
| Upgrades | Manual | `az aks mesh upgrade` |

---

## Usage

Apply the Gateway once before the first Helm deploy (Pass 2d):

```bash
kubectl apply -f use-cases/istio-mesh/istio-gateway.yaml
```

Safe to re-apply — `kubectl apply` is idempotent.

---

## TLS

With **Azure Front Door**: TLS terminates at the FD edge. Traffic arrives at the Istio gateway over HTTP (port 80). The port 443 block in the Gateway is commented out.

Without Front Door (e.g. cert-manager + Istio TLS termination): uncomment the port 443 server block and set `credentialName` to your cert-manager `Certificate` secret name.

---

## Related

- `values-overrides-pass-2.yaml.example` — sets `istioGateway.namespace: aks-istio-ingress`
- `use-cases/multi-dataplane-listener-and-operator/` — per-namespace listener/operator pattern using the same gateway
- `TROUBLESHOOTING.md` — Front Door 404 / Istio host header mismatch
