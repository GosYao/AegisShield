#!/usr/bin/env bash
# bringup.sh — Restore AegisShield after a cost-saving teardown.
#
# Assumes VPC/networking is still in place (module.network).
# Recreates: GKE cluster + node pools, IAM SAs, GCS bucket, Workload Identity,
#            GKE Hub mesh feature + membership, all k8s workloads.
#
# Run from repo root: HF_TOKEN=hf_xxx ./scripts/bringup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${GREEN}[bringup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[bringup]${NC} $*"; }
die()     { echo -e "${RED}[bringup] ERROR:${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; \
            echo -e "${CYAN} $*${NC}"; \
            echo -e "${CYAN}════════════════════════════════════════${NC}"; }

# ── Preflight ────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null    || die "kubectl not found"
command -v terraform &>/dev/null  || die "terraform not found"
command -v gcloud &>/dev/null     || die "gcloud not found"
command -v docker &>/dev/null     || die "docker not found"

if [[ -z "${HF_TOKEN:-}" ]]; then
  echo -n "HuggingFace token (HF_TOKEN): "
  read -rs HF_TOKEN
  echo ""
  [[ -n "$HF_TOKEN" ]] || die "HF_TOKEN is required to download models."
fi

REGISTRY="us-central1-docker.pkg.dev/gyao-bde-demo/aegis-repo"

# ── Step 1: Recreate GKE cluster (networking + IAM already exist) ────────────
section "Step 1 — Terraform: GKE cluster + IAM + mesh hub (full apply)"
cd "${REPO_ROOT}/terraform"
# Full apply — network already exists in state and will be a no-op.
# IAM, GCS bucket, and mesh hub are recreated alongside GKE.
terraform apply -var-file=terraform.tfvars -auto-approve
cd "${REPO_ROOT}"

log "Fetching GKE credentials..."
gcloud container clusters get-credentials aegis-cluster \
  --zone us-central1-a --project gyao-bde-demo

# ── Step 2: ArgoCD bootstrap ─────────────────────────────────────────────────
section "Step 2 — Bootstrap ArgoCD"
kubectl apply -k "${REPO_ROOT}/gitops/system/argocd/" --server-side --force-conflicts

log "Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s

log "Applying app-of-apps..."
kubectl apply -f "${REPO_ROOT}/gitops/system/argocd/app-of-apps.yaml"

# ── Step 3: Install KServe ───────────────────────────────────────────────────
section "Step 3 — Install KServe (direct manifests)"
# ArgoCD OCI Helm support for ghcr.io is unreliable on GKE (403 on token fetch).
# Install directly from the KServe GitHub release manifests instead.
KSERVE_VERSION="v0.13.0"

log "Waiting for cert-manager (required for KServe webhook certs)..."
kubectl rollout status deployment/cert-manager         -n cert-manager --timeout=300s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s

log "Applying KServe manifests..."
kubectl apply --server-side \
  -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"

# gcr.io/kubebuilder/kube-rbac-proxy was deprecated; current location is quay.io/brancz.
log "Patching kube-rbac-proxy image..."
kubectl patch deployment kserve-controller-manager -n kserve \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/1/image","value":"quay.io/brancz/kube-rbac-proxy:v0.13.1"}]'

log "Waiting for kserve-controller-manager to be ready..."
kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=180s

log "Applying KServe cluster resources (ClusterServingRuntimes)..."
kubectl apply --server-side \
  -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml"

log "KServe ready."

# ── Step 4: Namespace + ambient mode enrollment ───────────────────────────────
section "Step 4 — Namespace + ambient mesh enrollment"
kubectl apply -f "${REPO_ROOT}/gitops/ai-workloads/namespace.yaml"

# ── Step 5: HuggingFace secret + InferenceServices ───────────────────────────
section "Step 5 — HuggingFace secret + model InferenceServices"
kubectl create secret generic hf-secret \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  -n aegis-mesh \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying InferenceServices (model download begins — 15–20 min)..."
kubectl apply -f "${REPO_ROOT}/gitops/ai-workloads/mistral-inferenceservice.yaml"
kubectl apply -f "${REPO_ROOT}/gitops/ai-workloads/classifier-inferenceservice.yaml"

log "Waiting for Mistral-7B to become Ready..."
until kubectl get inferenceservice mistral-7b -n aegis-mesh \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -q "True"; do
  warn "  Mistral-7B not ready, retrying in 60s..."
  sleep 60
done
log "Mistral-7B ready."

log "Waiting for classifier (Qwen2.5-7B-Instruct) to become Ready..."
until kubectl get inferenceservice classifier -n aegis-mesh \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -q "True"; do
  warn "  classifier not ready, retrying in 60s..."
  sleep 60
done
log "classifier ready."

# ── Step 6: Security policies ────────────────────────────────────────────────
section "Step 6 — Cilium policies + waypoint proxy"
kubectl apply -f "${REPO_ROOT}/gitops/security/cilium-policy-agent.yaml"
kubectl apply -f "${REPO_ROOT}/gitops/security/cilium-policy-supervisor.yaml"

# Gateway API CRDs are required for the waypoint Gateway resource.
log "Installing Kubernetes Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

kubectl apply -f "${REPO_ROOT}/gitops/security/waypoint-proxy.yaml"

# ── Step 7: Build + push images ──────────────────────────────────────────────
section "Step 7 — Build + push Agent and Supervisor images"
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

log "Building agent..."
docker build "${REPO_ROOT}/src/agent/" --platform linux/amd64 -t "${REGISTRY}/aegis-agent:latest"
docker push "${REGISTRY}/aegis-agent:latest"

log "Building supervisor..."
docker build "${REPO_ROOT}/src/supervisor/" --platform linux/amd64 -t "${REGISTRY}/aegis-supervisor:latest"
docker push "${REGISTRY}/aegis-supervisor:latest"

# ── Step 8: Deploy agent + supervisor ────────────────────────────────────────
section "Step 8 — Deploy Agent + Supervisor"
kubectl apply -f "${REPO_ROOT}/src/agent/k8s/"
kubectl apply -f "${REPO_ROOT}/src/supervisor/k8s/"

kubectl rollout status deployment/aegis-agent     -n aegis-mesh --timeout=120s
kubectl rollout status deployment/aegis-supervisor -n aegis-mesh --timeout=120s

# ── Step 9: NFS provisioner + FortiAIGate ────────────────────────────────────
section "Step 9 — NFS provisioner + FortiAIGate"
# GKE has no built-in RWX StorageClass; FortiAIGate needs one for its shared PVC.
log "Installing NFS provisioner (creates nfs-rwx StorageClass)..."
helm repo add nfs-ganesha \
  https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ 2>/dev/null || true
helm upgrade --install nfs-server nfs-ganesha/nfs-server-provisioner \
  --namespace nfs-provisioner --create-namespace \
  --set storageClass.name=nfs-rwx \
  --set persistence.enabled=true \
  --set persistence.storageClass=standard-rwo \
  --set persistence.size=50Gi

log "Waiting for NFS provisioner to be ready..."
kubectl rollout status statefulset/nfs-server-nfs-server-provisioner \
  -n nfs-provisioner --timeout=120s

if [[ ! -d "${REPO_ROOT}/gitops/security/fortiaigate/chart" ]]; then
  warn "FortiAIGate chart not found at gitops/security/fortiaigate/chart/ — skipping."
  warn "Download from https://info.fortinet.com/builds/?project_id=807, extract, and commit."
else
  kubectl apply -f "${REPO_ROOT}/gitops/security/fortiaigate/application.yaml"

  log "Waiting for FortiAIGate pods to be Running (~5 min)..."
  until [[ "$(kubectl get pods -n fortiaigate --field-selector=status.phase!=Running \
               --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
        && [[ "$(kubectl get pods -n fortiaigate --no-headers 2>/dev/null | wc -l | tr -d ' ')" -gt "0" ]]; do
    warn "  FortiAIGate pods not all Running yet, retrying in 30s..."
    sleep 30
  done
  log "FortiAIGate pods Running."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
section "Bringup complete"
echo ""
echo -e "${GREEN}All automated steps finished.${NC}"
echo ""
echo "Manual step remaining — FortiAIGate WebUI onboarding:"
FORTIGATE_IP=$(kubectl get svc -n fortiaigate \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
  2>/dev/null || echo "<check: kubectl get svc -n fortiaigate>")
echo "  WebUI: https://${FORTIGATE_IP}"
echo ""
echo "  A) Settings → AI Providers → Add:"
echo "       Type: OpenAI-compatible"
echo "       API Base URL: http://agent-svc.aegis-mesh.svc.cluster.local:8080"
echo ""
echo "  B) AI Guard → New Guard → attach provider:"
echo "       Input:  Prompt Injection + DLP + Toxicity  (action: Block)"
echo "       Output: DLP + Toxicity                     (action: Block)"
echo ""
echo "  C) AI Flow → New Flow:"
echo "       Path: /v1/chat/completions"
echo "       Route to Guard from step B → Deploy"
echo ""
echo "Verify: kubectl get isvc -n aegis-mesh && kubectl get pods -n aegis-mesh"
