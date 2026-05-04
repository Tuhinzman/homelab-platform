# Phase 3 — Networking + Storage Foundation

> **Status:** ✅ Complete
> **Date:** 2026-04-24
> **Cluster:** kubeadm v1.31.14, 4 nodes, Calico v3.29.3
> **Components added:** MetalLB, ingress-nginx, Longhorn

---

## Goal in one line

Make the cluster ready to run real workloads — add a system to give external IPs (MetalLB), HTTP routing (ingress-nginx), and persistent storage (Longhorn). All three installed manually with Helm.

## Why we needed this

After Phase 2 the cluster was running, but no real app could be deployed because:

1. **No external access** — creating a `type: LoadBalancer` service would just sit `<pending>` (bare-metal has no cloud provider like AWS to hand out IPs)
2. **No HTTP routing** — no way to reach an app by domain name
3. **No persistent storage** — pod delete meant data gone, no PVC could bind

Phase 3 solves all three. The cluster is now ready for Phase 5+ (GitLab, ArgoCD, observability stack, OTel Demo).

---

## What we installed

| Tool | Version | Job |
|---|---|---|
| **MetalLB** | 0.15.3 | Gives LoadBalancer IPs on bare-metal (does what AWS Load Balancer Controller does in cloud) |
| **ingress-nginx** | 4.15.1 (controller v1.15.1) | HTTP/HTTPS routing — maps domain name to service |
| **Longhorn** | 1.11.1 | Distributed block storage — PVCs get provisioned automatically |

---

## Architecture — how a request flows end-to-end

```
Your Mac browser
   ↓ (http://drill.lab)
Mac route table: 10.10.0.0/24 → pve (192.168.68.200)
   ↓
pve nftables FORWARD rule
   ↓
Lab subnet 10.10.0.0/24 → MetalLB IP 10.10.0.200
   ↓
MetalLB speaker helps the node advertise the IP
Actual ARP/data handling stays at the node kernel level
   ↓
ingress-nginx pod (k8s-worker-3) receives the packet
   ↓
Match Host header "drill.lab" → backend service
   ↓
Service ClusterIP → pod IP (kube-proxy iptables)
   ↓
nginx pod serves /usr/share/nginx/html/index.html
   ↓
File comes from Longhorn PVC (replica on worker-1 + worker-2)
```

**Worth remembering:** three components, three layers. If one is down the others may still work, but the end-to-end request fails.

---

## How each component works — in plain words

### MetalLB

**The problem:** On bare-metal, `type: LoadBalancer` service stays `<pending>` forever — because nobody is allocating external IPs.

**MetalLB's solution:**
1. Define an **IP pool** (10.10.0.200 to 10.10.0.220)
2. When someone creates a `type: LoadBalancer` service, MetalLB hands out an IP from the pool
3. **Speaker pod** (DaemonSet, one per node) helps the node advertise that IP — actual ARP/data handling stays at the kernel level
4. **Controller pod** manages the pool and decides leader election

**In L2 mode:** the IP is announced through ARP. Devices in the same broadcast domain learn where that IP should go. The speaker is not in the data path; packet forwarding happens through the node/kernel and kube-proxy.

### ingress-nginx

**The problem:** Remembering service IPs is impossible. We want to reach apps by domain name.

**ingress-nginx's solution:**
1. Controller pod (pinned to worker-3) listens on HTTP/HTTPS
2. We define an **Ingress object** mapping domain → service:
   ```yaml
   host: drill.lab
   backend: service/drill-app
   ```
3. When a request arrives, controller looks at the Host header → forwards to the matching backend
4. Service ClusterIP → kube-proxy iptables → pod IP

### Longhorn

**The problem:** Pod delete used to mean data loss. No dynamic PVC provisioning.

**Longhorn's solution:**
1. **longhorn-manager** (DaemonSet on every node) tracks cluster-wide storage state
2. **engine-image** (DaemonSet) provides the actual data-plane container
3. **instance-manager** runs the actual storage processes (engine + replicas)
4. When a PVC is created:
   - A volume is created (1 engine + 2 replicas in our config)
   - The engine pod serves the data path
   - Replicas keep a copy of the data on two different nodes
5. When a pod mounts the PVC → CSI driver → Longhorn engine → iSCSI block device → ext4 filesystem

---

## What got installed — exact pods

```
metallb-system:        1 controller + 4 speakers (DaemonSet)
ingress-nginx:         1 controller (pinned to worker-3)
longhorn-system:       ~22 pods total
                       - 3 longhorn-manager (all schedulable nodes; cp skipped because it is tainted)
                       - 3 engine-image (workers)
                       - 3 instance-manager (workers)
                       - 3 longhorn-csi-plugin (workers)
                       - 2 csi-attacher
                       - 2 csi-provisioner
                       - 2 csi-resizer
                       - 2 csi-snapshotter
                       - 1 longhorn-driver-deployer
                       - 1 longhorn-ui
```

---

## Locked decisions (choices made in Phase 3 that won't change later)

### MetalLB
- **L2 mode** (instead of BGP) — BGP is overkill for homelab, L2 is enough
- **IP pool: 10.10.0.200–10.10.0.220** — 21 IPs, isolated lab subnet
- **autoAssign: true** — services get auto-assigned IPs unless they ask for a specific one

### ingress-nginx
- **Single replica** — Phase 3 scope, HA in Phase 4+
- **Pinned to k8s-worker-3** — `nodeSelector: ingress-ready=true`
- **LoadBalancer IP: 10.10.0.200** — pinned via `metallb.io/loadBalancerIPs` annotation
- **externalTrafficPolicy: Local** — preserves client source IP, advertises only from nodes that have endpoints
- **IngressClass `nginx`** = default (annotation `is-default-class=true`)

### Longhorn
- **defaultReplicaCount: 2** — homelab-sized, not the default 3
- **Failure limit:** replica=2 can survive 1 node/replica failure; losing 2 node/data replicas at the same time can cause data loss
- **Default StorageClass: longhorn**
- **ReclaimPolicy: Delete** — deleting a PVC also deletes the volume (homelab; production would use Retain)
- **storageOverProvisioningPercentage: 100** — no oversubscription, disk safety
- **storageMinimalAvailablePercentage: 25** — keep 25% disk free as buffer

---

## Step-by-step what we did

### T0 — Helm + repos (Mac)
```bash
brew install helm                  # already installed, version 4.1.4
helm repo add metallb https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

### T1 — MetalLB install
```bash
kubectl create namespace metallb-system
kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged ...
helm install metallb metallb/metallb --namespace metallb-system --version 0.15.3 --wait
```

Then apply the IPAddressPool + L2Advertisement manifest:
```yaml
# manifests/phase-3/metallb/ipaddresspool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses: ["10.10.0.200-10.10.0.220"]
  autoAssign: true
  avoidBuggyIPs: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools: ["lab-pool"]
```

**Verify:** test deployment → `type: LoadBalancer` → IP `10.10.0.200` assigned, HTTP 200 from Mac.

### T2 — ingress-nginx install

Pre-step: label worker-3
```bash
kubectl label node k8s-worker-3 ingress-ready=true --overwrite
```

values.yaml:
```yaml
controller:
  nodeSelector:
    ingress-ready: "true"
  replicaCount: 1
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
    annotations:
      metallb.io/loadBalancerIPs: "10.10.0.200"
  ingressClassResource:
    name: nginx
    enabled: true
    default: true
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { memory: 256Mi }
  metrics:
    enabled: true
defaultBackend:
  enabled: false
```

Install:
```bash
kubectl create namespace ingress-nginx
kubectl label namespace ingress-nginx pod-security.kubernetes.io/enforce=baseline ...
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --version 4.15.1 \
  --values values.yaml --wait
```

### T3 — Longhorn prerequisites + install

**Fix prerequisites on all 3 workers:**
```bash
for h in k8s-worker-1 k8s-worker-2 k8s-worker-3; do
  ssh "$h" "
    sudo systemctl enable --now iscsid
    sudo systemctl stop multipathd.service multipathd.socket
    sudo systemctl disable multipathd.service multipathd.socket
    sudo systemctl mask multipathd.service multipathd.socket
  "
done
```

**Why:**
- `iscsid` was installed but disabled — Longhorn uses iSCSI to mount volumes; without it, PVCs will not bind
- `multipathd` was running — it grabs Longhorn iSCSI devices and breaks volumes; disabling is the right call

**Longhorn Helm install** with values.yaml (defaultReplicaCount: 2 etc.) — see manifests folder.

---

## Deviations recorded

### D6 — ingress-nginx EOL accepted (NEW)
- ingress-nginx project upstream maintenance ended **March 2026**
- 7 weeks past EOL when we installed
- **Why accepted:** isolated homelab learning, no public exposure, lab network isolated (10.10.0.0/24)
- **Migration target:** Gateway API (likely Envoy Gateway), naturally fits at Phase 16 (EKS + ALB Controller) or earlier if needed
- **Not recommended for new production deployments post-2026** — outside learning/legacy context, Gateway API is the better direction

### Hardening template gaps (to fix in Phase 4 template refresh)
- `iscsid` not enabled by default → make it enabled in baseline VM 9001
- `multipathd` running by default → remove or mask in baseline
- Add `nfs-common` to baseline (already present, but confirm in checklist)

---

## Break-it drills (validation)

For each drill: kill something, measure time, observe recovery, document.

### Drill 1 — ingress-nginx pod kill

**What we did:** `kubectl delete pod` on the controller.

**Results:**
- Time to recovery: **~12s** (kill → new pod Ready)
- Failure window: **~8.5s** (17 non-200 probes × 0.5s)
- First failure: HTTP 000 (connection refused)
- MetalLB IP retained: `10.10.0.200` ✅
- New pod placed correctly on worker-3 (nodeSelector working) ✅
- PVC content unchanged ✅

**Lesson:** Stateless controllers self-heal cleanly. Single replica = brief outage during respawn. Phase 4+ should add 2 replicas + PodDisruptionBudget for zero-downtime.

### Drill 2 — Longhorn replica node failure (cordon + instance-manager kill)

**What we did:** Cordoned worker-2, force-deleted instance-manager pod on worker-2.

**Results:**
- Time to detect degraded: **~21s**
- Replica rebuild time after uncordon: **~42s**
- HTTP failures: **0/63 probes** ✅
- App stayed up throughout ✅
- PVC content unchanged ✅

**Lesson:** Replicated storage works as designed. Single replica failure is invisible to the app — engine + remaining replica served everything. Replica auto-rebuilt when the node returned. Production tip: alert when `degraded` lasts more than 2 min.

### Drill 3 — MetalLB speaker pod kill (leader for `.200`)

**What we did:** `kubectl delete pod --grace-period=0 --force` on the leader speaker (worker-3). Cleared Mac ARP cache before the kill.

**Results:**
- Pod respawn time: **~20.5s**
- HTTP failures: **0/86 probes** ✅
- Leader stayed on worker-3 (DaemonSet respawned in place)

**Important nuance:** 0 failures despite a 20.5s pod outage looks like magic, but here's why —
- Speaker pod uses `hostNetwork: true` → IP is bound to node-level kernel state
- Speaker's actual job = ARP control plane (initial claim + GARP retransmit)
- **Speaker is NOT in the data path** — packets flow through kube-proxy iptables, which doesn't depend on the speaker
- Mac's earlier ARP resolution → packets kept arriving at worker-3 → kube-proxy DNAT → ingress-nginx pod (also on worker-3) → success

**What would actually break things:**
- Whole node failure (kernel state lost)
- If the node fails, ARP ownership has to move to another node; brief downtime is expected during re-announcement
- Mac ARP cache expiry mid-outage with no speaker to re-claim
- L2Advertisement node selector forcing migration to a different node

**Lesson:** MetalLB L2 mode is resilient to speaker pod respawn (kernel state survives), but vulnerable to node failure (state goes down with the node). Phase 4+ multi-replica ingress on multiple nodes will give true HA.

---

## Common pitfalls hit + fixes

### 1. macOS LaunchDaemon route timing
**Symptom:** `kubectl` timeout, route to `10.10.0.0/24` going via wrong gateway.

**Cause:** LaunchDaemon `RunAtLoad` fires before Wi-Fi associates → `route add` silently fails → boot exit code 0 but route not added.

**Fix:** Helper script with retry loop until gateway is reachable:
```sh
#!/bin/sh
GATEWAY="192.168.68.200"; NET="10.10.0.0/24"
for i in $(seq 1 30); do
  if /sbin/ping -c 1 -t 1 "$GATEWAY" >/dev/null 2>&1; then
    /sbin/route -n delete -net "$NET" >/dev/null 2>&1
    /sbin/route -n add -net "$NET" "$GATEWAY"
    exit 0
  fi
  sleep 2
done
exit 1
```

Plus `WatchPaths` on `/etc/resolv.conf` for sleep/wake recovery.

**VPN note:** VPN connect/disconnect can change the route table. After turning on VPN, verify the gateway with `route -n get 10.10.0.10`.

### 2. `/usr/local/sbin` doesn't exist on Apple Silicon
**Symptom:** `tee: /usr/local/sbin/...: No such file or directory`.

**Fix:** `sudo mkdir -p /usr/local/sbin` first.

### 3. zsh glob conflict with kubectl jsonpath
**Symptom:** `zsh: no matches found: custom-columns=...[?(@.type=="Ready")]...`

**Cause:** zsh's extended globbing treats `[?(...)` as a literal pattern.

**Fix:** Single-quote the entire `-o` argument:
```bash
kubectl get nodes.longhorn.io -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

### 4. macOS BSD `date` doesn't support `%N`
**Symptom:** `date +%H:%M:%S.%3N` outputs `00:48:25.3N` (literal `3N`).

**Cause:** `%N` (nanoseconds) is GNU date only; BSD date (macOS default) doesn't have it.

**Fix:** Python one-liner for portable ms:
```bash
ts() { python3 -c 'import datetime;print(datetime.datetime.utcnow().strftime("%H:%M:%S.")+f"{datetime.datetime.utcnow().microsecond//1000:03d}")'; }
```

### 5. Init container missing volumeMount
**Symptom:** Pod stuck `Init:Error`, exit code 1, message `sh: can't create /data/index.html: No such file or directory`.

**Cause:** Init container needs its own `volumeMounts:` block — the main container's mount doesn't carry over to init.

**Fix:** Add `volumeMounts` to BOTH init and main containers:
```yaml
initContainers:
  - name: seed
    volumeMounts:
      - { name: content, mountPath: /data }   # ← writable for init
containers:
  - name: nginx
    volumeMounts:
      - { name: content, mountPath: /usr/share/nginx/html, readOnly: true }
```

### 6. Pod readinessProbe too aggressive
**Symptom:** Pod `Running 0/1`, deployment never reaches Available.

**Cause:** `initialDelaySeconds: 0` + `periodSeconds: 2` + `failureThreshold: 2` = pod marked unhealthy before nginx can start serving.

**Fix:** Reasonable defaults:
```yaml
readinessProbe:
  httpGet: { path: /, port: 80 }
  initialDelaySeconds: 3
  periodSeconds: 5
  failureThreshold: 3
```

### 7. ingress-nginx returns 404 for new Ingress
**Symptom:** Ingress created, controller picked it up, but HTTP returns 404.

**Cause:** Backend service has no Ready endpoints yet (pod still starting). Depending on ingress-nginx version/config, this may show as 404 or 503. The root cause is the same: the backend endpoint is not ready.

**Fix:** Always `kubectl wait deployment` before HTTP test.

### 8. PVC delete async cleanup
**Symptom:** PVC deleted, but `kubectl get volumes.longhorn.io` still shows the orphan attached for 30–60s.

**Cause:** Longhorn's volume lifecycle (detach → delete → garbage collect) is async.

**Fix:** Sleep 30–60s before asserting "clean state". For scripted teardowns, poll the CRD.

---

## How to recover from common failures

### "kubectl timeout" from Mac
```bash
# 1. Check route
route -n get 10.10.0.10 | grep gateway   # should be 192.168.68.200, not the home router
# 2. Re-add manually
sudo route -n add -net 10.10.0.0/24 192.168.68.200
# 3. Check LaunchDaemon health
sudo launchctl print system/com.tuhin.homelab.route | grep "exit code"
# 4. Re-bootstrap if needed
sudo launchctl bootout system/com.tuhin.homelab.route
sudo launchctl bootstrap system /Library/LaunchDaemons/com.tuhin.homelab.route.plist
```

### "No external IP" for LoadBalancer service
```bash
# 1. MetalLB pods running?
kubectl get pods -n metallb-system
# 2. Pool exists?
kubectl get ipaddresspool -n metallb-system
# 3. L2Advertisement bound to pool?
kubectl get l2advertisement -n metallb-system
# 4. Pool not exhausted?
kubectl get ipaddresspool lab-pool -n metallb-system -o jsonpath='{.status}'
```

### Ingress returns 404
```bash
# 1. Backend has endpoints?
kubectl get endpoints <service-name>
# 2. Pod actually Ready?
kubectl get pod -l <selector>
# 3. Controller observed the Ingress?
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=50 | grep <host>
```

### PVC stuck Pending
```bash
# 1. SC default?
kubectl get sc
# 2. Longhorn nodes Ready?
kubectl get nodes.longhorn.io -n longhorn-system
# 3. Provisioner running?
kubectl get pod -n longhorn-system -l app=csi-provisioner
# 4. Detailed events
kubectl describe pvc <name>
```

### Pod stuck ContainerCreating with PVC
```bash
# 1. Volume actually attached?
kubectl get volumes.longhorn.io -n longhorn-system
# 2. iscsid running on the host?
NODE=$(kubectl get pod <pod> -o jsonpath='{.spec.nodeName}')
ssh "$NODE" "sudo systemctl status iscsid"
# 3. iscsi_tcp module loaded?
ssh "$NODE" "lsmod | grep iscsi"
# 4. Pod events
kubectl describe pod <pod> | tail -30
```

---

## Files committed in this phase

```
manifests/phase-3/
├── metallb/
│   └── ipaddresspool.yaml
├── ingress-nginx/
│   └── values.yaml
├── longhorn/
│   └── values.yaml
├── storage-test/
│   ├── pvc-test.yaml
│   └── integration-test.yaml
└── drills/
    └── drill-app.yaml

docs/runbooks/
├── phase-3-bn.md        ← Bangla runbook
├── phase-3-en.md        ← English runbook
└── phase-3/
    └── drills/
        ├── drill-1-ingress-pod-kill.log
        ├── drill-2-longhorn-replica-fail.log
        └── drill-3-metallb-speaker-kill.log
```

---

## Success criteria — final check

- [x] `kubectl get svc -A` → no LoadBalancer service stays `<pending>`
- [x] `curl http://10.10.0.200` → ingress-nginx 404 default backend
- [x] `kubectl get pods -n ingress-nginx -o wide` → only on `k8s-worker-3`
- [x] Test PVC `Bound`, replica count = 2
- [x] End-to-end: Mac → MetalLB → Ingress → Service → Pod → PVC works
- [x] 3 break-it drills passed
- [x] Bangla + English runbooks committed
- [x] D6 logged in commit body

---

## Phase 4 prerequisites that came up here

- VM 9001 hardening template needs: `iscsid enabled`, `multipathd masked`, `conntrack` package
- Disk size baseline 60G (current template 13.5G is too small for full Phase 12 OTel Demo)
- 2-replica ingress + PDB pattern when adding more nodes
- DNS server (Pi-hole/dnsmasq on svc-1) — currently using `Host:` header workaround
- TLS via cert-manager — currently HTTP only

---

*Document owner: Tuhin Zaman · Phase 3 closed · English runbook · Tag: phase-3-complete*
