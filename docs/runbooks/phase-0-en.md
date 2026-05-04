

# Phase 0 — Network + Proxmox Foundation (Plain English, Detailed)

> **Status:** ✅ Complete  
> **Executed:** 2026-04-21  
> **Owner:** Tuhin Zaman  
> **Host:** pve-1 (Proxmox VE 9.1, 192.168.68.200)

---

## Goal (one line)

Build a clean and predictable network base on Proxmox so that:
- The lab network is isolated
- The lab can reach the internet (NAT)
- Remote access works (Tailscale)
- Your Mac can directly reach lab IPs

---

## Final End State (what must be true)

- `vmbr0` = main network bridge (192.168.68.0/24, bound to physical NIC `nic0`)
- `vmbr1` = isolated lab bridge (10.10.0.0/24, no physical NIC)
- Proxmox host (`pve-1`) is the gateway for lab: `10.10.0.1`
- IPv4 and IPv6 forwarding enabled and persistent
- nftables configured for:
  - NAT (lab → internet)
  - filtering (block direct home → lab access)
- Tailscale runs as a subnet router for:
  - 192.168.68.0/24
  - 10.10.0.0/24
- Mac has a route: `10.10.0.0/24 → 192.168.68.200`
- Test VM (10.10.0.51) is reachable from Mac and can access the internet

---

## Mental Model (simple flow)

### Local access (Mac → VM)

```
Mac → pve-1 → vmbr1 → VM
```

### Internet access (VM → Internet)

```
VM → vmbr1 → pve-1 → NAT → vmbr0 → Internet
```

### Remote access (outside → lab)

```
Laptop/Phone → Tailscale → pve-1 → vmbr1 → VM
```

---

## Key Design Decisions (why this setup)

- **Two bridges only**
  - vmbr0 = external (home LAN)
  - vmbr1 = internal (lab)
- **No physical NIC on vmbr1**
  - ensures full isolation
- **NAT on Proxmox**
  - simplest way to give lab internet
- **nftables instead of iptables**
  - modern, cleaner, avoids conflicts with Tailscale
- **Tailscale subnet router**
  - easy remote access without opening ports
- **Static route on Mac**
  - direct access without relying on DNS/VPN

---

## Prerequisites

- Proxmox VE installed and reachable at `192.168.68.200`
- SSH access from Mac to Proxmox
- Working internet on Proxmox
- Tailscale account ready

---

## Step 1 — Backup and identify NIC

**Where:** pve-1

Always take a backup before editing network config.

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d)
ip -br link show | grep -v 'lo\|vmbr\|tap\|veth'
```

👉 Find your real NIC name (in this setup: `nic0`)

---

## Step 2 — Clean old configuration (if migrating)

If there was an older setup (vmbr2, iptables NAT, etc.), remove it:

```bash
iptables -t nat -D POSTROUTING -s 10.0.1.0/24 -o vmbr0 -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i vmbr2 -o vmbr0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i vmbr0 -o vmbr2 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
ifreload -a
```

👉 This avoids hidden conflicts later.

---

## Step 3 — Configure bridges

**Concept**

| Bridge | Purpose |
|--------|--------|
| vmbr0  | Main network (home LAN) |
| vmbr1  | Lab network (isolated) |

- vmbr0 → attached to `nic0`
- vmbr1 → no physical NIC

---

## Step 4 — Verify network state

```bash
ip -br addr show
ip route
```

Expected:
- vmbr0 → 192.168.68.200/24
- vmbr1 → 10.10.0.1/24
- default route → 192.168.68.1
- 10.10.0.0/24 → directly connected

---

## Step 5 — Enable IP forwarding

**Where:** pve-1

```bash
sysctl --system
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
```

Expected:
```
= 1
= 1
```

👉 IPv6 forwarding must also be enabled (Tailscale expects it)

---

## Step 6 — Configure nftables (NAT + filtering)

**Why nftables?**
- Cleaner than iptables
- Avoids breaking Tailscale rules
- Easier to maintain

**Apply config**

```bash
nft -c -f /etc/nftables.conf && echo "SYNTAX OK"
systemctl enable --now nftables
nft -f /etc/nftables.conf
```

**Verify**

```bash
nft list ruleset
```

### Important rules behavior

- NAT: `10.10.0.0/24 → vmbr0`
- Allow: lab → internet
- Allow: return traffic
- Block: home → lab direct access
- Allow: Tailscale → lab

👉 Never run:
```
nft flush ruleset
```
This will break Tailscale.

---

## Step 7 — Configure Tailscale subnet router

**Where:** pve-1

```bash
tailscale up \
  --advertise-routes=192.168.68.0/24,10.10.0.0/24 \
  --accept-routes \
  --ssh
```

### Required UI step

Go to:
https://login.tailscale.com/admin/machines

- Find `pve-1`
- Enable both routes:
  - 192.168.68.0/24
  - 10.10.0.0/24
- Disable key expiry

---

## Step 8 — Add route on Mac

**Where:** Mac

```bash
sudo route -n add -net 10.10.0.0/24 192.168.68.200
```

Test:

```bash
ping -c 3 10.10.0.1
```

👉 Must succeed

---

## Step 9 — Create test VM

**Where:** pve-1

```bash
qm clone 9000 901 --name phase0-test-1 --full
qm set 901 --net0 virtio,bridge=vmbr1
qm set 901 --ipconfig0 ip=10.10.0.51/24,gw=10.10.0.1
qm set 901 --nameserver 1.1.1.1
qm set 901 --ciuser tuhin --sshkeys ~/.ssh/authorized_keys_tuhin.pub
qm set 901 --onboot 1
qm cloudinit update 901
qm start 901
```

---

## Step 10 — Validate data plane

**From Mac**

```bash
ping -c 3 10.10.0.51
ssh tuhin@10.10.0.51 'hostname'
ssh tuhin@10.10.0.51 'ping -c 3 1.1.1.1'
ssh tuhin@10.10.0.51 'ping -c 3 google.com'
```

Expected:
- ping works
- SSH works
- internet works (IP + DNS)

---

## Step 11 — Reboot persistence test

**Where:** pve-1

```bash
reboot
```

After ~60 seconds:

```bash
ping -c 3 10.10.0.1
ssh tuhin@10.10.0.51
```

👉 Everything must still work

---

## Common Problems and Fixes

### 1. Wrong NIC name

**Problem**
```
device not found
```

**Fix**
```bash
ip link
```

---

### 2. Cannot reach lab network

**Problem**
```
ping 10.10.x.x fails
```

**Fix**
```bash
sudo route -n add -net 10.10.0.0/24 192.168.68.200
```

---

### 3. No internet from VM

Check:
- gateway = 10.10.0.1
- DNS = 1.1.1.1
- NAT rule exists

---

### 4. Tailscale broken

Cause:
```
nft flush ruleset
```

Fix:
- reapply nft config
- restart tailscale

---

### 5. VM gets wrong DNS

Fix:
```bash
qm set 901 --nameserver 1.1.1.1
```

---

## Deferred Items (later phases)

- Persist Mac route (LaunchDaemon)
- DNS server for lab
- Firewall hardening (default drop policy)
- External Tailscale testing
- Remove test VM after Phase 1

---

## Exit Criteria (all must pass)

- [x] Mac → 10.10.0.1 reachable  
- [x] VM reachable via SSH  
- [x] VM has internet (IP + DNS)  
- [x] NAT working  
- [x] Tailscale routes working  
- [x] Reboot does not break anything  

---

## Final Understanding

You built 3 core things:

1. **Network isolation (vmbr1)**
2. **Internet access (NAT)**
3. **Remote access (Tailscale)**

👉 Without these, Kubernetes setup cannot work.

---

**Phase 0 COMPLETE ✅**  
Next → Phase 1 (VM Template + Hardening)
# Phase 0 — Network + Proxmox Foundation

> **Status:** ✅ Complete  
> **Date:** 2026-04-21  
> **Owner:** Tuhin Zaman  
> **Host:** pve-1 (Proxmox VE 9.1, 192.168.68.200)

---

## Goal in one line

Build an isolated lab network on the Proxmox host, route lab traffic out to the internet, open a path from the Mac into the lab, and set up Tailscale for remote access.

---

## Why we needed this

After installing Proxmox, the host had only one bridge: `vmbr0` on the home network. But the VMs coming in Phase 1+ (Kubernetes nodes, GitLab, service nodes, and future workloads) need to live on an **isolated lab network**.

This gives us five important things:

1. Lab VMs can talk to each other freely
2. Other devices on the home network cannot directly start connections into the lab
3. Lab VMs can still reach the internet through NAT
4. The Mac can SSH/kubectl into lab resources
5. Off-LAN access can work through Tailscale

After Phase 0, the lab network became the foundation for every later phase.

---

## End State — verified

- `vmbr0` = management bridge (`192.168.68.0/24`, physical NIC `nic0`)
- `vmbr1` = isolated lab bridge (`10.10.0.0/24`, no physical NIC)
- pve-1 acts as lab gateway: `10.10.0.1`
- IPv4 + IPv6 forwarding enabled and persistent across reboot
- nftables `homelab_filter` + `homelab_nat` tables load at boot
- Forward chain enforces home → lab isolation, with stateful return only
- Tailscale advertises both subnets and routes are approved in the admin console
- Mac uses runtime static route: `10.10.0.0/24 → 192.168.68.200`
- Test VM 901 (`phase0-test-1`) is on `vmbr1`, IP `10.10.0.51`, reachable by SSH

---

## Architecture — how traffic reaches a lab VM

Mac to lab VM:

```text
Mac (192.168.68.X)
   ↓ static route: 10.10.0.0/24 → pve-1
pve-1 (192.168.68.200) physical NIC / vmbr0
   ↓ forward to lab bridge
vmbr1 bridge (10.10.0.1 gateway)
   ↓
Test VM (10.10.0.51)
```

VM to internet:

```text
VM (10.10.0.51)
   ↓ default gateway 10.10.0.1
pve-1 vmbr1
   ↓ nftables NAT (homelab_nat → MASQUERADE)
pve-1 vmbr0
   ↓
home router → internet
```

Remote access:

```text
Remote Mac / Phone
   ↓
Tailscale
   ↓
pve-1 subnet router
   ↓
10.10.0.0/24 lab network
```

---

## How each component works — plain English

### Bridges: `vmbr0`, `vmbr1`

A bridge is a software switch. Inside Proxmox, it behaves like a virtual cable. Devices attached to the same bridge can talk to each other.

- `vmbr0` is connected to physical NIC `nic0`, so it connects Proxmox to the home network
- `vmbr1` has no physical NIC, so it is only for lab VMs
- pve-1 is the gateway on `vmbr1`: `10.10.0.1`

### IP forwarding

By default, Linux does not forward packets from one interface to another. To make pve-1 act like a router, IP forwarding must be enabled.

Required settings:

```text
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

IPv6 forwarding is not enabled because the lab is using IPv6. It is enabled to keep Tailscale subnet routing behavior clean and avoid warnings.

### nftables — `homelab_filter` + `homelab_nat`

`homelab_filter`:

- allows lab → internet traffic
- allows established/related return traffic
- blocks direct new home LAN → lab connections
- explicitly allows the Tailscale admin path into the lab

`homelab_nat`:

- rewrites traffic from `10.10.0.0/24` when it exits through `vmbr0`
- uses MASQUERADE so internet replies come back to pve-1
- without NAT, the internet would not know how to return traffic to `10.10.0.0/24`

Why named tables:

- Tailscale also uses nftables/iptables-nft rules, such as `ts-postrouting`
- `nft flush ruleset` would wipe Tailscale rules and break Tailscale
- using named tables lets us manage only our own rules: `homelab_filter`, `homelab_nat`

### Tailscale subnet router

Tailscale is not only being used as a VPN client here. pve-1 acts as a subnet router.

Advertised routes:

```text
192.168.68.0/24
10.10.0.0/24
```

This means approved Tailscale devices can reach the home network and lab network without opening ports on the home router.

### Mac static route

By default, the Mac does not know where `10.10.0.0/24` lives. It sends unknown traffic to the home router `192.168.68.1`, but the home router does not know the lab network either. Result: timeout.

Fix:

```bash
sudo route -n add -net 10.10.0.0/24 192.168.68.200
```

Meaning: to reach `10.10.0.0/24`, use pve-1 (`192.168.68.200`) as the gateway.

---

## What was configured

| Item | Value |
|---|---|
| Proxmox version | VE 9.1 |
| pve-1 management IP | 192.168.68.200 |
| Management network | 192.168.68.0/24 |
| Lab subnet | 10.10.0.0/24 |
| pve-1 lab gateway | 10.10.0.1 |
| Physical NIC | nic0 |
| Management bridge | vmbr0 |
| Lab bridge | vmbr1 |
| Tailscale routes | 192.168.68.0/24, 10.10.0.0/24 |
| Mac route | 10.10.0.0/24 → 192.168.68.200 |
| Test VM | VM 901, IP 10.10.0.51 |

---

## Deviations from the original plan

1. **Pre-existing config was found**  
   pve-1 already had `vmbr2` on `10.0.1.0/24` with inline iptables NAT rules. There was also a stopped Ubuntu 24.04 template, VM 9000. We migrated to the v2.5 design: removed `vmbr2`, cleaned old iptables rules, and preserved the template for Phase 1.

2. **Physical NIC name was `nic0`**  
   It was not the default `enp*` style name. It had been renamed with a systemd link rule. All configs use `nic0`.

3. **Tailscale was already installed**  
   Installation was skipped. Only preferences were reconfigured: `AdvertiseRoutes`, `RouteAll`, and `RunSSH`.

4. **nftables named tables were used**  
   We avoided global `flush ruleset` because it could wipe Tailscale's `ts-postrouting` rules.

5. **Forward chain was corrected**  
   The first version allowed `vmbr0 ↔ vmbr1` in both directions. The corrected design blocks new home LAN → lab traffic, allows stateful return, and explicitly allows the Tailscale admin path.

6. **Mac route persistence was deferred**  
   In Phase 0, the runtime route was considered enough. This later caused an issue in Phase 3, where a retry-based LaunchDaemon approach was selected.

7. **Break-it drills were deferred**  
   Phase 0–6 had an execution-time exception for formal drills. Break-it discipline resumed in Phase 3.

---

## Prerequisites

- [x] Proxmox VE 9.1 installed on pve-1 (`192.168.68.200`)
- [x] Physical NIC connected to the home router/network
- [x] Root SSH access from Mac to pve-1
- [x] Tailscale account ready
- [x] Ubuntu 24.04 template VM 9000 available

---

## Step-by-step execution

### Step 1 — Backup + identify the NIC

**Run on:** pve-1

A backup was taken before editing network config. This is the rollback safety net.

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d)
ip -br link show | grep -v 'lo\|vmbr\|tap\|veth'
```

Result:

```text
NIC name = nic0
```

Rule: never assume the NIC name. Always verify it.

---

### Step 2 — Bridge config + old iptables cleanup

**Run on:** pve-1

Final network config is committed here:

```text
configs/phase-0/interfaces
```

Old iptables cleanup:

```bash
iptables -t nat -D POSTROUTING -s 10.0.1.0/24 -o vmbr0 -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i vmbr2 -o vmbr0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i vmbr0 -o vmbr2 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
ifreload -a
```

Validation:

```bash
ip -br addr show vmbr0
ip -br addr show vmbr1
ip route
```

Expected:

```text
vmbr0: 192.168.68.200/24
vmbr1: 10.10.0.1/24
default route: via 192.168.68.1
10.10.0.0/24: direct via vmbr1
```

Note: `vmbr1` may show `UNKNOWN`; that is normal when no physical port is attached.

---

### Step 3 — IP forwarding

**Run on:** pve-1

Final sysctl config is committed here:

```text
configs/phase-0/99-ipforward.conf
```

Apply and verify:

```bash
sysctl --system
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
```

Expected:

```text
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

---

### Step 4 — nftables ruleset

**Run on:** pve-1

Final nftables config is committed here:

```text
configs/phase-0/nftables.conf
```

Syntax check, enable, and apply:

```bash
nft -c -f /etc/nftables.conf && echo "SYNTAX OK"
systemctl enable --now nftables
nft -f /etc/nftables.conf
```

Validation:

```bash
nft list table inet homelab_filter
nft list table ip homelab_nat
iptables -t nat -L ts-postrouting -n -v | head -5
```

Expected:

- `homelab_filter` present
- `homelab_nat` present
- Tailscale `ts-postrouting` still intact

---

### Step 5 — Tailscale subnet router

**Run on:** pve-1

Important: `tailscale up` is declarative. Pass all desired flags at the same time. Missing flags can reset old settings.

```bash
tailscale up \
  --advertise-routes=192.168.68.0/24,10.10.0.0/24 \
  --accept-routes \
  --ssh
```

Admin console steps:

1. Open the Tailscale admin console
2. Find the pve-1 / pve machine
3. Edit route settings
4. Enable:
   - `192.168.68.0/24`
   - `10.10.0.0/24`
5. Disable key expiry for pve-1

Validation:

```bash
tailscale status
tailscale debug prefs | grep -iE 'route|ssh'
tailscale netcheck
```

Expected:

- advertised routes visible
- SSH enabled
- UDP reachability healthy enough

---

### Step 6 — Mac static route

**Run on:** Mac

```bash
sudo route -n add -net 10.10.0.0/24 192.168.68.200
ping -c 3 10.10.0.1
```

Expected:

```text
3 replies from 10.10.0.1
```

Phase 0 decision: persistence deferred. Runtime route was enough for early phases.

---

### Step 7 — Data plane validation with test VM

**Run on:** pve-1

Prerequisite: Mac public key copied to:

```text
~/.ssh/authorized_keys_tuhin.pub
```

Create and configure test VM:

```bash
qm clone 9000 901 --name phase0-test-1 --full
qm set 901 --net0 virtio,bridge=vmbr1
qm set 901 --ipconfig0 ip=10.10.0.51/24,gw=10.10.0.1 --nameserver 1.1.1.1 --searchdomain lab.local
qm set 901 --ciuser tuhin --sshkeys ~/.ssh/authorized_keys_tuhin.pub
qm set 901 --onboot 1
qm cloudinit update 901
qm start 901
```

Validate from Mac:

```bash
ping -c 3 10.10.0.51
ssh tuhin@10.10.0.51 'hostname && ip -4 addr show eth0 | grep inet'
ssh tuhin@10.10.0.51 'ping -c 3 1.1.1.1 && ping -c 3 google.com'
```

Expected:

- Mac can ping VM
- SSH works
- VM has IP `10.10.0.51/24`
- VM can reach the internet by IP and DNS

---

### Step 8 — Reboot persistence validation

**Run on:** pve-1

```bash
reboot
```

After about 60 seconds, run from Mac:

```bash
ping -c 3 10.10.0.1
ssh tuhin@10.10.0.51 'hostname && ip -4 addr show eth0 | grep inet'
```

Expected:

- pve-1 lab gateway reachable
- VM autostart works
- SSH still works
- bridges, nftables, IP forwarding, and VM config survived reboot

---

## Common Pitfalls — actually hit during execution

| Pitfall | Symptom | Fix |
|---|---|---|
| NIC renamed via systemd link | `enp3s0` not found | use `ip link` to find the actual name (`nic0` in this setup) |
| `--full 0` typo in `qm clone` | Silent linked clone | `--full` is a boolean flag; it takes no value |
| Inline comments in multi-line shell block | `qm` parses `#` as an argument | Put commands separately and comments on their own lines |
| Cloud-init inherited pve-1 resolv.conf | VM gets Tailscale MagicDNS (`100.100.100.100`) | Use explicit `--nameserver 1.1.1.1` |
| `--sshkeys` expects a file path | Inline key silently fails | Write the pubkey to a file and pass the file path |
| Forward chain accepted both directions | Home hosts could initiate new connections into the lab | vmbr0 → vmbr1 must be stateful-return-only |
| `nft flush ruleset` breaks Tailscale | `ts-postrouting` wiped | Use named tables and only manage your own rules |
| IPv6 forwarding off | Tailscale warning / suboptimal routing | Enable `net.ipv6.conf.all.forwarding=1` |

---

## Recovery scenarios

### Mac cannot reach `10.10.0.X`

**Run on:** Mac

```bash
route -n get 10.10.0.10 | grep gateway
sudo route -n add -net 10.10.0.0/24 192.168.68.200
ping -c 3 192.168.68.200
ping -c 3 10.10.0.1
```

Expected gateway:

```text
192.168.68.200
```

### VM cannot reach the internet

**Run on:** pve-1

```bash
sysctl net.ipv4.ip_forward
nft list table ip homelab_nat
systemctl status nftables
```

Also check inside the VM:

```bash
ip route
cat /etc/resolv.conf
ping -c 3 1.1.1.1
ping -c 3 google.com
```

### Tailscale broken after a network change

**Run on:** pve-1

```bash
systemctl status tailscaled
tailscale status
tailscale debug prefs | grep -iE 'route|ssh'
iptables -t nat -L ts-postrouting -n
```

If rules were wiped:

```bash
systemctl restart tailscaled
tailscale up \
  --advertise-routes=192.168.68.0/24,10.10.0.0/24 \
  --accept-routes \
  --ssh
```

---

## Deferred Items

- **Tailscale off-LAN path test** — verify with phone hotspot; still pending after Phase 3
- **Mac route persistence** — appeared as an issue in Phase 3; later handled with LaunchDaemon/retry approach
- **Break-it drills** — Phase 0–6 exception existed; resumed in Phase 3
- **Forward chain hardening** — revisit in Phase 4 with explicit drop policy + logging
- **VM 901 cleanup** — after Phase 1 template work is complete: `qm stop 901 && qm destroy 901`

---

## Files committed in this phase

```text
configs/phase-0/
├── interfaces                          # /etc/network/interfaces snapshot
├── nftables.conf                       # /etc/nftables.conf snapshot
├── 99-ipforward.conf                   # /etc/sysctl.d/99-ipforward.conf
├── vm-901.config                       # qm config 901 dump
└── vm-901-cloudinit-network.yaml       # cloud-init network dump

docs/runbooks/
├── phase-0-bn.md                       # Bangla runbook
└── phase-0-en.md                       # English runbook
```

---

## Exit Criteria — all passed

- [x] Mac → `10.10.0.1` ping succeeds
- [x] `sysctl net.ipv4.ip_forward` = 1
- [x] `sysctl net.ipv6.conf.all.forwarding` = 1
- [x] `nft list` shows `homelab_filter` + `homelab_nat`
- [x] Tailscale `ts-postrouting` still intact
- [x] Forward chain isolation enforced: no plain home → lab new connection allowed
- [x] Test VM booted and received cloud-init IP
- [x] Mac can SSH into test VM
- [x] Test VM reaches internet by IP and DNS
- [x] pve-1 reboot → all above still true
- [x] Configs + runbooks committed

---

## Final understanding

Phase 0 created the base network layer for the entire homelab.

You built:

1. **Network isolation** with `vmbr1`
2. **Internet access** with NAT
3. **Remote access** with Tailscale subnet routing
4. **Mac access** with a static route
5. **Persistence validation** with a reboot test

Without this phase, Kubernetes nodes in later phases would not have stable networking, internet access, or predictable admin access.

---

*Phase 0 complete. Move on to Phase 1 — VM baseline + Ubuntu template hardening.*