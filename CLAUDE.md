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
| Agent GCP SA | `aegis-agent-sa@gyao-bde-demo.iam.gserviceaccount.com` |
| GCS bucket | `aegis-financial-data` |
| Mistral KServe DNS | `mistral-7b-predictor.aegis-mesh.svc.cluster.local` |
| phi-3-mini KServe DNS | `phi-3-mini-predictor.aegis-mesh.svc.cluster.local` |
| Agent service | `agent-svc.aegis-mesh.svc.cluster.local:8080` |
| Supervisor service | `supervisor-svc.aegis-mesh.svc.cluster.local:8081` |

## Placeholders to Replace Before Deploying

| File | Placeholder | Replace With |
|---|---|---|
| `gitops/security/fortiaigate/chart/override-values.yaml` | Node names in `global.licenses` | GKE worker node names (`kubectl get nodes`) — **changes on every full cluster recreate** |

> **Note**: `storageClass` (`nfs-rwx`) and `image.tag` (`V8.0.0-build0023`) are already set in `chart/override-values.yaml`. The only value that must be updated on each bringup is the license node name mapping — GKE randomizes the node hash suffix when the cluster is destroyed and recreated.

## Deployment Order

Steps must be executed in this order due to hard dependencies.
**Use `bringup.sh` to automate steps 1–10** (`HF_TOKEN=hf_xxx ./scripts/bringup.sh`).

```
0.  gcloud storage buckets create gs://aegis-tfstate-gyao-bde-demo \
      --project=gyao-bde-demo --location=us-central1   # One-time: TF state bucket
1.  terraform apply                          # VPC, GKE, IAM, fleet mesh feature
    # After apply: kubectl get nodes → update license node names in
    #   gitops/security/fortiaigate/chart/override-values.yaml, commit & push
2.  kubectl apply -k gitops/system/argocd/ --server-side --force-conflicts
    # Bootstrap ArgoCD; CRD annotations exceed 262KB — server-side apply required
3.  Install KServe directly from GitHub release manifests (NOT via ArgoCD OCI Helm):
      kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.13.0/kserve.yaml
      # Patch kube-rbac-proxy: gcr.io/kubebuilder deprecated → quay.io/brancz
      kubectl patch deployment kserve-controller-manager -n kserve --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/1/image","value":"quay.io/brancz/kube-rbac-proxy:v0.13.1"}]'
      kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.13.0/kserve-cluster-resources.yaml
    # ArgoCD kserve application.yaml is visibility-only (syncPolicy: {})
4.  kubectl apply -f gitops/ai-workloads/namespace.yaml   # Ambient mode enrollment
5.  kubectl create secret generic hf-secret \
      --from-literal=HF_TOKEN=<token> -n aegis-mesh
6.  ArgoCD auto-syncs ai-workloads app → InferenceServices  # Model download: 10-20 min
7.  Install Gateway API CRDs (required for waypoint proxy):
      kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
    kubectl apply -f gitops/security/cilium-policy-agent.yaml \
              -f gitops/security/cilium-policy-supervisor.yaml \
              -f gitops/security/waypoint-proxy.yaml
8.  docker build --platform linux/amd64 & push agent + supervisor images
    # --platform linux/amd64 required when building on Apple Silicon (M-series)
9.  kubectl apply -f src/agent/k8s/
    kubectl apply -f src/supervisor/k8s/
10. Install NFS provisioner (creates nfs-rwx StorageClass — required by FortiAIGate):
      helm upgrade --install nfs-server nfs-ganesha/nfs-server-provisioner \
        --namespace nfs-provisioner --create-namespace \
        --set storageClass.name=nfs-rwx \
        --set persistence.enabled=true --set persistence.storageClass=standard-rwo \
        --set persistence.size=50Gi
    kubectl apply -f gitops/security/fortiaigate/application.yaml
    # Wait for all pods in fortiaigate namespace (~5 min), then onboard via WebUI
```

## Running Terraform

The Terraform state is stored in GCS. The bucket must exist **before** `terraform init` — create it once manually:

```bash
gcloud storage buckets create gs://aegis-tfstate-gyao-bde-demo \
  --project=gyao-bde-demo \
  --location=us-central1 \
  --uniform-bucket-level-access
```

Then run Terraform:

```bash
cd terraform
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Building and Pushing Images

```bash
# --platform linux/amd64 is required when building on Apple Silicon (M-series Mac).
# GKE nodes are x86-64; without this flag the pod fails with "exec format error".

# Agent
docker build --platform linux/amd64 src/agent/ \
  -t us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo/aegis-agent:latest
docker push us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo/aegis-agent:latest

# Supervisor
docker build --platform linux/amd64 src/supervisor/ \
  -t us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo/aegis-supervisor:latest
docker push us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo/aegis-supervisor:latest
```

## FortiAIGate Deployment & Configuration

FortiAIGate 8.0.0 is **not** a single container image and has **no public Helm chart repository**. It is distributed as offline TAR archives and a local Helm chart by Fortinet. It deploys ~10 components: API server, WebUI, Core engine, nine AI scanner microservices, NVIDIA Triton Inference Server, PostgreSQL, Redis, License Manager, and LogD — all into its own dedicated namespace (`fortiaigate`), not `aegis-mesh`.

### 1. Prerequisites

Before installing FortiAIGate:
- Kubernetes ≥ 1.25, Helm ≥ 3.10
- An **Ingress Controller** must be installed cluster-wide (`kubectl get ingressclass` to verify)
- An **RWX StorageClass** must be available (PostgreSQL and Redis require `ReadWriteMany` PVCs)
- NVIDIA GPU operator installed and L4 nodes labeled/tainted (already configured by Terraform)
- FortiAIGate `.lic` license files obtained from FortiCare — **one file per GKE worker node**

### 2. Download Helm Chart and Images

Download the Helm chart TAR and image archives from Fortinet Infosite:
```
https://info.fortinet.com/builds/?project_id=807
```

Extract the Helm chart, copy licenses, and commit to Git so ArgoCD can sync it:
```bash
tar xf fortiaigate-chart-V8.0.0-*.tar
# Note: the extracted directory name may vary (e.g. fortiaigate/ or fortiaigate-8.0.0/)
cp -r fortiaigate/ gitops/security/fortiaigate/chart/

# IMPORTANT: Do NOT overwrite chart/values.yaml — it contains the upstream chart defaults.
# Our customisations live in chart/override-values.yaml (already committed).
# The ArgoCD Application references override-values.yaml via helm.valueFiles.

# Copy license files into the chart so ArgoCD can deploy them
mkdir -p gitops/security/fortiaigate/chart/files/licenses/
cp gitops/security/fortiaigate/files/licenses/*.lic \
   gitops/security/fortiaigate/chart/files/licenses/

# Update node names in chart/override-values.yaml BEFORE committing:
#   kubectl get nodes  →  replace global.licenses node names
git add gitops/security/fortiaigate/chart/
git commit -m "Add FortiAIGate 8.0.0 Helm chart"
git push
```

### 3. Image Preparation

Load, tag, and push all image archives to your private registry before deploying:

```bash
# Load all archives
for archive in FAIG_*.tar; do
  sudo docker load -i "$archive"
done

# After loading, list images to confirm tags:
docker images | grep fortiaigate

# Tag and push each image (repeat for all components):
# api, core, webui, scanners, license_manager, logd, triton-server
docker tag <source_image> us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo/<name>:<tag>
docker push us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo/<name>:<tag>
```

> **triton-models and custom-triton**: keep their original image tags when pushing. The Helm chart references them by exact tag.

After loading, note the build tag (e.g. `V8.0.0-build0023`) and set `fortiaigate.image.tag` in `chart/override-values.yaml`.

### 4. Licensing

Current licenses (already committed):
- `FAIGCNSD26000104.lic` and `FAIGCNSD26000135.lic` in `gitops/security/fortiaigate/chart/files/licenses/`

**After every full cluster recreate**, run `kubectl get nodes` and update the license node name mapping in `gitops/security/fortiaigate/chart/override-values.yaml` (GKE randomizes the hash suffix on each cluster creation):

```yaml
global:
  licenses:
    "gke-aegis-cluster-system-pool-<new-hash>-<id1>": "files/licenses/FAIGCNSD26000104.lic"
    "gke-aegis-cluster-system-pool-<new-hash>-<id2>": "files/licenses/FAIGCNSD26000135.lic"
```

### 5. Helm `chart/override-values.yaml` (`gitops/security/fortiaigate/chart/override-values.yaml`)

Key values already set (see the file for full contents):

```yaml
fortiaigate:
  image:
    repository: us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo
    tag: V8.0.0-build0023
  gpu:
    enabled: false            # GPU nodes fully used by KServe models

storage:
  storageClass: nfs-rwx       # Provisioned by nfs-ganesha-server-and-external-provisioner
  size: 8Gi

ingress:
  className: nginx
  host: ""                    # Access via Ingress controller external IP

tls:
  enabled: true
  cert: files/certificate/dflt.crt
  key: files/certificate/dflt.key
```

CPU requests are intentionally reduced from production defaults (1 CPU → 100m per scanner) to fit on `e2-standard-4` demo nodes. Do not revert these without also scaling the system pool.

### 6. Deployment via ArgoCD

Once the chart is committed to Git with updated node names, apply the ArgoCD Application:

```bash
kubectl apply -f gitops/security/fortiaigate/application.yaml
# Then monitor: kubectl get pods -n fortiaigate -w
```

### 7. Post-Deploy Onboarding (Admin UI)

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

### 8. Traffic Flow with FortiAIGate

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

## GPU & Spot VM Note

- **GPU Resources**: Mistral-7B (~14 GB VRAM) and TinyLlama-1.1B (~2 GB VRAM) together consume ~16 GB. The NVIDIA L4 has 24 GB VRAM. The `gpu-pool` is configured with `node_count = 2` so each model runs on a dedicated node. Do not reduce to 1 GPU node or models will compete for VRAM. The supervisor's InferenceService is named `phi-3-mini` (DNS: `phi-3-mini-predictor.aegis-mesh.svc.cluster.local`) but actually runs TinyLlama-1.1B-Chat.
- **System pool**: `node_count = 3` (`e2-standard-4`). 2 nodes is insufficient — CPU saturates with FortiAIGate scanners running alongside ArgoCD/cert-manager/KServe controller.
- **Spot VMs**: All node pools (`system` and `gpu`) use **GCP Spot VMs** to minimize infrastructure costs (up to 60-91% savings). Be aware that nodes can be preempted by GCP at any time with a 30-second notice, which may cause temporary service interruptions. For production stability, consider switching to standard VMs in `terraform/modules/gke/main.tf`.
- **GPU Spot preemption risk**: `g2-standard-4` Spot VMs with NVIDIA L4 GPUs face **higher preemption rates** than CPU Spot VMs due to elevated GPU demand. If a GPU node is preempted, KServe must reschedule and reload the model from HuggingFace — Mistral-7B (~14 GB) can take 10–20 minutes to recover. During this window the agent will be unavailable. For demos, verify both InferenceServices are `Ready` before presenting.
