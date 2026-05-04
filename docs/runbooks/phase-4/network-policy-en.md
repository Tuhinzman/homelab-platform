# Phase 4 S8 — NetworkPolicy (default-deny + allow-DNS)

> **Phase:** 4 (Security) · **Step:** 8 · **Status:** Complete
> **Date:** 2026-05-01 · **Cluster:** kubeadm v1.31.14, Calico v3.29.3

---

## 1. Goal

Apply default-deny ingress + egress NetworkPolicy in the `dev`, `staging`, and `prod` namespaces, plus a minimum-viable allow rule (DNS to CoreDNS). Remaining allow rules (ingress-nginx, OTel, external HTTPS, monitoring) will land via the workload-arrival pattern in later phases.

v2.5 §Phase 4 demand: "Default deny all ingress + egress per namespace" + explicit allow list.

---

## 2. Pre-flight checks

Read-only verification of the cluster baseline and S7 regression before any S8 mutation.

| Check | Expected | Why |
|---|---|---|
| 4 nodes Ready, v1.31.14 | All `Ready` | Cluster healthy |
| kube-system pods | All `Running`, no CrashLoop | Platform layer healthy |
| PSS labels | dev/staging=baseline, prod=restricted, kube-system=privileged | S7 regression |
| Default SA automount | dev/staging/prod = `false` | S7 regression |
| Calico image | `docker.io/calico/node:v3.29.3` | NetworkPolicy-capable CNI |
| Core API | `networkpolicies.networking.k8s.io/v1` namespaced | API available |
| Calico CRDs | `networkpolicies.crd.projectcalico.org`, `globalnetworkpolicies...`, etc. | Calico extended set present |

**Admission/lifecycle proof** (NOT runtime enforcement proof — drills cover that):

```bash
# Throwaway no-op NetworkPolicy: apply, verify, delete, confirm clean
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: preflight-canary
  namespace: dev
spec:
  podSelector:
    matchLabels:
      preflight-canary: "true"
  policyTypes: [Ingress, Egress]
YAML
kubectl get networkpolicy preflight-canary -n dev
kubectl delete networkpolicy preflight-canary -n dev
kubectl get networkpolicy -A   # expect: No resources found
```

The API admission path is proven; runtime enforcement remains unproven at this stage.

---

## 3. Scope decisions

| Namespace | Default-deny? | Reason |
|---|---|---|
| `dev` | ✅ Apply | App workload ns, PSS=baseline |
| `staging` | ✅ Apply | App workload ns, PSS=baseline |
| `prod` | ✅ Apply | App workload ns, PSS=restricted |
| `kube-system` | ❌ NEVER | Holds CoreDNS/kube-proxy/calico-node/etcd/apiserver — applying default-deny here would break the cluster instantly |
| `cert-manager` | ⏸ Defer | Traffic graph audit needed (controller→apiserver, ACME, validating webhook) |
| `ingress-nginx` | ⏸ Defer | External entry point; should be paired with an "ingress-nginx → app pods" allow rule |
| `longhorn-system` | ⏸ Defer | iSCSI traffic, D10 OPEN, naturally revisited during Phase 13 backup work |
| `metallb-system` | ⏸ Defer | Mixed hostNetwork/pod-network model, separate analysis required |

**Net S8 scope:** dev, staging, prod (3 namespaces).

---

## 4. File authoring + structural verify

### File layout

```text
k8s/network-policies/
├── default-deny-dev.yaml
├── default-deny-staging.yaml
├── default-deny-prod.yaml
├── allow-dns-dev.yaml
├── allow-dns-staging.yaml
└── allow-dns-prod.yaml
```

**Why per-ns files (not multi-doc):** canary rollout requires per-ns control — apply to dev → verify → staging → verify → prod → verify. A single multi-doc file with `kubectl apply -f` would apply all three at once, defeating canary discipline. Per-ns files give a clean per-ns apply and a clean per-ns rollback.

### Default-deny YAML shape

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: <ns>
spec:
  podSelector: {}                # match all pods
  policyTypes: [Ingress, Egress] # both directions
  # no allow rules below = total deny
```

`podSelector: {}` is an empty selector matching all pods in the namespace. Listing both `policyTypes` without any `ingress:` or `egress:` rules below produces total bidirectional deny.

### Allow-DNS YAML shape

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: <ns>
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

**Selector reasoning:**
- `kubernetes.io/metadata.name=kube-system` is the auto-applied namespace label that became stable in k8s 1.21+. It is a reliable identifier without manual labeling.
- `k8s-app=kube-dns` is the standard label that kubeadm-installed CoreDNS pods carry (a legacy convention preserved for backward-compat with the pre-CoreDNS kube-dns era).
- Combining both is tighter than namespaceSelector-only — principle of least privilege.

**Port reasoning:**
- UDP/53 is the primary DNS path.
- TCP/53 covers the fallback for responses larger than 512 bytes (RFC + EDNS0 truncation behavior).

**Asymmetry note:** kube-system has no default-deny applied (it is out of S8 scope), so no reciprocal ingress allow rule is needed there — CoreDNS pods accept ingress by default.

### Structural verify (Python)

`kubectl apply --dry-run=server` validates schema and admission, not semantic intent. For example, an accidental allow rule would still pass server dry-run while breaking the default-deny intent. An additional Python parse asserts structural invariants:

```python
import yaml
with open('k8s/network-policies/default-deny-dev.yaml') as f:
    d = yaml.safe_load(f)
assert d['spec']['podSelector'] == {}
assert sorted(d['spec']['policyTypes']) == ['Egress', 'Ingress']
assert 'ingress' not in d['spec']  # no allow rules
assert 'egress' not in d['spec']
```

The server says "valid NetworkPolicy"; Python says "valid **default-deny** NetworkPolicy".

---

## 5. Default-deny rollout — per-ns canary

**Order:** dev → verify → staging → verify → prod → verify. Never batched.

```bash
kubectl apply -f k8s/network-policies/default-deny-dev.yaml
kubectl get networkpolicy default-deny -n dev
# scope check: only dev should appear
kubectl get networkpolicy -A
```

After dev is verified, repeat for staging and prod with the same pattern.

**Cluster Policy Mutation Gate** (required language at each apply):
- What changes: 1 NetworkPolicy in 1 ns
- Effect: Felix programs iptables → total ingress + egress block in target ns
- Blast radius: zero (all 3 ns empty pre-apply)
- Reversibility: `kubectl delete -f <file>`
- Irreversibility-class: NO (no key material, fully reversible)

---

## 6. Drills (runtime enforcement proof)

### Drill 1 — External egress blocked from dev

**Goal:** Verify default-deny actually drops packets at runtime, not just at the declarative layer.

```bash
kubectl run drill1-egress-test \
  --namespace=dev \
  --image=curlimages/curl:8.10.1 \
  --restart=Never --rm -i \
  --command -- curl -sS --max-time 15 -o /dev/null \
    -w "HTTP=%{http_code} TIME=%{time_total}s\n" https://1.1.1.1
```

**Expected (PASS):** `HTTP=000 TIME=15.0xxx s`, curl error 28 (timeout), exit=28.
**Observed:** `HTTP=000 TIME=15.002674s`, exit=28 ✅

### Drill 2 — DNS path also blocked (deny is total)

**Goal:** Confirm default-deny includes the kube-system path, not just external traffic.

```bash
kubectl run drill2-dns-test \
  --namespace=dev \
  --image=busybox:1.36 \
  --restart=Never --rm -i \
  --command -- sh -c 'timeout 10 nslookup kubernetes.default.svc.cluster.local 2>&1; echo "nslookup_exit=$?"'
```

**Expected (PASS):** `;; connection timed out; no servers could be reached`, nslookup_exit=1.
**Observed:** Match ✅

### Drill 3a — DNS resolves after allow-dns is applied

**Goal:** allow-dns rule works at runtime; Felix programs the new ipset entry.

```bash
kubectl run drill3a-dns \
  --namespace=dev --image=busybox:1.36 \
  --restart=Never --rm -i \
  --command -- timeout 10 nslookup kubernetes.default.svc.cluster.local
```

**Expected (PASS):** `Address: 10.96.0.1`, exit=0.
**Observed:** Match ✅

### Drill 3b — External HTTPS still blocked (additive proof)

**Goal:** Confirm allow-dns is additive, not replacing — it did not accidentally open all egress.

```bash
kubectl run drill3b-egress \
  --namespace=dev --image=curlimages/curl:8.10.1 \
  --restart=Never --rm -i \
  --command -- curl -sS --max-time 15 -o /dev/null \
    -w "HTTP=%{http_code} TIME=%{time_total}s\n" https://1.1.1.1
```

**Expected (PASS):** Identical signature to Drill 1 — `HTTP=000`, exit=28.
**Observed:** Match ✅

**Drill ordering rule (locked):** A drill belongs immediately after the mutation it validates. Drill 1+2 ran after dev's default-deny apply, before the staging/prod rollout. Drill 3a+3b ran after dev's allow-dns apply, before the staging/prod allow-dns rollout. Drills are not repeated for staging/prod (mechanism uniformity argument).

---

## 7. Allow-dns rollout — per-ns canary

After dev was verified (Drill 3a+3b PASS), allow-dns was rolled out to staging and then prod. Drills were NOT repeated for staging/prod — same Calico, same YAML shape (structural verify confirmed), same Felix path = same runtime behavior.

```bash
kubectl apply -f k8s/network-policies/allow-dns-staging.yaml
kubectl apply -f k8s/network-policies/allow-dns-prod.yaml
kubectl get networkpolicy -A   # expect 6 rows
```

Final state: 3 ns × (default-deny + allow-dns) = 6 NetworkPolicy resources.

---

## 8. End-to-end prod verification (PSS=restricted-compliant)

Drills 1–3 ran in dev (PSS=baseline). The `kubectl run` shortcut passes PSS=baseline but is rejected under PSS=restricted. Verifying enforcement in prod therefore requires a manifest-based pod with full securityContext — see the §9 template.

prod verification result (manifest-based):
- DNS resolves (`Address: 10.96.0.1`) ✅
- External HTTPS blocked (`HTTP=000`, curl error 28) ✅

**Architectural significance:** the S7 PSS + S8 NetworkPolicy stack-up integration is verified — both layers cooperate correctly.

---

## 9. PSS=restricted test pod template

In a PSS=restricted namespace, generic `kubectl run` is rejected:

```text
violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false
  unrestricted capabilities
  runAsNonRoot != true
  seccompProfile (must be RuntimeDefault or Localhost)
```

Every restricted-ns pod requires a full securityContext. Template:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: <pod-name>
  namespace: prod
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault          # required by restricted PSS
  containers:
  - name: <container-name>
    image: <image>
    command: ["sh", "-c", "<test-command>; sleep 1"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 65534              # nobody
      capabilities:
        drop: ["ALL"]
```

**Test execution pattern:**

```bash
kubectl apply -f /tmp/test-pod.yaml
kubectl wait -n prod --for=condition=Ready pod/<name> --timeout=60s
sleep 10                            # allow command + timeout to complete
kubectl logs -n prod pod/<name>
kubectl get pod <name> -n prod \
  -o jsonpath='exitCode={.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
kubectl delete pod <name> -n prod
```

**Why not `kubectl run --rm -i`:** PSS=restricted requires a manifest-based pod creation flow; the synchronous pattern of `--rm -i` does not apply cleanly to manifest-based pods. The async lifecycle is: create → wait Ready → fetch logs → delete.

`kubectl logs` called too early returns a `ContainerCreating` error, so `kubectl wait --for=condition=Ready` is mandatory before fetching logs.

---

## 10. Drill 4 — Reversibility / Ablation test

**Goal:** Confirm the NetworkPolicy lifecycle is properly reversible at runtime — when a rule is deleted, enforcement state updates immediately and Felix does not cache stale state anywhere.

**Why this drill matters:** Drills 1–3 prove state A (deny) → state B (allow added). They do not prove the round-trip state A → state B → state A. This drill does.

```bash
# 1. delete allow-dns (state B → state A)
kubectl delete networkpolicy allow-dns -n dev

# 2. immediate DNS test → expect failure (back to total deny)
kubectl run drill4-dns-drop \
  --namespace=dev --image=busybox:1.36 \
  --restart=Never --rm -i \
  --command -- sh -c 'timeout 10 nslookup kubernetes.default.svc.cluster.local; echo "dns_exit=$?"'

# 3. re-apply allow-dns (state A → state B)
kubectl apply -f k8s/network-policies/allow-dns-dev.yaml

# 4. confirm both policies present
kubectl get networkpolicy -n dev
```

**Expected (PASS):**
- Step 2: `;; connection timed out`, `dns_exit=1` (rule removed → DNS blocked again, no caching)
- Step 4: 2 rows — `allow-dns` + `default-deny`

**Observed:** Match ✅ (executed during S8 as a user-driven ablation test)

---

## 11. Future allow rules (TODO ledger)

Workload-arrival pattern: each allow rule is added when its corresponding workload is deployed.

| Allow rule | Phase | Notes |
|---|---|---|
| ingress-nginx → app pods | 6 (paired with first GitOps app) | ingress-nginx → app traffic, ports 80/443 + readiness probe paths |
| app pods → OTel Collector | 11 | OTLP gRPC :4317, OTLP HTTP :4318 |
| app pods → external HTTPS | 17+ | Anthropic/OpenAI API calls, port 443 |
| Monitoring scrapers → target ns | 8 | Prometheus cross-ns scrape, port 8080/metrics |
| App pods → in-cluster database | When DB deployed | Postgres :5432, etc. |

---

## 12. Deferred default-deny (TODO ledger)

| Namespace | Defer reason | Closure target |
|---|---|---|
| `cert-manager` | Traffic graph audit needed (controller↔apiserver, ACME, validating webhook) | Phase 4 close-out follow-up OR Phase 6 GitOps |
| `ingress-nginx` | Pair with the "ingress-nginx → app" allow rule | Phase 6 |
| `longhorn-system` | iSCSI / instance-manager pod-to-pod, D10 awareness | Phase 13 backup work natural revisit |
| `metallb-system` | speaker uses hostNetwork=true (NetworkPolicy is ineffective on host-net pods); controller is pod-network. Mixed model, separate analysis | TBD |

**`kube-system` is permanently excluded** — it is the platform layer, not a namespace to fence with NetworkPolicy.

---

## 13. Reversal procedure

Full S8 rollback (cluster-wide):

```bash
# allow rules first, then deny rules
kubectl delete -f k8s/network-policies/allow-dns-dev.yaml
kubectl delete -f k8s/network-policies/allow-dns-staging.yaml
kubectl delete -f k8s/network-policies/allow-dns-prod.yaml
kubectl delete -f k8s/network-policies/default-deny-dev.yaml
kubectl delete -f k8s/network-policies/default-deny-staging.yaml
kubectl delete -f k8s/network-policies/default-deny-prod.yaml

kubectl get networkpolicy -A   # expect: No resources found
```

**Order reasoning:** allow rules are subordinate to deny rules. Deleting deny first opens a brief default-allow window (the allow rule is still present but irrelevant since nothing blocks). Not security-critical here (empty namespaces), but it keeps the state machine clean — the opposite of apply order is a clean rollback.

Per-ns rollback follows the same pattern (allow first, deny second).

---

## 14. Lessons learned

1. **Admission/lifecycle proof ≠ runtime enforcement proof.** `kubectl apply --dry-run=server` only validates the API path. Runtime enforcement requires drill execution. Earlier in the session these were conflated; the language is now locked separately.

2. **Drill ordering: a drill belongs immediately after the mutation it validates.** The per-ns canary order interleaves with drill order: dev apply → drills → staging apply → (drill skipped if mechanism proven) → prod apply.

3. **Mechanism uniformity argument is valid.** A drill is a mechanism proof. Same YAML shape + same Calico = same enforcement. Per-ns drill repetition is ceremony with no information gain. **However**, cross-PSS-class verification (baseline vs restricted) is a different test and should not be skipped.

4. **`kubectl run --rm -i` with compound shell heredocs is unreliable.** Drill 3's first attempt had its TEST 1 output truncated/missing entirely. Prefer single-command-per-pod, or a YAML manifest with an explicit wait+log+delete pattern (§9 template).

5. **PSS=restricted requires full securityContext.** The `kubectl run` shortcut passes baseline but fails restricted. Future prod workload manifests must include the full securityContext block as standard.

6. **NetworkPolicy semantics: rules are additive.** Multiple policies on overlapping podSelectors → union of allows (logical OR). Default-deny + allow-dns = "deny everything except DNS". A misauthored rule that opens broader egress would slip past server dry-run; Drill 3b (additivity check) catches it.

7. **`kubernetes.io/metadata.name` is the automatic namespace label (k8s 1.21+).** It is a reliable destination identifier in NetworkPolicy egress rules — preferable over manually-applied labels.

8. **`k8s-app=kube-dns` legacy label is still used by kubeadm CoreDNS.** Backward-compat with the pre-CoreDNS kube-dns era.

9. **Drill 4 (ablation/round-trip) is architecturally important.** State A → B → A confirms reversibility at runtime, not just declaratively. Future-locking: add ablation drills to phase break-it checklists wherever reversibility matters.

10. **External paste discipline (CLAUDE.md §8) must hold during testing.** User-driven test design = stop, articulate the proof goal, let Claude design the drill. Drill 4 + the prod end-to-end test were valuable findings but came via a process violation. Going forward: proof goal user-side, drill design Claude-side.

---

*Runbook owner: Tuhin Zaman · Phase 4 S8 · Bilingual pair: `network-policy-bn.md`*
