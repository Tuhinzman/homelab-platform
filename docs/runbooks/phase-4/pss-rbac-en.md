# Phase 4 S7 — Pod Security Standards + RBAC Baseline

**Date:** 2026-05-01
**Phase:** 4 (Security)
**Step:** S7
**Status:** COMPLETE
**Owner:** Tuhin Zaman

---

## 1. Goal & Scope

Establish the security baseline for application namespaces in the homelab Kubernetes cluster.

**In scope:**

- Apply Pod Security Standards (PSS) labels to four namespaces per v2.5 plan §Phase 4.
- Disable `automountServiceAccountToken` on the `default` ServiceAccount in `dev`, `staging`, `prod`.
- Prove enforcement with admission-rejection drills (restricted + baseline profiles).
- Verify no kube-system regression after labeling.

**Out of scope (surgical-change rule):**

- Pre-existing PSS labels on `ingress-nginx`, `longhorn-system`, `metallb-system` — left untouched.
- Platform namespaces without PSS labels (`cert-manager`, `default`, `kube-node-lease`, `kube-public`) — not in plan's PSS table.
- Scoped Role/RoleBinding creation in `dev`/`staging`/`prod` — no workloads exist yet, no demonstrable need (Task 10 skipped, see §6.1).
- Longhorn support-bundle SA cluster-admin grant — drift observed, deferred to Phase 13 (D10, see §7.1).

---

## 2. Pre-flight Gates

All five gates passed before any S7 mutation:

| Gate | Check                                            | Result                                                                                |
| ---- | ------------------------------------------------ | ------------------------------------------------------------------------------------- |
| G1   | S6.5 Section 9 runbook commit landed             | `3e1fa2c` already on `origin/main`                                                    |
| G2   | Cluster nodes Ready                              | 4 nodes Ready, no crashloops, etcd 1/1 Running                                        |
| G3   | Encryption-at-rest active post-rotation          | etcd peek of `cert-manager/homelab-signing-ca` confirmed envelope `k8s:enc:aescbc:v1:key1:` |
| G4   | ClusterIssuer `homelab-signing-ca` Ready=True    | Verified post-D8 rotation                                                             |
| G5   | D9 status unchanged (OPEN)                       | `ca-en.md` lines 761, 1108 unchanged                                                  |

**Encryption-at-rest verification used secret-blind discipline (memory rule):** etcdctl output piped to Python which read bytes internally and emitted only envelope metadata + length + verdict — no Secret body bytes ever reached stdout.

---

## 3. Inventory Snapshots

### 3.1 PSS Label State Before S7

| Namespace        | Enforce          | Audit       | Warn        | Disposition                                |
| ---------------- | ---------------- | ----------- | ----------- | ------------------------------------------ |
| cert-manager     | —                | —           | —           | Out of scope, untouched                    |
| default          | —                | —           | —           | Out of scope, untouched                    |
| ingress-nginx    | baseline         | restricted  | restricted  | **Asymmetric drift, untouched** (see §7.2) |
| kube-node-lease  | —                | —           | —           | System ns, untouched                       |
| kube-public      | —                | —           | —           | System ns, untouched                       |
| kube-system      | —                | —           | —           | **Will label privileged**                  |
| longhorn-system  | privileged       | privileged  | privileged  | Already aligned, untouched                 |
| metallb-system   | privileged       | privileged  | privileged  | Already aligned, untouched                 |
| dev              | (does not exist) | —           | —           | **Will create + label baseline**           |
| staging          | (does not exist) | —           | —           | **Will create + label baseline**           |
| prod             | (does not exist) | —           | —           | **Will create + label restricted**         |

### 3.2 RBAC Inventory (cluster-admin bindings)

```
cluster-admin            Group/system:masters
kubeadm:cluster-admins   Group/kubeadm:cluster-admins
longhorn-support-bundle  ServiceAccount/longhorn-support-bundle    [DRIFT — D10]
```

First two are kubeadm defaults. The third is upstream Longhorn Helm chart default — flagged as D10 (see §7.1).

### 3.3 Default ServiceAccount State (dev/staging/prod)

After namespace creation, each namespace has only the auto-created `default` SA with `automountServiceAccountToken` field unset (Kubernetes defaults to `true` at pod level).

---

## 4. Mutations Applied

### 4.1 PSS Labels

**Declarative source:** `k8s/namespaces/applications.yaml` — Namespaces dev/staging/prod with PSS labels embedded.

**Imperative label for kube-system** (existing namespace, not in declarative file):

```bash
# [Mac terminal]
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```

`--overwrite` flag makes the command idempotent.

**Apply declarative file:**

```bash
# [Mac terminal]
kubectl apply -f k8s/namespaces/applications.yaml
```

**Result:**

- `namespace/dev created`
- `namespace/staging created`
- `namespace/prod created`
- `namespace/kube-system labeled`

**Verification (post-apply):**

| Namespace   | Enforce    | Audit      | Warn       |
| ----------- | ---------- | ---------- | ---------- |
| kube-system | privileged | privileged | privileged |
| dev         | baseline   | baseline   | baseline   |
| staging     | baseline   | baseline   | baseline   |
| prod        | restricted | restricted | restricted |

### 4.2 Default ServiceAccount Tightening

**Declarative additions to `applications.yaml`:**

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: dev
automountServiceAccountToken: false
---
# (same for staging, prod)
```

**Apply:**

```bash
# [Mac terminal]
kubectl apply -f k8s/namespaces/applications.yaml
```

**Result:** `serviceaccount/default configured` × 3.

Warnings about missing `kubectl.kubernetes.io/last-applied-configuration` annotation are expected — auto-created SAs lack this annotation; first kubectl apply patches it. Future applies are silent.

**Verification:**

```
=== dev ===
false
=== staging ===
false
=== prod ===
false
```

All three default SAs confirm `automountServiceAccountToken: false`.

---

## 5. Drills & Proofs

### 5.1 Drill 1 — Restricted Profile Rejects Privileged Pod

**Goal:** Prove `prod` namespace (enforce=restricted) rejects a privileged Pod admission.

**Manifest violations (intentional):**

- `privileged: true`
- No `runAsNonRoot`
- No `seccompProfile`
- No `allowPrivilegeEscalation: false`
- No `capabilities.drop: ALL`

**Manifest applied to prod namespace.**

**Result:**

```
Error from server (Forbidden): error when creating "STDIN": pods "privileged-test"
is forbidden: violates PodSecurity "restricted:latest":
privileged (container "test" must not set securityContext.privileged=true),
allowPrivilegeEscalation != false,
unrestricted capabilities (must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true,
seccompProfile (must set type to "RuntimeDefault" or "Localhost")
```

`kubectl get pod privileged-test -n prod` → `Error from server (NotFound)`.

**Verdict:** PASS — all 5 violations caught, pod never created.

### 5.2 Drill 1b — Baseline Profile Rejects hostNetwork Pod

**Goal:** Prove `dev` namespace (enforce=baseline) rejects a Pod using host namespaces.

**Manifest:** Pod with `hostNetwork: true` applied to dev namespace.

**Result:**

```
Error from server (Forbidden): pods "baseline-violation-test" is forbidden:
violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)
```

`kubectl get pod baseline-violation-test -n dev` → `Error from server (NotFound)`.

**Verdict:** PASS — baseline profile blocks host namespaces, pod never created.

### 5.3 Drill 2 — Restricted Accepts Compliant Pod, No SA Token Mount

**Goal:** Two-in-one validation — (a) PSS restricted accepts a compliant Pod (positive control to Drill 1), (b) default SA tightening prevents token auto-mount.

**Compliant Pod manifest applied to prod namespace** with all 5 restricted-required securityContext fields set: `runAsNonRoot: true`, `runAsUser: 65534`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault`.

**Result:**

```
pod/compliant-test created
NAME             READY   STATUS    RESTARTS   AGE
compliant-test   1/1     Running   0          4s
```

**Critical proof — no SA token volume mounted:**

```
kubectl describe pod compliant-test -n prod | grep -A2 'Mounts:'
Mounts:         <none>
```

**Verdict:** PASS on both counts.

- Restricted profile accepts compliant Pod (admission allowed, pod runs).
- Default SA tightening confirmed — without our `automountServiceAccountToken: false`, the pod would have a `kube-api-access-XXXXX` projected volume mounted at `/var/run/secrets/kubernetes.io/serviceaccount` containing the SA token.

**Cleanup:**

```bash
kubectl delete pod compliant-test -n prod --grace-period=0 --force
```

### 5.4 Drill 3 — Auth can-i Matrix Baseline

**Goal:** Confirm RBAC baseline — default SAs in dev/staging/prod have zero permissions; current user (kubeadm admin) has full access.

**Matrix executed:**

| Test                                                       | Expected | Actual |
| ---------------------------------------------------------- | -------- | ------ |
| prod default SA → get pods in prod                         | no       | no     |
| prod default SA → get secrets in kube-system (cross-ns)    | no       | no     |
| dev default SA → create pods in dev                        | no       | no     |
| staging default SA → list configmaps cluster-wide          | no       | no     |
| current user (admin) → list pods all-namespaces            | yes      | yes    |

**Verdict:** PASS — vanilla Kubernetes zero-permission baseline confirmed for default SAs. Phase 5+ workloads will introduce dedicated SAs with scoped permissions as needed.

### 5.5 Post-Mutation kube-system Safety Check

**Goal:** Verify kube-system labeling caused no regression.

**Result:** All 16 kube-system pods Running 1/1:

- `etcd-k8s-cp-1` (1/1)
- `kube-apiserver-k8s-cp-1` (1/1)
- `kube-controller-manager-k8s-cp-1` (1/1)
- `kube-scheduler-k8s-cp-1` (1/1)
- `kube-proxy-*` × 4 (one per node)
- `coredns-*` × 2
- `calico-node-*` × 4 (one per node)
- `calico-kube-controllers-*` (1/1)

Pre-existing restart counts (7) and apiserver age (15h) trace back to S6.5 encryption-config flag enable on apiserver — not caused by S7.

**Verdict:** PASS — zero regression. As predicted: applying `enforce=privileged` to a namespace causes no behavior change because privileged is the most permissive level.

---

## 6. Surgical Scope Decisions

### 6.1 Task 10 (Scoped Role/RoleBinding) Skipped

**Original plan:** Create scoped Role/RoleBindings for known workloads in dev/staging/prod.

**State at S7 execution:**

- No workloads in dev/staging/prod
- No GitLab Runner (Phase 5 not started)
- No ArgoCD (Phase 6 not started)

**Decision:** No bindings created this session. Per surgical-change rule (CLAUDE.md §4): "only what's demonstrably needed now."

**Principle locked for future phases:**

> Application namespaces (dev/staging/prod) launch with NO custom Roles/RoleBindings. Per-workload SAs and scoped bindings are created when the workload lands (Phase 5+, 12a, 12b). Default SA usage forbidden by `automountServiceAccountToken: false` baseline established in S7.

### 6.2 Out-of-Scope Namespaces

The following namespaces were left untouched:

- `cert-manager`, `default` — no PSS labels currently, not in plan's PSS table; defer to a later session if needed.
- `kube-node-lease`, `kube-public` — system family namespaces; could align with kube-system (privileged) but not in plan; deferred.
- `ingress-nginx` — pre-existing asymmetric labels (see §7.2).
- `longhorn-system`, `metallb-system` — already aligned (privileged); untouched.

---

## 7. Drift Observations & Open Deviations

### 7.1 D10 — longhorn-support-bundle ServiceAccount Has cluster-admin (OPEN, accepted)

- **Discovered:** 2026-05-01 during Phase 4 S7 RBAC inventory.
- **Subject:** `longhorn-support-bundle` ServiceAccount in `longhorn-system` namespace.
- **Bound to:** `cluster-admin` ClusterRole.
- **Source:** Upstream Longhorn Helm chart default (community-known security gap).
- **Risk:** Low — SA is mounted only when support bundle generation is triggered (on-demand, not continuously). However, when active, grants full cluster read/write.
- **Acceptance:** Lab-accepted, S7-scope-deferred (fixing it requires Longhorn Helm values override + chart upgrade — out of scope here).
- **Closure target:** Phase 13 (Backup work touches Longhorn naturally — appropriate point for values override).
- **Monitoring:** Re-verify SA still exists during each Longhorn upgrade; add note to Phase 13 runbook to address.
- **Status:** OPEN.

### 7.2 ingress-nginx Asymmetric PSS Labels (Drift, No Action)

- `ingress-nginx` namespace: enforce=baseline, audit=restricted, warn=restricted.
- Pattern is legitimate ("warn me on restricted, enforce only baseline") but inconsistent with the typical aligned-3 convention used elsewhere in this cluster.
- **No action this session** — pre-existing config, not in S7 scope.
- **Future review:** Decide whether to align all three to baseline OR explicitly document this as intentional asymmetry.

---

## 8. Lessons Learned (Locked Rules)

### 8.1 Display vs Data — Chat Autolink Artifact

**Symptom:** During YAML file creation via heredoc paste, the file content displayed in chat as `[pod-security.kubernetes.io/enforce](http://pod-security.kubernetes.io/enforce): baseline` — an apparent markdown autolink corruption.

**Verification with `xxd`:** Raw file bytes showed clean text, no `[` (0x5b) or `(http://` byte sequences. The bracket format was a chat-rendering artifact only. File on disk and shell paste both clean.

**Locked rule (extends memory #17):** When chat output looks malformed for URL-like / FQDN-containing strings:

1. Run `xxd` or `od -c` on the file/data first.
2. Do NOT escalate to rewrite without byte-level verification.
3. Same applies to terminal output pasted back into chat — the autolink can re-trigger on output, even when source bytes are clean.

This rule saved a wasted file-rewrite cycle this session.

### 8.2 Drill Ordering — Verify Mutations Before Next Step

**Symptom:** Initial task order placed all drills (1, 2, 3) at the END of the session, after both PSS and RBAC mutations were applied.

**Problem:** PSS apply (Task 7) followed by default SA tighten (Task 9) without admission-rejection proof in between meant the second mutation depended on an unverified first mutation.

**Locked rule (reinforces "run → verify → proceed"):** When two mutations affect the same security domain, run the validation drill for the first mutation before applying the second. In this session: Drill 1 (PSS restricted enforcement) belonged immediately after Task 7 (PSS apply), not after Task 9 (SA tighten).

User pushback caught this gap. Drill 1 + Drill 1b ran before Task 9 retroactively in the corrected execution.

---

## 9. Rollback Commands (Reference)

These commands fully reverse all S7 mutations. Not destructive to existing workloads since the affected namespaces were either empty (dev/staging/prod) or received a no-op label change (kube-system → privileged).

### 9.1 Roll Back PSS Labels on Application Namespaces

```bash
# [Mac terminal]
kubectl label namespace dev staging prod \
  pod-security.kubernetes.io/enforce- \
  pod-security.kubernetes.io/audit- \
  pod-security.kubernetes.io/warn-
```

### 9.2 Roll Back PSS Label on kube-system

```bash
# [Mac terminal]
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce- \
  pod-security.kubernetes.io/audit- \
  pod-security.kubernetes.io/warn-
```

### 9.3 Roll Back Default SA Tightening

```bash
# [Mac terminal]
for ns in dev staging prod; do
  kubectl patch serviceaccount default -n $ns \
    -p '{"automountServiceAccountToken": null}'
done
```

`null` value resets the field to unset (revert to Kubernetes default behavior).

### 9.4 Delete Application Namespaces (only if truly desired)

```bash
# [Mac terminal]
kubectl delete -f k8s/namespaces/applications.yaml
```

**Warning:** This deletes the namespaces themselves, including any future workloads. Only use if reverting the entire S7 namespace creation.

---

## 10. Artifacts Committed

| Artifact                              | Path                                  | Purpose                                                                      |
| ------------------------------------- | ------------------------------------- | ---------------------------------------------------------------------------- |
| Application namespace declarative file | `k8s/namespaces/applications.yaml`    | Single source of truth for dev/staging/prod + their default SA overrides     |
| English runbook                       | `docs/runbooks/phase-4/pss-rbac-en.md` | This document                                                                |
| Bangla runbook                        | `docs/runbooks/phase-4/pss-rbac-bn.md` | Bangla mirror                                                                |
