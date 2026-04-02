# ArgoCD + Helm Secret Rotation: From 101 to 505

A field guide to why Helm-generated secrets rotate on every ArgoCD sync, how it cascades into system failures, and how to fix it permanently.

---

## 101 — What is GitOps and Why Does ArgoCD Exist?

### The problem GitOps solves

Before GitOps, deploying software to Kubernetes looked like this:

```
Developer → kubectl apply -f deployment.yaml → cluster
```

This works but has problems:
- Nobody knows what's actually running in the cluster
- Someone could `kubectl edit` a deployment and the change is invisible
- Rollback means remembering what the previous state was
- Two environments (staging, production) drift apart over time

GitOps flips the model: **Git is the single source of truth**. The cluster should always match what's in the Git repo. If there's a difference, something is wrong.

```
Git repo  ←→  ArgoCD watches  ←→  Kubernetes cluster
              "does cluster
               match Git?"
```

### What ArgoCD does

ArgoCD is the engine that enforces GitOps. It:

1. Watches a Git repository for changes
2. Computes the **desired state** (what the cluster should look like) from the repo
3. Compares it against the **actual state** (what the cluster currently looks like)
4. If there's a diff: applies the diff to make the cluster match Git
5. Repeats every ~3 minutes forever

This reconciliation loop is the foundation of everything that follows.

---

## 201 — How Helm Fits Into ArgoCD

### What Helm does

Helm is a templating engine for Kubernetes manifests. Instead of writing raw YAML for every environment, you write **templates** with variables:

```yaml
# Template
image: {{ .Values.image.repository }}:{{ .Values.image.tag }}

# values.yaml
image:
  repository: myapp
  tag: v1.2.3

# Output after helm template
image: myapp:v1.2.3
```

Helm packages templates + default values into a **chart**. You provide override values at install time. Helm renders everything and applies it to the cluster.

### ArgoCD + Helm

ArgoCD has native Helm support. When you point an ArgoCD `Application` at a Helm chart in Git, ArgoCD:

1. Checks out the Git repo
2. Runs `helm template` with your values files
3. Compares the rendered output to the live cluster
4. Applies any diffs

```yaml
# ArgoCD Application
spec:
  source:
    path: gitops/security/fortiaigate/chart
    helm:
      valueFiles:
        - override-values.yaml
```

This is powerful — your entire application configuration lives in Git as Helm values, and ArgoCD continuously enforces it.

### The key detail: ArgoCD runs `helm template`, not `helm upgrade`

When you run `helm upgrade` directly, Helm:
- Connects to the live cluster
- Reads existing resources
- Renders templates with access to live cluster data
- Applies the rendered output

When ArgoCD renders a Helm chart, it runs the equivalent of `helm template` — **offline**, without a live cluster connection. It produces the desired YAML, then uses its own diff/apply logic. This distinction becomes critical in a moment.

---

## 301 — Helm Secrets and the `lookup` Function

### The problem: secrets need to be generated once

Some secrets can't come from the user — they're internal keys that the application generates itself. Examples:
- Encryption keys for database fields
- Internal JWT signing keys
- Session secret keys
- Fernet keys for encrypting Redis data

For these, the Helm chart author wants: **"generate a random value on first install, then never change it."**

### The naive approach (broken)

```yaml
# templates/secret.yaml
apiVersion: v1
kind: Secret
data:
  encryption-key: {{ randAlphaNum 32 | b64enc | quote }}
```

`randAlphaNum 32` generates a random 32-character string. `b64enc` base64-encodes it for the Secret's `data` field.

**Problem**: this generates a new random value every time `helm template` runs. Every `helm upgrade` rotates the key. Any data encrypted with the old key becomes unreadable.

### The correct Helm pattern: `lookup`

Helm provides a `lookup` function that queries the live cluster:

```yaml
# templates/secret.yaml
{{- $secretObj := (lookup "v1" "Secret" .Release.Namespace "myapp-secret") | default dict }}
{{- $secretData := (get $secretObj "data") | default dict }}
{{- $encKey := (get $secretData "encryption-key") | default (randAlphaNum 32 | b64enc) }}

apiVersion: v1
kind: Secret
data:
  encryption-key: {{ $encKey | quote }}
```

Logic in plain English:
1. Look up the existing `myapp-secret` Secret in the cluster
2. If it exists, read the current `encryption-key` value
3. If not (first install), generate a new random one
4. Write whichever value was chosen

This is **idempotent**: the first `helm upgrade` generates the key. Every subsequent `helm upgrade` finds the existing secret and reuses the same key. The key never rotates.

### Why `helm.sh/resource-policy: keep` doesn't solve it

Chart authors sometimes add:

```yaml
metadata:
  annotations:
    helm.sh/resource-policy: keep
```

This tells Helm: "don't delete this resource on `helm uninstall`." It protects against accidental deletion but **does not prevent updates**. A `helm upgrade` can still overwrite the value. This annotation is commonly misunderstood as providing more protection than it does.

---

## 401 — Why ArgoCD Breaks the `lookup` Pattern

### The `lookup` problem with ArgoCD

Here's where everything goes wrong. ArgoCD renders Helm templates **without a live cluster connection**. When ArgoCD encounters:

```yaml
{{- $secretObj := (lookup "v1" "Secret" .Release.Namespace "myapp-secret") | default dict }}
```

`lookup` returns **nil** because there's no cluster to query. The `| default dict` catches this and returns an empty dict. `get $secretData "encryption-key"` returns nil. The `| default (randAlphaNum 32 | b64enc)` fires.

**Result: every ArgoCD sync renders a new random key.**

```
Direct helm upgrade:          ArgoCD sync:
─────────────────────         ─────────────────
lookup → Secret found    vs.  lookup → nil
  → use existing key            → default fires
  → key unchanged               → randAlphaNum 32
                                → NEW key every sync
```

ArgoCD then sees a diff between the rendered secret (new key) and the live secret (old key) and applies the update. The secret is overwritten.

### The cascading failure chain

This isn't just about a key changing. Depending on what the key protects, the consequences cascade:

```
ArgoCD sync
  │
  ▼
Helm re-renders → lookup nil → randAlphaNum fires
  │
  ▼
New LICENSE_KEY written to Secret
  │
  ▼
license-manager pods restart (secret changed triggers rollout)
  │
  ▼
New pods read new LICENSE_KEY from env
  │
  ▼
Try to decrypt existing Redis data (encrypted with OLD key)
  │
  ▼
"Failed to decrypt data" → fdn_client session lost
  │
  ▼
license-manager registers as NEW instance with FDN server
  │
  ▼
FDN: "license already in use by another instance"
  │
  ▼
core pods → 0/1 Running ("license status: in use")
  │
  ▼
FortiAIGate WebUI: "No license detected"
  │
  ▼
~3 hour wait for FDN session timeout
```

A routine Git push (even changing an unrelated value in `override-values.yaml`) triggers a sync, which starts this entire chain.

### The same problem affects Redis and PostgreSQL

The FortiAIGate chart uses the same `lookup | default (randAlphaNum)` pattern for Redis and PostgreSQL passwords:

```
Redis password rotates
  │
  ▼
license-manager (and other pods) can't authenticate to Redis
  │
  ▼
license status can't be read/written
  │
  ▼
"No license detected" / core pod 0/1
```

Three independent secrets all using the same fragile pattern. One ArgoCD sync can break all three simultaneously.

### Why this is a known ArgoCD limitation

ArgoCD documents this behavior. From the ArgoCD docs:

> "The `lookup` function is not supported when using Helm with ArgoCD because ArgoCD renders Helm charts without a cluster connection."

The `lookup` function was designed for direct Helm usage. It fundamentally requires cluster access that ArgoCD's rendering pipeline doesn't provide. This isn't a bug in either Helm or ArgoCD — it's an architectural mismatch between two tools designed for different usage patterns.

---

## 501 — Solutions and Their Tradeoffs

There are several approaches to solving this. Each has different tradeoffs.

### Solution A: `ignoreDifferences` (what we used)

Tell ArgoCD to ignore specific fields when computing diffs:

```yaml
# application.yaml
spec:
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: fortiaigate-license-manager
      jsonPointers:
        - /data/license-key
    - group: ""
      kind: Secret
      name: fortiaigate-redis
      jsonPointers:
        - /data/redis-password

  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true  # required for automated syncs
```

**How it works**: ArgoCD still renders the Helm template (and gets a new random key), but when computing the diff it ignores those specific JSON paths. The live secret is never overwritten.

**Pros**:
- No chart modification required
- Works with any upstream chart
- Keys are preserved indefinitely

**Cons**:
- You can never update those secret values through ArgoCD (intentional change would also be ignored)
- The ArgoCD UI will show the app as "Synced" even though the rendered manifest differs from the cluster — can be confusing
- `RespectIgnoreDifferences=true` must be set or automated syncs bypass it

---

### Solution B: Pre-create secrets outside the Helm chart

Create the secret manually before the chart is installed, with a fixed value you control:

```bash
kubectl create secret generic fortiaigate-license-manager \
  --namespace fortiaigate \
  --from-literal=license-key="$(openssl rand -base64 32)"
```

Then annotate it so Helm doesn't adopt it:
```bash
kubectl annotate secret fortiaigate-license-manager \
  helm.sh/resource-policy=keep
```

And tell ArgoCD not to manage it:
```yaml
# In application.yaml
spec:
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: fortiaigate-license-manager
```

**Pros**:
- You have explicit control over the secret value
- Clear separation between "infrastructure secrets" and "application config"

**Cons**:
- Manual step required before every fresh cluster install
- Easy to forget in runbooks
- Key not tracked in Git (intentional for secrets, but means no audit trail)

---

### Solution C: Seal the secrets in Git (Sealed Secrets / SOPS)

Use a secrets management tool to store **encrypted** secret values in Git. ArgoCD decrypts them at sync time.

**Sealed Secrets** (Bitnami):
```bash
# Encrypt the secret
kubeseal --format yaml < secret.yaml > sealed-secret.yaml
# Commit sealed-secret.yaml to Git — safe to store, only your cluster can decrypt
```

**SOPS** (Mozilla):
```yaml
# .sops.yaml encrypted file — decrypted by ArgoCD via SOPS plugin
license-key: ENC[AES256_GCM,data:abc123...,tag:xyz...]
```

**How it works**: The actual key value is stored in Git (encrypted). ArgoCD decrypts it at sync time with access to a KMS key (AWS KMS, GCP KMS, etc.). The rendered secret always has the same value (the decrypted secret from Git).

**Pros**:
- True GitOps: the exact secret value is in Git (encrypted)
- Auditable: you can see when secrets were created/rotated
- No `lookup` dependency — the value is explicit

**Cons**:
- Requires additional infrastructure (KMS, Sealed Secrets controller)
- Initial setup complexity
- Key rotation requires re-sealing all secrets

---

### Solution D: Use an external secrets manager

Store secrets in a dedicated secrets store (HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager) and sync them into Kubernetes using the External Secrets Operator (ESO):

```yaml
# ExternalSecret custom resource
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: fortiaigate-license-manager
spec:
  secretStoreRef:
    name: gcp-secret-manager
  target:
    name: fortiaigate-license-manager
  data:
    - secretKey: license-key
      remoteRef:
        key: fortiaigate-license-key
```

**How it works**: The `ExternalSecret` CR is committed to Git (no sensitive data). ESO reads the actual value from the external store and creates/updates the Kubernetes Secret. ArgoCD manages the `ExternalSecret` resource, not the Secret itself.

**Pros**:
- Clean separation: ArgoCD owns config, secrets manager owns secrets
- Centralized secrets management across multiple clusters/applications
- Rotation can be triggered independently of ArgoCD
- No `lookup` dependency

**Cons**:
- Most operationally mature solution — requires Vault/Secrets Manager setup
- Another component to operate and secure
- Overkill for simple demos

---

## 505 — Architectural Lessons and Production Patterns

### The fundamental tension: idempotency vs. randomness

Kubernetes + GitOps requires **idempotency**: applying the same manifests repeatedly produces the same state. Helm's `randAlphaNum` is inherently non-idempotent. These two requirements are in direct conflict.

The `lookup` function was an attempt to bridge them — "be random once, then idempotent forever." It works under direct Helm usage but breaks in any pipeline that renders templates without cluster access (ArgoCD, Flux, CI preview environments, `helm template` in pipelines).

The architectural lesson: **auto-generated secrets and GitOps are fundamentally incompatible unless you externalize the secret value**. The secret value must come from somewhere stable — either explicitly in Git (encrypted) or from an external store. It cannot be generated at render time.

### Why this matters beyond FortiAIGate

The `lookup | default (randAlphaNum)` pattern is extremely common in public Helm charts. Charts for Redis, PostgreSQL, RabbitMQ, and many third-party applications use this pattern for their internal passwords and keys. If you adopt ArgoCD to manage these charts, you will hit this problem repeatedly.

Before adopting any Helm chart with ArgoCD, audit its templates for:
```bash
grep -r "randAlphaNum\|randAlpha\|uuidv4\|lookup" chart/templates/
```

Any chart using `randAlphaNum` without `lookup` will rotate on every sync. Any chart using `lookup | default (randAlphaNum)` will rotate on every ArgoCD sync (since `lookup` returns nil).

### The FDN session problem: a secondary architectural issue

The FortiAIGate license system compounds the secret rotation problem with its own design choice: the `fdn_client` session state is stored in Redis (ephemeral, encrypted with the LICENSE_KEY). This creates a dependency chain:

```
LICENSE_KEY stable → fdn_client decryptable → FDN session preserved → licenses Active
LICENSE_KEY rotates → fdn_client undecryptable → FDN session lost → licenses "In Use"
```

A more resilient design would store the FDN session on a persistent volume (not Redis) and tie it to the node hardware fingerprint rather than a pod-level encryption key. The Fortinet team chose Redis for simplicity — it works fine in environments where the key never changes (direct Helm usage) but is fragile under ArgoCD.

### The `helm.sh/resource-policy: keep` misconception

This annotation is widely misunderstood. It appears in many charts alongside `randAlphaNum` as if it provides stability. A clear breakdown:

| Scenario | Effect of `resource-policy: keep` |
|---|---|
| `helm uninstall` | ✓ Secret NOT deleted |
| `helm upgrade` | ✗ Secret CAN be updated |
| ArgoCD sync | ✗ Secret CAN be updated |
| `kubectl delete secret` | ✗ No protection |

The annotation only protects against deletion during uninstall. It provides no protection against value updates. Charts that rely on it for key stability under ArgoCD are incorrectly relying on an annotation that doesn't do what the author thinks it does.

### Recommended pattern for production ArgoCD + Helm

For any application with auto-generated internal secrets:

1. **At install time**: let Helm generate the secret once via direct `helm install` (not ArgoCD)
2. **Export and seal**: export the generated secrets and seal them with SOPS or Sealed Secrets
3. **Commit sealed secrets to Git**: now the values are stable and in source control
4. **Add `ignoreDifferences`**: belt-and-suspenders protection against the chart re-generating

Or, for teams with a secrets manager:

1. **Pre-populate secrets in Vault/Secret Manager** before ArgoCD touches the chart
2. **Use External Secrets Operator** to sync into Kubernetes
3. **Add `ignoreDifferences`** for the Kubernetes Secret objects themselves
4. ArgoCD manages configuration; the secrets layer manages secrets independently

### Summary table

| Approach | GitOps purity | Complexity | Rotation risk | Best for |
|---|---|---|---|---|
| `ignoreDifferences` | Medium (secret not in Git) | Low | None after fix | Immediate fix, demo/dev |
| Pre-created secret | Medium | Low | Manual control | Small teams, few secrets |
| Sealed Secrets | High | Medium | Explicit rotation only | Most production use cases |
| External Secrets + Vault | Highest | High | External lifecycle mgmt | Enterprises, multi-cluster |
| Nothing (raw chart) | Low | None | Every ArgoCD sync | Never do this |

The core principle across all solutions: **separate the concern of "what value should this secret have" from the concern of "how do I apply this configuration to the cluster."** GitOps tools are excellent at the second part. They need help with the first.
