# Progress Log

## Day 4 — April 3, 2026
**Goal:** GitHub repo bootstrap, documentation baseline, Mac kubectl access, namespace validation, mini app deployment, Service validation, and controlled break/fix testing
**Status:** Complete

### Completed
- Bootstrapped `homelab-platform` GitHub repository
- Backfilled Day 1 to Day 3 as logical commits
- Created tag `v0.1-k8s-cluster-ready`
- Verified Mac `kubectl` access
- Verified `dev` and `prod` namespaces
- Reorganized repo structure: `kubernetes/apps/nginx-test/`
- Added `service.yaml` to align repo state with cluster state
- Verified Deployment, Service, and Endpoints in `dev`
- Ran controlled break scenario: Service selector mismatch
- Debugged empty endpoints condition and restored traffic flow
- Wrote debug playbook: `docs/debug/services.md`

### Key Lessons
- Pods Running does not mean traffic is flowing
- Always check endpoints first: `kubectl get endpoints <svc> -n <namespace>`
- A Service can exist with a valid ClusterIP and still have no backend targets
- Repo state and cluster state must stay aligned

---

## Day 3 — April 2, 2026
**Goal:** Kubernetes cluster initialization and validation
**Result:** 3-node cluster fully validated. CoreDNS working, cluster networking functional, cross-node pod-to-pod communication verified.
**Tag:** `v0.1-k8s-cluster-ready`

## Day 2 — April 2, 2026
**Goal:** Worker node join and cluster networking
**Result:** `mk-worker-1` and `mk-worker-2` joined successfully. Calico CNI installed.

## Day 1 — April 2, 2026
**Goal:** Proxmox VM provisioning and network design
**Result:** Base infrastructure prepared. Lab network established. Kubernetes nodes provisioned and reachable by SSH.

---

## Day 5 — Next Session
**Goal:** CoreDNS break scenario, Service discovery debugging, stronger production-style workload validation
**Starting point:** Cluster healthy, `nginx-test` running in `dev`, repo and cluster state aligned
