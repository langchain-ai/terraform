# LangSmith on OCP — Architecture

## POC: Single Node OpenShift on Azure Baremetal Host

```
Your Laptop
    │
    │  SSH (22) · API (6443) · HTTPS (443) · HTTP (80)
    ▼
┌─────────────────────────────────────────────────────┐
│  Azure VM  (Standard_D16s_v5 · 16 vCPU / 64 GB)   │
│  "Simulated Baremetal Host"                         │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  KVM Guest: sno-master                       │  │
│  │  12 vCPU / 48 GB RAM / 400 GB disk           │  │
│  │  IP: 192.168.126.10 (virbr1 NAT bridge)      │  │
│  │                                              │  │
│  │  Single Node OpenShift 4.14                  │  │
│  │  ├── Pass 1 — In-cluster backing services    │  │
│  │  │   ├── Crunchy PGO   → PostgreSQL          │  │
│  │  │   ├── Redis          → in-cluster Redis   │  │
│  │  │   ├── MinIO          → S3-compat storage  │  │
│  │  │   └── cert-manager   → TLS (Let's Encrypt)│  │
│  │  ├── Pass 2 — LangSmith Base Platform        │  │
│  │  │   └── Helm chart (langsmith namespace)    │  │
│  │  └── Pass 3 — LangSmith Deployments          │  │
│  │      └── LangGraph Platform (optional)       │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  firewalld port-forward:                           │
│    :6443 → 192.168.126.10:6443  (API)             │
│    :443  → 192.168.126.10:443   (HTTPS / console) │
│    :80   → 192.168.126.10:80    (HTTP / ACME)     │
└─────────────────────────────────────────────────────┘
```

---

## DNS: nip.io (zero-config)

The cluster uses [nip.io](https://nip.io) — the public IP is embedded in the domain name, no DNS setup required.

```
Public IP: 1.2.3.4
Base domain: 1-2-3-4.nip.io

API server:  https://api.sno-langsmith.1-2-3-4.nip.io:6443
OCP console: https://console-openshift-console.apps.sno-langsmith.1-2-3-4.nip.io
LangSmith:   https://langsmith.apps.sno-langsmith.1-2-3-4.nip.io
```

---

## Module Layout

```
ocp/infra/
├── azure-host/          Terraform — provisions the Azure "baremetal" host VM
│   ├── main.tf          Resource group, VNet, NSG, NIC, VM, data disk
│   ├── variables.tf
│   ├── outputs.tf       Exposes public IP, SSH command, nip.io URLs
│   └── templates/
│       └── cloud-init.yaml   Formats data disk; all else done manually
│
├── scripts/             Manual step-by-step install scripts (run after SSH)
│   ├── 00-check-prereqs.sh   Verify host readiness
│   ├── 01-setup-kvm.sh       Install KVM, create bridge, configure firewalld
│   ├── 02-install-ocp-tools.sh  Download oc, openshift-install, helm
│   ├── 03-generate-sno-iso.sh   Build agent ISO from install/agent configs
│   ├── 04-deploy-sno.sh      Create KVM guest, boot ISO, wait for install
│   ├── 05-post-install.sh    Verify cluster, print kubeconfig + URLs
│   └── README.md
│
└── langsmith/           (coming soon) Terraform for LangSmith on OCP
```

---

## Key Differences from AKS / GKE / EKS

| Concern          | AKS / GKE / EKS              | OCP                                     |
|------------------|------------------------------|-----------------------------------------|
| Ingress          | NGINX / Envoy / ALB          | OpenShift Route or Gateway API          |
| Security context | Standard pod security        | SCC (Security Context Constraints)      |
| Storage          | Cloud-native CSI             | ODF / Rook-Ceph or in-cluster MinIO     |
| Identity         | Workload Identity / IRSA     | OpenShift service account tokens        |
| Operators        | Helm-only                    | OLM (Operator Lifecycle Manager)        |
| DNS              | Cloud DNS / external-dns     | nip.io (POC) / custom domain (prod)     |

---

## VM Sizing

| VM Size           | vCPU | RAM    | Use case                           |
|-------------------|------|--------|------------------------------------|
| Standard_D16s_v5  | 16   | 64 GB  | Minimum — SNO + LangSmith (tight)  |
| Standard_D32s_v5  | 32   | 128 GB | Recommended — comfortable headroom |

Data disk: 600 GB Premium LRS (KVM storage pool + ODF).
