#!/usr/bin/env bash
# teardown.sh — Tear down AegisShield compute resources for cost saving.
#
# Destroys: GKE cluster + node pools, mesh hub membership
# Keeps:    VPC/networking, GCS bucket, IAM service accounts, Workload Identity bindings,
#           GKE Hub mesh feature (project-level, free — avoids slow re-propagation on bringup)
# NOTE: module.iam depends_on=[module.gke] has been removed from main.tf to prevent
#       IAM/GCS resources from being pulled into the destroy by Terraform's dep chain.
#
# Run from repo root: ./scripts/teardown.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

log()  { echo -e "${GREEN}[teardown]${NC} $*"; }
warn() { echo -e "${YELLOW}[teardown]${NC} $*"; }
die()  { echo -e "${RED}[teardown] ERROR:${NC} $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null    || die "kubectl not found"
command -v terraform &>/dev/null  || die "terraform not found"
command -v gcloud &>/dev/null     || die "gcloud not found"

log "Fetching GKE credentials..."
gcloud container clusters get-credentials aegis-cluster \
  --zone us-central1-a --project gyao-bde-demo 2>/dev/null \
  || warn "Could not fetch credentials — cluster may already be gone, skipping k8s steps."

CLUSTER_UP=false
kubectl cluster-info &>/dev/null 2>&1 && CLUSTER_UP=true

# ── Step 1: Delete k8s resources (prevents orphaned GCP LBs and PVCs) ───────
if $CLUSTER_UP; then
  log "Step 1/2 — Deleting Kubernetes resources (prevents orphaned LBs/PVCs)..."

  # FortiAIGate first — has PVCs and an ingress LB
  if kubectl get application fortiaigate -n argocd &>/dev/null 2>&1; then
    log "  Removing FortiAIGate ArgoCD Application..."
    kubectl delete -f "${REPO_ROOT}/gitops/security/fortiaigate/application.yaml" --ignore-not-found
  fi
  if kubectl get namespace fortiaigate &>/dev/null 2>&1; then
    log "  Deleting fortiaigate namespace (waiting for LBs/PVCs to release)..."
    kubectl delete namespace fortiaigate --timeout=120s \
      || warn "  Namespace deletion timed out — continuing anyway."
  fi

  # Agent + supervisor
  log "  Deleting agent and supervisor..."
  kubectl delete -f "${REPO_ROOT}/src/agent/k8s/"      --ignore-not-found
  kubectl delete -f "${REPO_ROOT}/src/supervisor/k8s/" --ignore-not-found

  # Security policies
  log "  Deleting Cilium policies and waypoint proxy..."
  kubectl delete -f "${REPO_ROOT}/gitops/security/cilium-policy-agent.yaml"      --ignore-not-found
  kubectl delete -f "${REPO_ROOT}/gitops/security/cilium-policy-supervisor.yaml" --ignore-not-found
  kubectl delete -f "${REPO_ROOT}/gitops/security/waypoint-proxy.yaml"           --ignore-not-found

  # Stop ArgoCD from re-syncing anything during destroy
  log "  Removing ArgoCD app-of-apps..."
  kubectl delete -f "${REPO_ROOT}/gitops/system/argocd/app-of-apps.yaml" --ignore-not-found || true

  log "  Waiting 15s for GCP to release load balancers..."
  sleep 15
else
  warn "Step 1/2 — Cluster unreachable, skipping Kubernetes cleanup."
fi

# ── Step 2: Targeted terraform destroy (compute only) ────────────────────────
log "Step 2/2 — Destroying GKE cluster and mesh membership (keeping network + IAM + GCS + mesh feature)..."
cd "${REPO_ROOT}/terraform"
terraform destroy \
  -target=google_gke_hub_feature_membership.mesh_membership \
  -target=module.gke \
  -var-file=terraform.tfvars
cd "${REPO_ROOT}"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Compute destroyed. Costs reduced.${NC}"
echo ""
echo "Still running (negligible cost):"
echo "  VPC, subnets, Cloud Router + NAT        — module.network"
echo "  GCS bucket + IAM service accounts       — module.iam"
echo "  GKE Hub mesh feature + time_sleep       — intentionally kept (free, avoids re-propagation delay)"
echo ""
echo "To restore compute: ./scripts/bringup.sh"
