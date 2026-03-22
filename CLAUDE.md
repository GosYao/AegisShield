# CLAUDE.md

This file provides guidance to Claude Code when working with the AegisShield repository.

## Overview

AegisShield is a zero-trust, Agentic AI security sandbox on GKE. It demonstrates a multi-layered control plane protecting an autonomous LangChain agent from prompt injection and data exfiltration using three stacked defenses:

1. **L4 (Cilium)** — network policy restricts the agent's egress to KServe DNS and Google APIs only
2. **L7 (FortiAIGate)** — WAF/DLP strips PII and prompt injection patterns before the agent sees user input
3. **Control Plane (Supervisor)** — the agent pre-clears every tool call with the Supervisor, which queries phi-3-mini to classify intent; MALICIOUS intent triggers immediate pod termination

---

## Architecture: Request Flow

```
User
 └─► FortiAIGate (Ingress)            [L7 DLP/WAF — strips PII + injection patterns]
      └─► Agent pod /chat             [LangChain + Mistral-7B via KServe]
           └─► Supervisor /evaluate   [phi-3-mini classifies intent]
                ├─► BENIGN  → Agent executes tool (GCS read via Workload Identity)
                └─► MALICIOUS → Supervisor deletes agent pod (kubectl via RBAC)
```

---

## Directory Structure

```
AegisShield/
├── terraform/              GCP foundation (VPC, GKE, IAM, Workload Identity)
│   └── modules/
│       ├── network/        VPC, subnet, Cloud Router + NAT
│       ├── gke/            GKE cluster + node pools
│       └── iam/            GCP SAs, GCS bucket, Workload Identity bindings
├── gitops/
│   ├── system/             ArgoCD app-of-apps, cert-manager, KServe, ai-workloads app
│   ├── ai-workloads/       Namespace (ambient mode), InferenceServices
│   └── security/           Cilium policies, FortiAIGate, waypoint proxy
├── src/
│   ├── agent/              Python LangChain pod — the attack target
│   └── supervisor/         Python FastAPI pod — the control plane
```

## Key Configuration Values

| Parameter | Value |
|---|---|
| GCP Region / Zone | `us-central1` / `us-central1-a` |
| GKE cluster | `aegis-cluster` |
| Datapath | `ADVANCED_DATAPATH` (Cilium) |
| Mesh namespace | `aegis-mesh` |
| GPU machine | `g2-standard-4` (NVIDIA L4) |
| Agent KSA | `agent-ksa` |
| Agent GCP SA | `aegis-agent-sa@PROJECT.iam.gserviceaccount.com` |
| GCS bucket | `aegis-financial-data` |
| Mistral KServe DNS | `mistral-7b-predictor.aegis-mesh.svc.cluster.local` |
| phi-3-mini KServe DNS | `phi-3-mini-predictor.aegis-mesh.svc.cluster.local` |
| Agent service | `agent-svc.aegis-mesh.svc.cluster.local:8080` |
| Supervisor service | `supervisor-svc.aegis-mesh.svc.cluster.local:8081` |

## Placeholders to Replace Before Deploying

| File | Placeholder | Replace With |
|---|---|---|
| `gitops/system/argocd/app-of-apps.yaml` | `YOUR_ORG/AegisShield` | Git repo path |
| `gitops/system/ai-workloads/application.yaml` | `YOUR_ORG/AegisShield` | Git repo path |
| `gitops/security/fortiaigate/application.yaml` | `YOUR_FORTINET_HELM_REPO` | Helm chart repo URL from Fortinet support |
| `gitops/security/fortiaigate/values.yaml` | `YOUR_DOMAIN` | Domain for FortiAIGate Ingress TLS |
| `gitops/security/fortiaigate/values.yaml` | `YOUR_RWX_STORAGECLASS` | RWX StorageClass name for PostgreSQL + Redis |
| `gitops/security/fortiaigate/values.yaml` | `REPLACE_NODE1/2` | GKE worker node names (`kubectl get nodes`) |
| `gitops/security/fortiaigate/values.yaml` | `KEEP_ORIGINAL_FORTINET_TAG` | Original image tags for Triton components |

## Deployment Order

Steps must be executed in this order due to hard dependencies:

```
1.  terraform apply                          # VPC, GKE, IAM, fleet mesh feature
2.  kubectl apply -k gitops/system/argocd/   # Bootstrap ArgoCD manually
3.  ArgoCD auto-syncs cert-manager → KServe  # Wait for kserve-controller Ready
4.  kubectl apply -f gitops/ai-workloads/namespace.yaml   # Ambient mode enrollment
5.  kubectl create secret generic hf-secret \
      --from-literal=HF_TOKEN=<token> -n aegis-mesh
6.  ArgoCD auto-syncs ai-workloads app → InferenceServices  # Model download: 10-20 min
7.  kubectl apply -f gitops/security/cilium-policy-agent.yaml \
              -f gitops/security/cilium-policy-supervisor.yaml \
              -f gitops/security/waypoint-proxy.yaml
8.  docker build & push agent + supervisor images
9.  kubectl apply -f src/agent/k8s/
    kubectl apply -f src/supervisor/k8s/
10. kubectl apply -f gitops/security/fortiaigate/application.yaml
    # Wait for all pods in fortiaigate namespace (~5 min), then onboard via WebUI
```

## Running Terraform

```bash
cd terraform
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Building and Pushing Images

```bash
# Agent
docker build src/agent/ -t YOUR_REGISTRY/aegis-agent:latest
docker push YOUR_REGISTRY/aegis-agent:latest

# Supervisor
docker build src/supervisor/ -t YOUR_REGISTRY/aegis-supervisor:latest
docker push YOUR_REGISTRY/aegis-supervisor:latest
```

## FortiAIGate Deployment & Configuration

FortiAIGate 8.0.0 is **not** a single container image. It is a full Helm chart that deploys ~10 components: API server, WebUI, Core engine, nine AI scanner microservices, NVIDIA Triton Inference Server (with model and custom-triton init containers), PostgreSQL, Redis, License Manager, and LogD. It deploys to its own dedicated namespace (`fortiaigate`), not `aegis-mesh`.

### 1. Prerequisites

Before installing FortiAIGate:
- Kubernetes ≥ 1.25, Helm ≥ 3.10
- An **Ingress Controller** must be installed cluster-wide (nginx-ingress or GKE native)
- An **RWX StorageClass** must be available (PostgreSQL and Redis require `ReadWriteMany` PVCs — ~8 Gi and ~4 Gi respectively)
- NVIDIA GPU operator installed and L4 nodes labeled/tainted (already configured by Terraform)
- FortiAIGate `.lic` license files obtained from FortiCare — **one file per GKE worker node** that will run FortiAIGate components

### 2. Image Preparation

FortiAIGate ships as offline TAR archives, not from Docker Hub. Each component has its own archive. Load, tag, and push all of them to your private registry before deploying:

```bash
# Full list of images that must be loaded and pushed:
# FAIG_api, FAIG_core, FAIG_webui
# FAIG_scanners (covers all nine AI scanner services)
# FAIG_license_manager, FAIG_logd
# FAIG_triton-server
# FAIG_triton-models   ← keep original tag, do not rename
# FAIG_custom-triton   ← keep original tag, do not rename

for archive in FAIG_*.tar; do
  docker load -i "$archive"
done

# Example for the API image (repeat for each image):
docker tag FAIG_api:V8.0.0-build0004 YOUR_REGISTRY/faig-api:v8.0.0
docker push YOUR_REGISTRY/faig-api:v8.0.0
# ... repeat for core, webui, scanners, license_manager, logd, triton-server, triton-models, custom-triton
```

> **triton-models and custom-triton**: keep their original image tags when pushing. The Helm chart references them by exact tag via init container specs.

### 3. Licensing

Place one `.lic` file (obtained from FortiCare) for each GKE worker node into:

```
gitops/security/fortiaigate/files/licenses/
```

Then map node names to license file names in `gitops/security/fortiaigate/values.yaml`:

```yaml
global:
  licenses:
    "gke-aegis-cluster-system-pool-xxxx": "node1.lic"
    "gke-aegis-cluster-system-pool-yyyy": "node2.lic"
    # Add one entry per worker node
```

Run `kubectl get nodes` after `terraform apply` to get the actual node names.

### 4. Helm values.yaml (`gitops/security/fortiaigate/values.yaml`)

Key values to set (see the file for the full template):

```yaml
global:
  imageRegistry: YOUR_REGISTRY
  imageTag: v8.0.0

fortiaigate:
  gpu:
    enabled: true          # Uses NVIDIA L4 for AI scanner acceleration

ingress:
  enabled: true
  className: nginx         # Or "gce" for GKE native ingress
  host: fortiaigate.YOUR_DOMAIN

postgresql:
  primary:
    persistence:
      storageClass: YOUR_RWX_STORAGECLASS
      size: 8Gi

redis:
  master:
    persistence:
      storageClass: YOUR_RWX_STORAGECLASS
      size: 4Gi
```

### 5. Deployment via ArgoCD

FortiAIGate is managed as an ArgoCD Application. See `gitops/security/fortiaigate/application.yaml`. ArgoCD will install the Helm chart into the `fortiaigate` namespace automatically.

```bash
kubectl apply -f gitops/security/fortiaigate/application.yaml
# Then monitor: kubectl get pods -n fortiaigate -w
```

### 6. Post-Deploy Onboarding (Admin UI)

After all pods are Running, log in to the FortiAIGate WebUI via the Ingress hostname and complete onboarding in this order:

#### Step A — Create an AI Provider
In **Settings → AI Providers**, add an AI Provider pointing at the Agent's service endpoint:
- **Type**: OpenAI-compatible
- **API Base URL**: `http://agent-svc.aegis-mesh.svc.cluster.local:8080`

#### Step B — Create an AI Guard
In **AI Guard**, create a new Guard and attach:
- **AI Provider**: the provider created above
- **Input Guard**: enable the scanners you want to apply to *incoming* user prompts:
  - Prompt Injection scanner (detects jailbreaks and injection attempts)
  - DLP scanner (blocks credit cards, SSNs, bank accounts via regex profiles)
  - Toxicity scanner (blocks harmful language)
  - Custom Rule scanner (add additional regex patterns as needed)
- **Output Guard**: enable scanners to apply to *LLM responses* before returning to user:
  - DLP scanner (prevents the model from echoing back PII it found in context)
  - Toxicity scanner
  - Custom Rule scanner

Set the action for each scanner match to **Block** (not just log) for production security posture.

#### Step C — Create an AI Flow
In **AI Flow**, define the traffic routing entry point:
- **Path**: `/chat` (matches the agent's `/chat` endpoint path)
- **Request Schema**: `{ "message": "string" }` (matches the agent's FastAPI request model)
- **Routing Strategy**: Static → target the AI Guard created in Step B
- **Deploy** the flow

Once deployed, all traffic arriving at the FortiAIGate ingress at `/chat` passes through the Input Guard before the request is forwarded to the Agent, and through the Output Guard before the response is returned to the user.

### 7. Traffic Flow with FortiAIGate

```
User → FortiAIGate Ingress (/chat)
         └─► AI Flow routes to AI Guard
               └─► Input Guard (Prompt Injection + DLP + Toxicity scanners)
                     ├─► BLOCKED: 403 returned to user, request never reaches Agent
                     └─► ALLOWED → Agent pod /chat (aegis-mesh)
                                     └─► [Agent + Supervisor control plane]
                                           └─► Response → Output Guard (DLP + Toxicity)
                                                 └─► Response returned to user
```

---

## Strict Rules

- **No sidecars**: All pods have `sidecar.istio.io/inject: "false"`. mTLS is provided by ztunnel (Ambient mode).
- **OpenAI SDK only**: All Python-to-LLM communication uses `openai.AsyncOpenAI` pointed at internal KServe `.svc.cluster.local` endpoints.
- **No raw GCP keys**: Pods authenticate to GCP via Workload Identity (metadata server). No service account JSON files anywhere.
- **Fail-closed supervisor**: If phi-3-mini is unreachable, the evaluator returns `MALICIOUS` and blocks the action.
- **Least-privilege RBAC**: The supervisor's `Role` is scoped to `aegis-mesh` namespace only (not a `ClusterRole`).

## GPU Note

Mistral-7B (~14 GB VRAM) and phi-3-mini (~8 GB VRAM) together consume ~22 GB. The NVIDIA L4 has 24 GB VRAM. The `gpu-pool` is configured with `node_count = 2` so each model runs on a dedicated node. Do not reduce to 1 GPU node or models will OOM-fail to load simultaneously.
