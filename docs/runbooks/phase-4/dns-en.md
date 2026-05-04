# Phase 4 — DNS Foundation (Session 1)

**Date:** 2026-04-25
**Phase:** 4 (Security Foundation) — Session 1 of N
**Scope this session:** DNS layer for the entire lab — CoreDNS forwarder, svc-1 authoritative dnsmasq, macOS per-domain resolver
**Status:** ✅ Complete — `*.lab` resolution proven from pods, Mac, and svc-1 itself
**Companion file:** [`dns-bn.md`](./dns-bn.md) (Bangla parallel)

---

## 1. Goal

Establish a single, opinionated DNS resolution path for the homelab so that every consumer (cluster pods, Mac workstation, svc-1 itself, future ingress URLs) can reach `*.lab` hostnames without `Host:` header workarounds.

Specific success criteria:

- A pod inside the cluster resolves `grafana.lab → 10.10.0.200`
- The Mac resolves `gitlab.lab → 10.10.0.30` from any application (browser, curl, kubectl future use of `cp.lab:6443`)
- svc-1 itself resolves `*.lab` via its own dnsmasq (loopback)
- Non-`*.lab` queries continue to use upstream public DNS unchanged
- CoreDNS cluster DNS for `*.svc.cluster.local` continues to work (no regression)

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Mac (workstation)                                               │
│                                                                 │
│   App / browser / curl / kubectl                                │
│       │                                                         │
│       ▼                                                         │
│   /etc/resolver/lab    →  nameserver 10.10.0.50                 │
│   (any other query)    →  ISP DNS via DHCP                      │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼  (10.10.0.50:53)
┌─────────────────────────────────────────────────────────────────┐
│ Pod (in cluster)                                                │
│                                                                 │
│   App                                                           │
│       │                                                         │
│       ▼                                                         │
│   Pod /etc/resolv.conf  →  nameserver 10.96.0.10 (CoreDNS svc)  │
│       │                                                         │
│       ▼                                                         │
│   CoreDNS (kube-system)                                         │
│       ├──── *.cluster.local       → kubernetes plugin           │
│       ├──── *.lab                 → forward to 10.10.0.50       │
│       └──── (everything else)     → forward to /etc/resolv.conf │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼  (10.10.0.50:53)
┌─────────────────────────────────────────────────────────────────┐
│ svc-1 (10.10.0.50) — DNS authority                              │
│                                                                 │
│   dnsmasq                                                       │
│     listen-address=10.10.0.50,127.0.0.1                         │
│     local=/lab/   ← authoritative for `lab` zone                │
│     │                                                           │
│     ├── address=/gitlab.lab/10.10.0.30      (explicit, direct)  │
│     ├── address=/cp.lab/10.10.0.10          (explicit, direct)  │
│     ├── address=/svc.lab/10.10.0.50         (explicit, direct)  │
│     ├── address=/pve.lab/192.168.68.200     (explicit, direct)  │
│     ├── address=/.lab/10.10.0.200           (ingress fallback)  │
│     │                                                           │
│     └── server=1.1.1.1 / server=8.8.8.8     (non-lab forward)   │
└─────────────────────────────────────────────────────────────────┘
```

### Zone design rules (locked)

1. **Direct records are explicit; ingress records are wildcard-driven.** Hostnames that bypass ingress-nginx and go directly to a VM/IP (`gitlab.lab`, `cp.lab`, `svc.lab`, `pve.lab`) get explicit A records. Browser-facing apps that go through ingress-nginx (`grafana.lab`, `argocd.lab`, `prometheus.lab`, future app hostnames) resolve through the default wildcard `*.lab → 10.10.0.200`. Add an explicit override only if an ingress hostname needs a non-default IP.
2. **Direct vs ingress-routed records are separated.** Direct infrastructure hostnames go to their own host IPs. Ingress-routed hostnames use the wildcard to reach the MetalLB ingress IP `10.10.0.200`. This avoids duplicate DNS answers.
3. **No `.local` suffix.** mDNS / Avahi conflicts ruled out by using `.lab` (RFC 6762 reserves `.local` for mDNS).
4. **Single source of truth: `/etc/dnsmasq.d/lab.conf`** on svc-1. Tracked in Git as `manifests/phase-4/dns/svc-1-dnsmasq-lab.conf`.

### Why this design vs alternatives

| Alternative | Why rejected |
|---|---|
| Pi-hole on svc-1 | UI overhead unjustified at lab scale; config-as-code purity preferred |
| Route DNS through Tailscale MagicDNS | Couples DNS lifecycle to Tailscale uptime; off-LAN drill exposed Tailscale fragility |
| `/etc/hosts` on every node + Mac | Doesn't scale; doesn't help pods at all |
| External DNS (Route53) for `lab` zone | Air-gapped lab principle violated; cost; latency |

---

## 3. Implementation steps

### 3.1 svc-1 — install dnsmasq

```
[svc-1]
sudo apt-get install -y dnsmasq
```

**Observed conflict and final state:**
- Initial state had `systemd-resolved` active and holding `127.0.0.53:53` / `127.0.0.54:53`.
- dnsmasq initially failed with: `failed to create listening socket for port 53: Address already in use`.
- Final fix: set `DNSStubListener=no`, restart `systemd-resolved`, then rewrite `/etc/resolv.conf` as a regular file using `nameserver 127.0.0.1`.
- Final state: dnsmasq owns `127.0.0.1:53` and `10.10.0.50:53`; svc-1 itself also uses local dnsmasq.

If a fresh node hits a port 53 conflict:

```text
[svc-1]
sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak.$(date +%Y%m%d)
sudo vi /etc/systemd/resolved.conf
# Set this inside the [Resolve] section:
# DNSStubListener=no
sudo systemctl restart systemd-resolved
sudo ss -tlnup 'sport = :53'
```

### 3.2 svc-1 — write the canonical dnsmasq config

Stored in Git at `manifests/phase-4/dns/svc-1-dnsmasq-lab.conf`. Deployed to `/etc/dnsmasq.d/lab.conf` on svc-1.

Key directives (full file in manifests):
- `listen-address=10.10.0.50,127.0.0.1` — never bind to `0.0.0.0` (security)
- `bind-interfaces` — strict interface binding
- `local=/lab/` — authoritative for `lab` zone, never forwards `.lab` upstream
- `address=/<direct-host>.lab/<ip>` lines — direct infrastructure hostnames only (`gitlab`, `cp`, `svc`, `pve`)
- `address=/.lab/10.10.0.200` — default fallback for all ingress-routed hostnames
- `no-resolv` + `server=1.1.1.1` + `server=8.8.8.8` — explicit upstreams, not from `/etc/resolv.conf`
- `cache-size=1000`, `log-queries`, `log-facility=/var/log/dnsmasq.log` — operational visibility

### 3.3 svc-1 — validate and restart

```
[svc-1]
sudo dnsmasq --test --conf-file=/etc/dnsmasq.conf   # syntax check
sudo systemctl restart dnsmasq
sudo ss -tlnup 'sport = :53'                        # confirm bind
dig @127.0.0.1 grafana.lab +short                   # local test
dig @127.0.0.1 archive.ubuntu.com +short            # upstream forward test
```

### 3.4 svc-1 — point itself at its own dnsmasq

```
[svc-1]
sudo cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s)
sudo tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 127.0.0.1
options edns0 trust-ad
EOF
getent hosts grafana.lab        # validates via NSS chain
```

### 3.5 Mac — per-domain resolver

```
[Mac terminal]
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/lab > /dev/null <<'EOF'
nameserver 10.10.0.50
EOF
scutil --dns | grep -A3 "domain.*lab"
dscacheutil -q host -a name grafana.lab    # validates macOS resolver chain
```

**Important:** Use `dscacheutil`, NOT `dig`, to verify. `dig` bypasses macOS's per-domain resolver mechanism.

### 3.6 Cluster — CoreDNS Corefile patch

Add a new `lab:53` server block while leaving the existing `.:53` block unchanged. The `lab:53` block is placed at the top for readability; CoreDNS handles the more-specific `lab` zone separately. The root forwarder (`forward . /etc/resolv.conf`) is not touched, which reduces cluster-wide blast radius.

**Full patched Corefile is in `manifests/phase-4/dns/coredns-corefile.yaml`.**


Use the file-based apply path for repeatability:

```text
[Mac terminal]
# 1. Backup current ConfigMap (rollback path)
mkdir -p /tmp/phase-4-coredns
kubectl -n kube-system get cm coredns -o yaml > /tmp/phase-4-coredns/backup-$(date +%s).yaml

# 2. Apply the patched CoreDNS ConfigMap from Git
kubectl apply -f manifests/phase-4/dns/coredns-corefile.yaml

# 3. Verify lab:53 block is present
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'

# 4. Restart CoreDNS to load the config immediately
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns --timeout=90s
```

**Session note:** The first `kubectl edit` attempt failed with `no original object found`; the saved temp YAML was then applied successfully. For the runbook, file-based `kubectl apply -f manifests/phase-4/dns/coredns-corefile.yaml` is the preferred repeatable path.

### 3.7 Functional validation from pods

```
[Mac terminal]
kubectl run dns-final --image=busybox:1.36 --restart=Never --rm -it --timeout=60s -- sh -c '
  nslookup kubernetes.default.svc.cluster.local
  nslookup grafana.lab
  nslookup gitlab.lab
  nslookup nonexistent-svc.lab
  nslookup google.com
'
```

---

## 4. Validation (commands + outputs from this session)

### svc-1 — dnsmasq local

```
$ dig @127.0.0.1 grafana.lab +short
10.10.0.200       # wildcard ingress fallback

$ dig @127.0.0.1 cp.lab +short
10.10.0.10

$ dig @127.0.0.1 totally-random.lab +short
10.10.0.200       # wildcard fallback

$ getent hosts grafana.lab
10.10.0.200     grafana.lab
```

### Mac — per-domain resolver

```
$ dscacheutil -q host -a name grafana.lab
name: grafana.lab
ip_address: 10.10.0.200

$ scutil --dns | grep -A3 "domain.*lab"
  domain   : lab
  nameserver[0] : 10.10.0.50
  flags    : Request A records
  reach    : 0x00000003 (Reachable,Transient Connection)
```

### Cluster — pod DNS

```
$ kubectl run dns-final ...
--- LAB ZONE — explicit record ---
Name:    grafana.lab
Address: 10.10.0.200

Name:    gitlab.lab
Address: 10.10.0.30

--- LAB ZONE — wildcard fallback ---
Name:    nonexistent-svc.lab
Address: 10.10.0.200

--- EXTERNAL (control) ---
Name:    google.com
Address: 142.251.211.174
```

### svc-1 dnsmasq query log (proves end-to-end chain)

```
Apr 25 15:09:13 dnsmasq[2550]: query[A] grafana.lab from 10.10.0.22
Apr 25 15:09:13 dnsmasq[2550]: config grafana.lab is 10.10.0.200
Apr 25 15:09:13 dnsmasq[2550]: query[A] gitlab.lab from 10.10.0.22
Apr 25 15:09:13 dnsmasq[2550]: config gitlab.lab is 10.10.0.30
Apr 25 15:09:13 dnsmasq[2550]: query[A] nonexistent-svc.lab from 10.10.0.22
Apr 25 15:09:13 dnsmasq[2550]: config nonexistent-svc.lab is 10.10.0.200
```

Source IP `10.10.0.22` is worker-2's node IP — pods' egress to external DNS is SNAT'd through Calico's `natOutgoing: true` default. Useful debugging context.

---

## 5. Failure modes encountered (and avoided)

### F1 — port 53 conflict with systemd-resolved

Ubuntu 24.04 defaults to systemd-resolved binding DNS stub listeners on `127.0.0.53:53` / `127.0.0.54:53`. dnsmasq initially failed with:

```
dnsmasq: failed to create listening socket for port 53: Address already in use
```

**Fix:** set `DNSStubListener=no`, restart `systemd-resolved`, and convert `/etc/resolv.conf` into a regular file that uses local dnsmasq (`127.0.0.1`).

**Lesson:** do not assume a loopback-only listener means another DNS daemon can bind successfully. Verify port 53 ownership with `ss -tlnup 'sport = :53'`.

### F2 — duplicate `address=` records returning duplicate answers

After dnsmasq install, every query returned 2 identical A records. Root cause: a pre-existing `lab-hosts.conf` file in `/etc/dnsmasq.d/` (created during pre-session experimentation), overlapping with the canonical `lab.conf`.

**Fix:** delete the redundant file, restart dnsmasq.

**Lesson:** before writing into any `*.d/` style directory, `ls -la <dir>/` first. Multi-source-of-truth in a config drop-in directory = drift inevitable.

### F3 — macOS `dig` doesn't honor `/etc/resolver/`

Under troubleshooting, `dig grafana.lab` returned nothing, yet `dscacheutil -q host -a name grafana.lab` returned the right IP. macOS's per-domain resolver mechanism (`/etc/resolver/<domain>`) is consumed by the OS DNS resolution chain, not by `dig` (which talks raw DNS to whatever's in `/etc/resolv.conf`).

**Lesson:** `dig` is for protocol-level testing. `dscacheutil` / `getent` / `curl` for OS-level validation.

### F4 — `kubectl edit` paste-trap with chat-rendered content (the most painful detour)

When the CoreDNS ConfigMap was first edited interactively, the editor content displayed bracket-link syntax like `[in-addr.arpa](http://in-addr.arpa)` instead of plain `in-addr.arpa`. This was a **chat client / terminal display layer artifact**, not real corruption. Verified by:

- `xxd` byte dump showed plain `in-addr.arpa` bytes (no `0x5b` `[` byte present)
- Reverse DNS (`nslookup 10.96.0.1` → `kubernetes.default.svc.cluster.local`) worked, which would fail if `in-addr.arpa` zone string was actually corrupted
- CoreDNS pods Running healthy throughout

**Resolution:** abandoned `kubectl edit` entirely. Used `kubectl patch` with `python3 -c 'import json; print(json.dumps(...))'` to JSON-encode the new Corefile. No editor paste, no shell escaping ambiguity.

**Lessons (locked):**

1. **Display ≠ data.** When chat output looks weird, run `xxd`/`od`/`hexdump` immediately. Don't escalate based on rendered text.
2. **Prefer non-interactive patches** for ConfigMaps with multi-line embedded content (Corefile, scripts, etc.). `kubectl edit` is fine for simple key edits but fragile for complex pasted blocks.
3. **Backup before any ConfigMap edit.** Rollback path proven essential — `kubectl apply -f` (with `resourceVersion`/`uid`/`creationTimestamp` stripped) is the lenient restore path; `kubectl replace -f` will reject due to optimistic concurrency.

### F5 — `kubectl replace` rejected stale resourceVersion

`kubectl replace -f backup.yaml` failed with `Operation cannot be fulfilled... the object has been modified`. Backup file had stale `resourceVersion` from when it was captured.

**Fix:** `sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d' backup.yaml > clean.yaml && kubectl apply -f clean.yaml`. `apply` does server-side merge and ignores resourceVersion.

---

## 6. AWS mapping

| Homelab component | AWS equivalent |
|---|---|
| `local=/lab/` in dnsmasq | Route 53 private hosted zone for `lab.` |
| `address=/...` records | Route 53 A records inside private zone |
| dnsmasq wildcard `address=/.lab/...` | Route 53 wildcard record `*.lab.` |
| `forward . 10.10.0.50` in CoreDNS | Route 53 Resolver outbound endpoint + forwarding rule |
| Mac `/etc/resolver/lab` | Local resolver conditional forwarding (DNS Server option in DHCP scope) |
| `/etc/dnsmasq.d/lab.conf` (Git-tracked) | Terraform `aws_route53_record` resources |
| dnsmasq query log | Route 53 Resolver query logs (CloudWatch) |
| Backup target for CA / config | S3 versioned bucket |

The shape of the system is the same as a private hosted zone + conditional forwarder pattern — only difference is the implementation is one config file and a CoreDNS block instead of a Terraform module against AWS APIs.

---

## 7. Lessons learned

1. **DNS is platform foundation, not setup work.** Future debugging of "X is unreachable" will start at this runbook 80% of the time.

2. **Display ≠ data.** Chat output, terminal copy-paste, and editor renderings can introduce or hide content. `xxd` is the source of truth.

3. **Prefer non-interactive ConfigMap patches** for complex multi-line content. `kubectl patch --type merge` with JSON-encoded values via `python3 -c json.dumps` is paste-immune.

4. **Backup before every ConfigMap edit, even one-line ones.** A 600-byte YAML file is cheap insurance; rollback is fast only when the snapshot exists.

5. **`kubectl replace` vs `kubectl apply` for restore:** `replace` is strict (resourceVersion match required), `apply` is lenient (server-side merge). Strip `resourceVersion`, `uid`, `creationTimestamp` from the backup file when doing apply-based restore.

6. **Pre-write directory check:** before writing into any `*.d/` drop-in directory (`/etc/dnsmasq.d/`, `/etc/sysctl.d/`, etc.), `ls -la <dir>/` first. Don't assume empty.

7. **DNS install becomes guesswork unless port ownership is verified.** Even if `systemd-resolved` is active, the real question is who owns `:53`. `ss -tlnup 'sport = :53'` is the source of truth.

8. **Calico's default `natOutgoing: true`** means upstream queries from pods appear sourced at the node IP, not the pod IP, in svc-1 dnsmasq logs. Useful to know when correlating queries to pods.

---

## 8. Operational notes

### Where logs live

- **dnsmasq queries:** `/var/log/dnsmasq.log` on svc-1 (size grows; consider `logrotate` if it gets unwieldy)
- **CoreDNS:** `kubectl -n kube-system logs -l k8s-app=kube-dns -f`
- **Mac DNS:** `Console.app` → search `mDNSResponder` (rarely needed)

### How to add a new `*.lab` record

1. Edit `manifests/phase-4/dns/svc-1-dnsmasq-lab.conf` in repo. If it is a direct infrastructure hostname, add an explicit `address=/host.lab/IP`. If it is ingress-routed, the wildcard is already enough — do not add a separate record unless it needs a non-default IP.
2. `git add` + `git commit`
3. Copy to svc-1: `scp manifests/phase-4/dns/svc-1-dnsmasq-lab.conf tuhin@10.10.0.50:/tmp/lab.conf`
4. On svc-1: `sudo mv /tmp/lab.conf /etc/dnsmasq.d/lab.conf && sudo dnsmasq --test --conf-file=/etc/dnsmasq.conf && sudo systemctl restart dnsmasq`
5. Verify: `dig @10.10.0.50 newhost.lab +short`

### How to test from anywhere quickly

```
# From Mac:
dscacheutil -q host -a name <host>.lab

# From svc-1:
dig @127.0.0.1 <host>.lab +short

# From cluster pod (throwaway):
kubectl run dnstest --image=busybox:1.36 --restart=Never --rm -it -- nslookup <host>.lab
```

### How to roll back the CoreDNS lab:53 block

```
kubectl apply -f /tmp/phase-4-coredns/restore-clean.yaml
# (or recreate from backup with sed strip if path differs)
# CoreDNS reload plugin picks up reversion within ~30s
```

---

## 9. Open follow-up items

1. **svc-1 reboot survival test** — verify three things after reboot: `/etc/resolv.conf` still points to `127.0.0.1`, dnsmasq is active, and `systemd-resolved` did not reclaim port 53. Quick test next session: `ssh tuhin@10.10.0.50 'sudo reboot'`, reconnect, then run `cat /etc/resolv.conf`, `systemctl is-active dnsmasq`, and `sudo ss -tlnup 'sport = :53'`.

2. **dnsmasq log rotation** — `/var/log/dnsmasq.log` will grow. Add `logrotate` config or set `--log-async` + size limits. Low priority for lab.

3. **DNS-level RBAC / ACLs** — currently dnsmasq accepts queries from anyone in lab subnet. Consider `--local-service` flag (already on by default in Ubuntu's systemd unit) verification, or explicit allow-list. Lab scale fine, document for record.

4. **CoreDNS Corefile in Git** — currently we have the manifest snapshot, but no GitOps reconciliation. Phase 6 (ArgoCD) is when CoreDNS ConfigMap could be Git-managed.

5. **Reverse DNS for `.lab` hostnames** — currently `nslookup 10.10.0.30` doesn't return `gitlab.lab`. Would need PTR records in dnsmasq. Defer until needed (logs/audit context typically the trigger).