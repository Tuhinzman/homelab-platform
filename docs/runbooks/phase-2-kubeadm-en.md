# Phase 2 + 2.5 — Kubernetes Bootstrap + etcd Backup

> **Status:** ✅ Complete  
> **Date:** 2026-04-22  
> **Owner:** Tuhin Zaman  
> **Supersedes:** N/A — first Kubernetes runbook

---

## Goal in one line

Turn 4 VMs into a production-minded Kubernetes cluster using kubeadm, install Calico CNI, and set up automated etcd snapshots every 6 hours.

---

## Why we needed this

After Phase 0 + Phase 1, the network and VM baseline were ready. But those machines were still just standalone Linux servers. To run real workloads, we needed a Kubernetes cluster.

A Kubernetes cluster gives us:

1. **Pod scheduling** — decides which container runs on which node
2. **Self-healing** — restarts crashed pods and reschedules workloads when needed
3. **Service discovery + networking** — pods and services can communicate
4. **Desired state management** — the cluster keeps trying to match the declared state
5. **Cluster state storage** — critical cluster state is stored in etcd

In Phase 2, we intentionally used kubeadm instead of a managed Kubernetes service. The goal was deep understanding: kubelet, container runtime, CNI, kubeadm certificates, control-plane static pods, and node join flow all stay visible.

In Phase 2.5, we added etcd backup. If etcd is corrupted or lost, the Kubernetes API/control plane becomes practically unusable. Without a verified snapshot, recovery is not realistic.

After Phase 2, the cluster was live and ready for Phase 3 add-ons: MetalLB, ingress-nginx, Longhorn, observability, and GitOps.

---

## End State — verified

### Nodes

| Node | Role | IP | Spec |
|---|---|---|---|
| k8s-cp-1 | control-plane | 10.10.0.10 | 4C / 4G / 50G |
| k8s-worker-1 | worker | 10.10.0.21 | 4C / 8G / 80G |
| k8s-worker-2 | worker | 10.10.0.22 | 4C / 8G / 80G |
| k8s-worker-3 | worker | 10.10.0.23 | 2C / 4G / 50G |

### Cluster parameters

| Parameter | Value |
|---|---|
| Kubernetes version | v1.31.14 |
| Bootstrap tool | kubeadm |
| Container runtime | containerd 2.2.3 |
| Cgroup driver | systemd (`SystemdCgroup=true`) |
| CNI | Calico v3.29.3 |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| API endpoint | https://10.10.0.10:6443 |
| etcd snapshot schedule | every 6h |
| etcd snapshot retention | 40 snapshots |
| etcd snapshot behavior | fail-closed, verified before prune |

---

## Architecture — how a kubectl request reaches the apiserver

```text
Mac (kubectl)
   ↓ KUBECONFIG server: https://10.10.0.10:6443
Mac route table: 10.10.0.0/24 → pve-1
   ↓
pve-1 → vmbr1 → k8s-cp-1 (10.10.0.10)
   ↓
kube-apiserver (port 6443, TLS)
   ↓
etcd (cluster state read/write, port 2379)
   ↓
Response: nodes / pods / services / deployments
```

---

## Architecture — how pod-to-pod traffic works

Example:

```text
Pod A on k8s-worker-1 (10.244.230.X)
   ↓
Calico CNI handles pod routing / encapsulation
   ↓
k8s-worker-2
   ↓
Pod B (10.244.140.Y)
```

Important note:

Kubernetes itself does not implement pod networking. Kubelet creates pods, but pod IP allocation and cross-node pod traffic are handled by the CNI plugin. In this cluster, Calico handles that layer.

---

## Architecture — etcd snapshot flow

Every 6 hours:

```text
systemd timer fires
   ↓
etcd-snapshot.service starts
   ↓
/usr/local/sbin/etcd-snapshot.sh runs
   ↓
etcdctl snapshot save → snapshot.tmp
   ↓
etcdutl snapshot status verifies integrity
   ↓
snapshot.tmp renamed to snapshot-<timestamp>.db
   ↓
old snapshots pruned, keeping latest 40
```

Key idea:

Partial or failed backups must never enter the real retention pool.

---

## How each component works — plain English

### kubeadm

**Problem:** Building Kubernetes fully from scratch is painful. You would need to manually configure the apiserver, etcd, controller-manager, scheduler, kubelet, kube-proxy, certificates, static manifests, and bootstrap flow.

**What kubeadm does:**

- `kubeadm init` bootstraps the control plane
- generates Kubernetes certificates
- creates static pod manifests for control-plane components
- creates kubelet config
- `kubeadm join` securely adds worker nodes to the cluster

Why manual kubeadm:

- not managed, so the internals remain visible
- better debugging and interview value
- makes later EKS comparison more meaningful

---

### containerd

**Problem:** kubelet does not run containers directly. It needs a container runtime.

**What containerd does:**

- implements CRI, so kubelet can talk to it
- pulls images
- runs containers/pods
- provides the core runtime behavior without Docker daemon overhead

Critical setting:

```text
SystemdCgroup = true
```

Kubelet and containerd must use the same cgroup driver. If they do not, resource accounting, OOM behavior, pod stats, and stability can become unreliable.

---

### Calico CNI

**Problem:** Pods need IP addresses and must be able to communicate across nodes. Kubernetes core does not do this by itself. A CNI plugin is required.

**What Calico does:**

- assigns pod IPs from Pod CIDR `10.244.0.0/16`
- handles node-to-node pod routing
- works with kube-proxy and Kubernetes service networking
- supports NetworkPolicy, which is needed for later pod-to-pod security work

Install method:

- direct Calico manifest was applied
- Tigera operator was not used

Why direct manifest:

- simpler for a single homelab cluster
- fewer moving parts
- operator is more justified for future production-like or multi-cluster use cases

---

### etcd

**What etcd is:**

etcd is the database for Kubernetes cluster state. Kubernetes API state, node state, pod objects, service objects, config, and metadata are stored there.

Important mental model:

```text
apiserver is mostly stateless
etcd is stateful and critical
```

If etcd is corrupted or lost, the control plane can become unusable. That is why verified snapshot backup is mandatory.

---

### etcd snapshot fail-closed pattern

The snapshot script was designed with these rules:

1. **Atomic write**  
   First write the snapshot to a `.tmp` file. Only after verification passes is it renamed to the final `.db` file.

2. **Fail-closed**  
   If the cert is missing, endpoint is unavailable, verification fails, or disk has a problem, the script exits non-zero and does not perform unsafe cleanup.

3. **Verify before pruning**  
   Old snapshots are deleted only after the new snapshot is proven valid.

4. **Least-privilege cert**  
   It uses the etcd `healthcheck-client` cert, not a full admin cert.

5. **Controlled failure tested**  
   The cert was temporarily renamed to confirm that the script fails safely, leaves no `.tmp` garbage, and does not damage retention.

---

## What we installed/configured

| Item | Value |
|---|---|
| kubeadm/kubelet/kubectl | v1.31.14, apt-mark hold |
| containerd | 2.2.3 from Docker CE repo |
| containerd cgroup driver | systemd |
| Calico | v3.29.3 direct manifest |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| etcdctl/etcdutl | v3.5.24, matching cluster etcd |
| Backup directory | `/var/backups/etcd/` |
| Backup directory permissions | `0700`, `root:root` |
| Backup script | `/usr/local/sbin/etcd-snapshot.sh`, mode `0750` |
| systemd unit | `etcd-snapshot.service` |
| systemd timer | `etcd-snapshot.timer` |
| Timer schedule | `OnBootSec=5min`, `OnUnitActiveSec=6h`, `Persistent=true` |
| Retention | 40 snapshots |
| Cert used | `/etc/kubernetes/pki/etcd/healthcheck-client.{crt,key}` |

---

## Deviations from the original plan

### D1 — Calico install method

- **Plan:** generic `kubectl apply` manifest wording
- **Actual:** direct `calico.yaml` manifest from upstream, not Tigera operator
- **Why:** simpler for homelab single cluster
- **Risk:** upgrades are manual with newer manifest URL
- **Status:** accepted

### D2 — Phase 2.5 backup target location

- **Plan:** snapshot to `svc-1`
- **Actual:** local `/var/backups/etcd/` on `k8s-cp-1`
- **Why:** get a local verified backup first and keep Phase 2 momentum
- **Risk:** control-plane disk loss also loses local snapshots
- **Track:** migrate/copy backups to an external target later, ideally when `svc-1`/backup storage is ready or Phase 13 backup work starts

### D3 — VM disk size

- **Plan/template:** original template disk was too small (`13.5G`)
- **Actual:** resized nodes to `50/80/80/50G`
- **Why:** future OTel Demo + Longhorn + platform components need more space
- **Track:** refresh baseline template to a larger disk, likely 60G minimum

### D4 — Storage backend

- **Plan assumption:** ZFS possible because hardware has 2×1TB NVMe
- **Actual:** local-lvm / LVM-thin on current Proxmox setup
- **Why:** not a Phase 2 blocker
- **Track:** revisit for Longhorn performance, etcd I/O, and future reliability

### D5 — Template missing `conntrack`

- **Caught by:** `kubeadm init --dry-run`
- **Fix:** installed `conntrack` on all 4 Kubernetes nodes
- **Track:** add `conntrack` to template baseline. Phase 3 surfaced more template gaps (`iscsid`, `multipathd`), so fold all into future template refresh

---

## Step-by-step execution

### Section A — Pre-flight

**Run on:** Mac terminal, from `~/Project/homelab`

Checked:

- SSH aliases across lab hosts
- VM CPU/RAM/disk matched the plan
- internet reachability from Kubernetes VMs
- access to `registry.k8s.io`
- disk resize completed: `13.5G → 50/80/80/50G`

Why this mattered:

- kubeadm pulls images
- container runtime needs internet
- future workloads need disk capacity
- SSH alias reliability is mandatory before multi-node execution

---

### Section B — Node prerequisites

**Run on:** Mac terminal using SSH loop across all 4 Kubernetes VMs

Configured/verified on:

```text
k8s-cp-1
k8s-worker-1
k8s-worker-2
k8s-worker-3
```

Tasks:

1. **Swap disabled**  
   Verified no active swap and no `/swap.img` dependency.

2. **Kernel modules loaded + persisted**

   ```text
   overlay
   br_netfilter
   ```

   Persisted in:

   ```text
   /etc/modules-load.d/k8s.conf
   ```

3. **Kubernetes sysctl applied + persisted**

   ```text
   net.bridge.bridge-nf-call-iptables=1
   net.bridge.bridge-nf-call-ip6tables=1
   net.ipv4.ip_forward=1
   ```

   Persisted in:

   ```text
   /etc/sysctl.d/k8s.conf
   ```

4. **containerd installed**  
   Installed from Docker CE repo and configured with:

   ```text
   SystemdCgroup = true
   ```

5. **Kubernetes packages installed**  
   Installed from `pkgs.k8s.io/core:/stable:/v1.31/deb/`:

   ```text
   kubeadm v1.31.14
   kubelet v1.31.14
   kubectl v1.31.14
   ```

   Then held with:

   ```bash
   apt-mark hold kubeadm kubelet kubectl
   ```

6. **conntrack installed**  
   Required by kube-proxy / kubeadm preflight. This was missing from the template.

---

### Section C — Control plane bootstrap

**Run on:** `k8s-cp-1`

Dry-run first:

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --apiserver-advertise-address=10.10.0.10 \
  --dry-run
```

Initial issue:

```text
[ERROR FileExisting-conntrack]
```

Fix:

```text
install conntrack on all nodes
```

Real init after dry-run passed:

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --apiserver-advertise-address=10.10.0.10 \
  | tee ~/kubeadm-init.out
```

Important:

`~/kubeadm-init.out` preserved the worker join command.

---

### Section D — kubeconfig distribution

**Run on:** `k8s-cp-1`

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 0600 ~/.kube/config
```

**Run on:** Mac

```bash
scp k8s-cp-1:~/.kube/config ~/.kube/config-homelab
chmod 0600 ~/.kube/config-homelab
echo 'export KUBECONFIG=$HOME/.kube/config-homelab' >> ~/.zshrc
source ~/.zshrc
kubectl cluster-info
```

Expected:

```text
Kubernetes control plane reachable at https://10.10.0.10:6443
```

---

### Section E — Calico CNI install

**Run on:** Mac terminal

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/calico.yaml

kubectl wait --for=condition=ready pod \
  -l k8s-app=calico-node \
  -n kube-system \
  --timeout=300s
```

Expected:

- `calico-node` pod on each node
- Calico controllers running
- nodes become `Ready`

Note:

Calico v3.29.3 default IP pool matched our planned Pod CIDR: `10.244.0.0/16`.

---

### Section F — Worker join

**Run on:** Mac terminal

Join command came from `~/kubeadm-init.out`.

Example:

```bash
JOIN_CMD='sudo kubeadm join 10.10.0.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>'

for h in k8s-worker-1 k8s-worker-2 k8s-worker-3; do
  ssh "$h" "$JOIN_CMD" &
done
wait

kubectl get nodes
```

Expected:

```text
k8s-cp-1       Ready    control-plane
k8s-worker-1   Ready
k8s-worker-2   Ready
k8s-worker-3   Ready
```

---

### Section G — Phase 2.5 etcd snapshot setup

**Run on:** `k8s-cp-1`

Install etcd tools, matching cluster etcd version:

```bash
ETCD_VER=v3.5.24
curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz \
  | sudo tar xz --strip-components=1 -C /usr/local/bin/ \
    etcd-${ETCD_VER}-linux-amd64/etcdctl \
    etcd-${ETCD_VER}-linux-amd64/etcdutl
```

Create backup directory:

```bash
sudo mkdir -p /var/backups/etcd
sudo chmod 0700 /var/backups/etcd
sudo chown root:root /var/backups/etcd
```

Install script + systemd files:

```bash
sudo install -m 0750 etcd-snapshot.sh /usr/local/sbin/
sudo install -m 0644 etcd-snapshot.service /etc/systemd/system/
sudo install -m 0644 etcd-snapshot.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now etcd-snapshot.timer
```

Validation:

```bash
sudo systemctl list-timers etcd-snapshot.timer --no-pager
sudo /usr/local/sbin/etcd-snapshot.sh
sudo ls -1 /var/backups/etcd/
```

Expected:

- timer active
- manual snapshot exits `0`
- at least one snapshot file exists

---

## Validation Proof

### Cluster smoke test

**Run on:** Mac terminal

```bash
kubectl run smoke-test --image=nginx --restart=Never
kubectl wait pod/smoke-test --for=condition=Ready --timeout=60s
kubectl get pod smoke-test -o wide
kubectl delete pod smoke-test
```

Result:

- pod scheduled successfully
- pod got IP from `10.244.0.0/16`
- CNI working
- scheduler working

---

### etcd snapshot controlled failure drill

**Run on:** `k8s-cp-1`

Break cert intentionally:

```bash
sudo mv /etc/kubernetes/pki/etcd/healthcheck-client.crt \
  /etc/kubernetes/pki/etcd/healthcheck-client.crt.DRILL
```

Run script:

```bash
sudo /usr/local/sbin/etcd-snapshot.sh; echo "exit: $?"
```

Expected:

```text
exit: 13
[ERROR] Missing client cert
```

Verify no damage:

```bash
ls /var/backups/etcd/*.tmp 2>/dev/null
ls /var/backups/etcd/*.db | wc -l
```

Restore cert:

```bash
sudo mv /etc/kubernetes/pki/etcd/healthcheck-client.crt.DRILL \
  /etc/kubernetes/pki/etcd/healthcheck-client.crt
```

Run again:

```bash
sudo /usr/local/sbin/etcd-snapshot.sh; echo "exit: $?"
```

Expected:

```text
exit: 0
```

---

### systemd-level failure test

**Run on:** `k8s-cp-1`

```bash
sudo mv /etc/kubernetes/pki/etcd/healthcheck-client.crt \
  /etc/kubernetes/pki/etcd/healthcheck-client.crt.DRILL

sudo systemctl start etcd-snapshot.service
sudo systemctl status etcd-snapshot.service
sudo journalctl -u etcd-snapshot.service -n 20 | grep ERROR

sudo mv /etc/kubernetes/pki/etcd/healthcheck-client.crt.DRILL \
  /etc/kubernetes/pki/etcd/healthcheck-client.crt
```

Expected:

- service fails with status `13`
- journal captures `[ERROR] Missing client cert`
- cert restored after drill

---

## Failure Story — what can break and how to detect it

| Failure | Symptom | Detection |
|---|---|---|
| `k8s-cp-1` down | `kubectl` timeout | `kubectl cluster-info` fails |
| etcd corruption | apiserver unhealthy / control plane unstable | `kubectl get pods -n kube-system` or static pod logs |
| Calico outage | new pods stuck `ContainerCreating` | `kubectl get pods -n kube-system | grep calico` |
| Snapshot script failure | systemd service failed | `systemctl status etcd-snapshot.service` |
| Snapshot disk full | snapshot fails / write error | journal + `df -h /var/backups/etcd` |
| Cert expiry | cluster/admin operations fail | `kubeadm certs check-expiration` |

---

## Recovery Plans

### Recover from failed snapshot

**Run on:** `k8s-cp-1`

```bash
sudo journalctl -u etcd-snapshot.service -n 50
sudo /usr/local/sbin/etcd-snapshot.sh; echo $?
sudo systemctl reset-failed etcd-snapshot.service
```

Process:

1. Read journal
2. Identify exit code/root cause
3. Fix issue: cert path, disk space, endpoint, permission
4. Run manual snapshot
5. Reset failed state

---

### Restore etcd from snapshot

⚠️ **Not executed in Phase 2.** This is documented for Phase 13 restore drill.

**Run on:** `k8s-cp-1`

```bash
sudo kubectl -n kube-system get pod etcd-k8s-cp-1 -o yaml > /tmp/etcd-pod-backup.yaml
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sudo mv /var/lib/etcd /var/lib/etcd.old

sudo etcdutl snapshot restore /var/backups/etcd/snapshot-<TS>.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-cp-1 \
  --initial-cluster=k8s-cp-1=https://10.10.0.10:2380 \
  --initial-advertise-peer-urls=https://10.10.0.10:2380

sudo mv /tmp/etcd.yaml /etc/kubernetes/manifests/
```

Important:

Do not treat this as a casual command. It is a restore drill procedure and must be performed with a controlled maintenance window.

---

### Rebuild a worker

**Run on broken worker:**

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F
```

**Run on:** `k8s-cp-1`

```bash
sudo kubeadm token create --print-join-command
```

Then run the generated join command on the worker.

---

### Regenerate join token

**Run on:** `k8s-cp-1`

```bash
sudo kubeadm token create --print-join-command
```

Use this when the original join token expires. kubeadm tokens are time-limited.

---

## Common Pitfalls — actually hit or explicitly guarded against

| Pitfall | Symptom | Fix |
|---|---|---|
| `conntrack` missing in template | `kubeadm init` preflight error | Install `conntrack` on each node |
| containerd cgroup driver mismatch | kubelet/container runtime instability | Set `SystemdCgroup = true` |
| swap not disabled | kubelet refuses to start | Disable swap and remove from `/etc/fstab` |
| `br_netfilter` not loaded | pod/service networking issues | Persist in `/etc/modules-load.d/k8s.conf` |
| Calico IPPool wrong CIDR | pods get IP outside planned range | verify Calico pool matches `10.244.0.0/16` |
| join token expired | worker join fails | regenerate with `kubeadm token create --print-join-command` |
| wrong etcd cert | snapshot auth fails | use `healthcheck-client.crt/key` |
| snapshot disk fill | snapshot fails or partial write risk | retention=40 + verify + fail-closed behavior |

---

## Break-it Drills Executed in Phase 2.5

- [x] Snapshot with cert missing → verified fail-closed behavior
- [x] systemd-triggered snapshot failure → verified failed service state + journal capture

Deferred to Phase 13:

- [ ] Full etcd restore drill
- [ ] Control plane rebuild drill
- [ ] Worker rebuild drill

Deferred to Phase 4:

- [ ] Cert rotation drill
- [ ] API server down drill

Note:

Phase 3 later revisited the “drills deferred” rule and completed three break-it drills for MetalLB, ingress-nginx, and Longhorn.

---

## Files committed in this phase

```text
infrastructure/etcd-backup/
├── etcd-snapshot.sh                    # /usr/local/sbin/etcd-snapshot.sh
├── etcd-snapshot.service               # /etc/systemd/system/etcd-snapshot.service
└── etcd-snapshot.timer                 # /etc/systemd/system/etcd-snapshot.timer

docs/runbooks/
├── phase-2-kubeadm-bn.md               # Bangla runbook
└── phase-2-kubeadm-en.md               # English runbook
```

---

## Exit Criteria — all passed

- [x] 4 nodes Ready: `kubectl get nodes`
- [x] all `kube-system` pods Running
- [x] pod IP allocation from planned CIDR `10.244.0.0/16` verified
- [x] Mac kubectl access working
- [x] worker join completed successfully
- [x] Calico running on all nodes
- [x] etcd snapshot script works manually
- [x] etcd snapshot systemd timer active
- [x] snapshot failure path verified at script level
- [x] snapshot failure path verified at systemd level
- [x] runbook committed
- [x] Git tag `phase-2-complete`

---

## Final understanding

Phase 2 converted standalone VMs into a real Kubernetes cluster.

You built:

1. **Control plane** with kubeadm
2. **Worker node join flow** with kubeadm token discovery
3. **Container runtime** with containerd
4. **Pod networking** with Calico
5. **Mac admin access** with kubeconfig
6. **Cluster state protection** with automated etcd snapshots

Without this phase, Phase 3 add-ons like MetalLB, ingress-nginx, and Longhorn would have nowhere to run.

---

*Phase 2 + 2.5 complete. Move on to Phase 3 — MetalLB + ingress-nginx + Longhorn.*