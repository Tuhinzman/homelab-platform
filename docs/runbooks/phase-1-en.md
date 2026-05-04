

# Phase 1 — VM Baseline

> **Status:** ✅ Complete  
> **Date:** 2026-04-21  
> **Owner:** Tuhin Zaman  
> **Host:** pve-1 (Proxmox VE 9.1, 192.168.68.200)

---

## Goal in one line

Turn the Ubuntu 24.04 cloud image into a hardened template, then clone six production VMs from it per the v2.5 plan — all reachable from the Mac via passwordless SSH, baseline-consistent, and ready for Phase 2 kubeadm.

---

## Why we needed this

After Phase 0, the network was ready, but the production VMs did not exist yet. Installing and configuring each VM manually would take too long and would create many chances for drift and mistakes.

The better approach was:

1. **Build one golden template** — Ubuntu 24.04, hardened baseline, SSH lockdown, common packages, timezone, QEMU guest agent, sudo
2. **Clone from it** — every production VM is a full clone with its own VMID, IP, and hostname
3. **Keep identity clean** — every clone must get its own machine-id and SSH host keys
4. **Keep reproducibility** — future VMs can be created from the same baseline
5. **Keep an audit trail** — the source of truth is the hardened template plus provisioning script

After Phase 1, six production VMs were running, hostnames and IPs matched the v2.5 plan, and the Mac could access each VM using SSH aliases. Phase 2 will bootstrap kubeadm on these VMs.

---

## End State — verified

- **Template VM 9000:** original Ubuntu 24.04 cloud template, untouched rollback baseline
- **Template VM 9001:** hardened template `ubuntu-2404-hardened`
  - latest package upgrade completed
  - QEMU guest agent active
  - SSH password authentication disabled
  - SSH root login disabled
  - SSH pubkey-only access
  - `tuhin` passwordless sudo enabled as a lab tradeoff
  - timezone set to `America/New_York`
  - root disk resized from 3.5 GB to 13.5 GB
  - machine-id truncated
  - cloud-init cleaned
  - SSH host keys removed before template conversion
- **6 production VMs** provisioned per v2.5 plan
- all VMs reachable from Mac using passwordless SSH
- SSH aliases configured locally on Mac
- reboot persistence verified
- unique machine-id per VM verified

---

## VM Inventory

| VMID | Hostname | IP | vCPU | RAM | Role |
|---|---|---|---|---|---|
| 9000 | ubuntu-2404-cloud | — | 2 | 2 GB | Original template / rollback baseline |
| 9001 | ubuntu-2404-hardened | — | 2 | 2 GB | Hardened template used for production clones |
| 110 | k8s-cp-1 | 10.10.0.10 | 4 | 4 GB | Control plane + etcd |
| 121 | k8s-worker-1 | 10.10.0.21 | 4 | 8 GB | App workloads |
| 122 | k8s-worker-2 | 10.10.0.22 | 4 | 8 GB | App workloads |
| 123 | k8s-worker-3 | 10.10.0.23 | 2 | 4 GB | Ingress + overflow |
| 130 | ci-1 | 10.10.0.30 | 4 | 12 GB | GitLab CE + Runner |
| 150 | svc-1 | 10.10.0.50 | 2 | 4 GB | DNS + CA |

**RAM total allocated:** 40 GB. Host reserved approximately 24 GB.

---

## Architecture — from template to production VM

```text
Ubuntu 24.04 cloud image
   ↓ qm importdisk / template prep
VM 9000: original template, immutable rollback baseline
   ↓ qm clone --full
VM 9001: writable WIP VM
   ↓ boot + harden + cleanup
VM 9001: converted to hardened template
   ↓ qm clone --full × 6
VM 110 / 121 / 122 / 123 / 130 / 150
   ↓ first boot cloud-init
unique hostname + IP + SSH key + machine-id + host keys
   ↓
production VMs ready, SSH from Mac via aliases
```

Why two templates:

- `9000` stays untouched, so it is the rollback baseline
- `9001` becomes the production source of truth for future clones

---

## How each component works — plain English

### Cloud-init

Problem:

If six VMs are cloned from the same template, they can accidentally share hostname, machine-id, SSH host keys, or user config. That can create cluster identity problems later.

What cloud-init does:

- reads first-boot config from the Proxmox cloud-init drive
- sets hostname
- configures static IP
- creates/configures the user
- injects the SSH public key
- triggers fresh first-boot identity generation

Important:

During template cleanup, cloud-init is reset so every clone runs cloud-init fresh on its first boot.

---

### QEMU guest agent

Problem:

Without a guest agent, the Proxmox host cannot easily see inside the VM. The VM is more like a black box.

What QEMU guest agent does:

- runs as a daemon inside the VM
- talks to Proxmox over a virtio channel
- lets Proxmox query VM IP/interface info
- can support filesystem freeze for future backup/snapshot consistency

Example future command:

```bash
qm guest cmd <vmid> network-get-interfaces
```

---

### SSH hardening

The default cloud image SSH config is not strict enough for the lab baseline. The hardened template tightens SSH access.

| Setting | Value | Why |
|---|---|---|
| `PasswordAuthentication` | `no` | reduces password brute-force risk |
| `PermitRootLogin` | `no` | blocks direct root login |
| `PubkeyAuthentication` | `yes` | uses SSH key based auth |
| `ChallengeResponseAuthentication` | `no` | disables non-pubkey login paths |
| `KbdInteractiveAuthentication` | `no` | disables keyboard-interactive login |

---

### Passwordless sudo

In production, requiring a sudo password can be better. It adds friction against accidental privilege use and can support stronger audit behavior.

In this homelab, `tuhin` has passwordless sudo because:

- automation is easier
- remote scripts do not get stuck on password prompts
- SSH key is already the main access control
- this is a single-user lab environment, not a shared production environment

Tradeoff:

This is acceptable for the homelab. A future hardening phase can revisit it.

---

### Machine-id + SSH host key cleanup

This part is critical.

If clones share the same identity files:

- systemd machine-id collisions can happen
- logs and telemetry can look duplicated
- SSH clients can warn about wrong host keys
- cluster software can behave unpredictably

Cleanup before converting VM 9001 into a template:

```text
/etc/machine-id truncated
/var/lib/dbus/machine-id relinked
/etc/ssh/ssh_host_* removed
cloud-init state cleaned
```

Critical rule:

After cleanup, do not boot VM 9001 before converting it to a template. If it boots, cloud-init and sshd can regenerate identity files, which ruins clone hygiene.

---

## What was installed/configured on Template VM 9001

| Item | Value |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Kernel | 6.8.0-110-generic |
| Disk | 13.5 GB root disk |
| Disk change | 3.5 GB → 13.5 GB, `+10G` resize |
| Packages | qemu-guest-agent, vim, curl, jq, htop, net-tools, dnsutils, ca-certificates, gnupg |
| Timezone | America/New_York |
| User | tuhin |
| Sudo | NOPASSWD for tuhin |
| SSH | pubkey only, root disabled, password auth disabled |
| Cleanup | machine-id, SSH host keys, cloud-init state, logs, shell history |

---

## Deviations from the original plan

### D1 — Template strategy: Option A

- **Decision:** VM 9000 preserved untouched
- **Flow:** full-clone 9000 → 9001 → harden → convert 9001 to template
- **Why:** rollback baseline remains intact
- **Status:** accepted

### D2 — Disk resize required

- **Issue:** Ubuntu 24.04 cloud image default disk was only 3.5 GB
- **Impact:** first `apt upgrade` failed with `No space left on device`
- **Fix:** resized VM 9001 disk by `+10G`, ending around 13.5 GB
- **Result:** cloud-init growpart auto-expanded filesystem

### D3 — Partial upgrade recovery

- **Issue:** disk-full interrupted `apt upgrade`; snapd/dpkg became inconsistent
- **Fix:** `dpkg --configure -a` + `apt-get -f install -y`
- **Result:** package state reconciled, hardening script re-run cleanly

### D4 — Heredoc paste issue

- **Issue:** first hardening script attempt was corrupted by terminal paste
- **Fix:** write script to file, inspect with `tail`, then execute
- **Lesson:** for long scripts, do not paste blindly into shell

### D5 — Pending kernel reboot

- **Issue:** upgrade installed kernel `6.8.0-110`, old running kernel was still active until reboot
- **Fix:** rebooted before final cleanup/template conversion
- **Result:** template baked with kernel `6.8.0-110-generic`

### D6 — Known_hosts collision

- **Issue:** Mac had stale SSH host key for `10.10.0.10` from previous homelab attempt
- **Fix:** `ssh-keygen -R 10.10.0.10`
- **Result:** new VM host key accepted cleanly

### D7 — Break-it drills deferred

- **Reason:** Phase 0–6 execution-time exception
- **Reality:** real failures were captured opportunistically: disk full, dpkg recovery, paste corruption
- **Update:** Phase 3 later resumed formal break-it drills earlier than originally planned

### D8 — Template gaps surfaced later

Later phases found baseline gaps:

- Phase 2: `conntrack` missing
- Phase 3: `iscsid` not enabled, `multipathd` active

Track:

Fold these into the next template refresh, likely Phase 4.

---

## Step-by-step execution

### Step 1 — Verify original template state

**Run on:** pve-1

```bash
qm config 9000 | grep -E '^(name|template|memory|cores|net0|scsi0|ide2):'
qm status 9000
qm list | grep 9000
```

Pre-execution state:

```text
template: 1
status: stopped
2C / 2GB / vmbr0 / 3.5 GB disk / cloud-init ide2
```

---

### Step 2 — Full-clone VM 9000 to VM 9001

**Run on:** pve-1

Template disk is protected with a `base-` prefix. In-place editing is not the right path. Full clone creates a writable VM.

```bash
qm clone 9000 9001 --name ubuntu-2404-hardened-wip --full
```

Result:

```text
9001 disk changed from base template disk to writable VM disk
```

---

### Step 3 — Boot VM 9001 on vmbr1 with cloud-init

**Run on:** pve-1

```bash
qm set 9001 --net0 virtio,bridge=vmbr1
qm set 9001 --ipconfig0 ip=10.10.0.60/24,gw=10.10.0.1
qm set 9001 --nameserver 1.1.1.1 --searchdomain lab.local
qm set 9001 --ciuser tuhin --sshkeys ~/.ssh/authorized_keys_tuhin.pub
qm set 9001 --agent enabled=1 --memory 4096
qm cloudinit update 9001
qm start 9001
```

Note:

Memory was temporarily increased to 4 GB for smoother upgrade/hardening. It was reverted to 2 GB before template conversion.

---

### Step 4 — Disk resize: 3.5 GB → 13.5 GB

First `apt upgrade` failed because the root disk was too small.

**Run on:** pve-1

```bash
qm shutdown 9001
qm resize 9001 scsi0 +10G
qm start 9001
```

**Run inside:** VM 9001

```bash
df -h /
lsblk
```

Expected:

```text
root filesystem around 13 GB
sda1 expanded by growpart
```

---

### Step 5 — Recover partial upgrade + harden template

**Run inside:** VM 9001

```bash
sudo dpkg --configure -a
sudo apt-get -f install -y
```

Then run the hardening script committed at:

```text
configs/phase-1/harden.sh
```

Hardening script actions:

- `apt update && apt -y upgrade`
- install common packages:
  - qemu-guest-agent
  - vim
  - curl
  - jq
  - htop
  - net-tools
  - dnsutils
  - ca-certificates
  - gnupg
- enable/start QEMU guest agent
- set timezone to `America/New_York`
- create SSH hardening config:

```text
/etc/ssh/sshd_config.d/10-homelab.conf
```

SSH settings:

```text
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
```

Sudo setting:

```text
/etc/sudoers.d/90-tuhin
```

```text
tuhin ALL=(ALL) NOPASSWD:ALL
```

Validation before applying:

```bash
sudo sshd -t
sudo visudo -c
```

Restart SSH:

```bash
sudo systemctl restart ssh
```

Reboot afterward to load the new kernel.

---

### Step 6 — Cleanup for clone hygiene

**Run inside:** VM 9001

```bash
sudo cloud-init clean --logs --seed
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo apt-get clean
sudo find /var/log -type f -exec truncate -s 0 {} \;
sudo rm -f /root/.bash_history /home/tuhin/.bash_history
sudo shutdown -h now
```

Critical rule:

Do not boot VM 9001 after cleanup before template conversion.

---

### Step 7 — Convert VM 9001 to template

**Run on:** pve-1

```bash
qm set 9001 --memory 2048
qm set 9001 --name ubuntu-2404-hardened
qm template 9001
```

Expected:

```text
VM 9001 becomes immutable template
Disk gets base- prefix
```

---

### Step 8 — Validate template with test clone VM 902

**Run on:** pve-1

```bash
qm clone 9001 902 --name phase1-test --full
qm set 902 --net0 virtio,bridge=vmbr1 \
  --ipconfig0 ip=10.10.0.61/24,gw=10.10.0.1 \
  --nameserver 1.1.1.1 --searchdomain lab.local \
  --ciuser tuhin --sshkeys ~/.ssh/authorized_keys_tuhin.pub \
  --agent enabled=1
qm start 902
```

Validate from Mac:

- SSH connects
- new host key generated
- hostname = `phase1-test`
- machine-id unique
- `sudo -n whoami` returns `root`
- timezone = `America/New_York`
- kernel = `6.8.0-110-generic`

Destroy test clones after validation:

```bash
qm stop 902 && qm destroy 902 --purge   # Phase 1 test VM
```

Note:

Do not destroy VM 9001 after it is converted to a template. VM 9001 is the hardened source template.

---

### Step 9 — Mass provision 6 production VMs

**Run on:** pve-1

Provisioning script:

```text
configs/phase-1/provision-vms.sh
```

Design:

- loop over VM array: VMID, hostname, IP, cores, memory
- full clone from VM 9001
- configure cloud-init per VM
- enable QEMU agent
- set `--onboot 1`
- stagger VM starts with `sleep 5` to avoid I/O storm

Execution:

```bash
/root/provision-vms.sh 2>&1 | tee /root/provision-vms.log
```

Result:

```text
6 production VMs running
specs match v2.5 plan
```

---

### Step 10 — SSH matrix + reboot persistence validation

#### SSH matrix

**Run on:** Mac

```bash
for ip in 10.10.0.10 10.10.0.21 10.10.0.22 10.10.0.23 10.10.0.30 10.10.0.50; do
  ssh -o StrictHostKeyChecking=accept-new tuhin@$ip \
    'hostname && uname -r && sudo -n whoami && systemctl is-active qemu-guest-agent'
done
```

Expected:

```text
hostname correct
kernel 6.8.0-110-generic
sudo returns root
qemu-guest-agent active
```

#### Machine-id uniqueness

**Run on:** Mac

```bash
for ip in 10.10.0.10 10.10.0.21 10.10.0.22 10.10.0.23 10.10.0.30 10.10.0.50; do
  ssh tuhin@$ip 'cat /etc/machine-id'
done
```

Expected:

```text
6 unique machine IDs
```

#### Reboot persistence

**Run on:** pve-1

```bash
for vmid in 110 121 122 123 130 150; do
  qm reboot $vmid
done
```

**Run on:** Mac after ~60 seconds

```bash
for ip in 10.10.0.10 10.10.0.21 10.10.0.22 10.10.0.23 10.10.0.30 10.10.0.50; do
  ssh tuhin@$ip 'echo OK $(hostname) uptime=$(awk "{print int(\$1)}" /proc/uptime)s'
done
```

Expected:

```text
all VMs return OK
boot + IP + SSH survived reboot
```

---

## SSH Access Setup — Mac to Homelab

Mac file:

```text
~/.ssh/config
```

This file is local only and not committed to Git.

Pattern:

```text
Host <alias>
    HostName <ip>
    User <user>
```

Aliases configured:

| Alias | IP | User |
|---|---|---|
| pve | 192.168.68.200 | root |
| k8s-cp-1 | 10.10.0.10 | tuhin |
| k8s-worker-1 | 10.10.0.21 | tuhin |
| k8s-worker-2 | 10.10.0.22 | tuhin |
| k8s-worker-3 | 10.10.0.23 | tuhin |
| ci-1 | 10.10.0.30 | tuhin |
| svc-1 | 10.10.0.50 | tuhin |

Validation from Mac:

```bash
for host in pve k8s-cp-1 k8s-worker-1 k8s-worker-2 k8s-worker-3 ci-1 svc-1; do
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" 'echo OK $(hostname)'
done
```

Expected:

```text
all 7 hosts reply with OK <hostname>
```

Prerequisite:

Mac public key must exist on pve-1 at:

```text
/root/.ssh/authorized_keys_tuhin.pub
```

That key is injected into VMs through cloud-init.

---

## Common Pitfalls — actually hit during execution

| Pitfall | Symptom | Fix |
|---|---|---|
| Ubuntu cloud image disk too small | `apt upgrade` fails with `No space left on device` | resize disk before upgrade |
| Partial dpkg state after disk full | future `apt` commands fail | `dpkg --configure -a` + `apt-get -f install -y` |
| Heredoc paste corruption | script content gets mangled | write to file, verify, then execute |
| Template disk rename on conversion | `vm-9001-disk-0` becomes `base-9001-disk-0` | expected Proxmox behavior |
| Booting after cleanup before template conversion | host keys/machine-id regenerate | cleanup → shutdown → convert immediately |
| Stale known_hosts entry | `REMOTE HOST IDENTIFICATION HAS CHANGED!` | `ssh-keygen -R <ip>` |
| QEMU agent start confusion | enable message looks odd | agent is socket-activated; reboot validation confirmed active |
| `--full 0` typo | silent linked clone | `--full` is boolean, no value follows |

---

## Recovery Scenarios

### Production VM broken, need rebuild

**Run on:** pve-1

```bash
qm stop <VMID>
qm destroy <VMID> --purge

qm clone 9001 <VMID> --name <hostname> --full
qm set <VMID> --net0 virtio,bridge=vmbr1
qm set <VMID> --ipconfig0 ip=10.10.0.<X>/24,gw=10.10.0.1
qm set <VMID> --nameserver 1.1.1.1 --searchdomain lab.local
qm set <VMID> --ciuser tuhin --sshkeys ~/.ssh/authorized_keys_tuhin.pub
qm set <VMID> --agent enabled=1 --onboot 1
qm cloudinit update <VMID>
qm start <VMID>
```

Validate from Mac:

```bash
ssh tuhin@10.10.0.<X> 'hostname && cat /etc/machine-id'
```

---

### Template VM 9001 corrupted or lost

**Run on:** pve-1

```bash
qm clone 9000 9001 --name ubuntu-2404-hardened-wip --full
```

Then repeat:

1. boot with cloud-init
2. resize disk
3. harden
4. cleanup
5. convert to template
6. validate with test clone

---

### SSH alias breaks with host key warning

**Run on:** Mac

```bash
ssh-keygen -R 10.10.0.<X>
ssh-keygen -R <hostname-alias>
ssh tuhin@10.10.0.<X>
```

---

### VM not reachable after pve-1 reboot

**Run on:** pve-1

```bash
qm list

for vmid in 110 121 122 123 130 150; do
  qm config $vmid | grep onboot
done

qm set <VMID> --onboot 1
```

---

## Deferred Items

- **VM 9000 cleanup** — keep as rollback baseline; destroy only if storage pressure justifies it
- **QEMU agent scripted checks** — future automation with `qm guest cmd <vmid> network-get-interfaces`
- **Forward chain hardening** — Phase 4, explicit drop + logging
- **Kubernetes prerequisites** — swap off, `br_netfilter`, `overlay`, containerd are Phase 2 scope, not Phase 1 template scope
- **DNS server on svc-1** — later phase, after ingress IPs exist
- **Break-it drills** — formally Phase 7+ per original exception; Phase 3 resumed earlier
- **Template refresh** — Phase 4 priority: add `conntrack`, enable `iscsid`, mask `multipathd`, increase base disk to 60G

---

## Files committed in this phase

```text
configs/phase-1/
├── provision-vms.sh                    # mass provisioning script
├── harden.sh                           # template hardening script
├── vm-9001.config                      # hardened template dump
├── vm-110.config                       # k8s-cp-1
├── vm-121.config                       # k8s-worker-1
├── vm-122.config                       # k8s-worker-2
├── vm-123.config                       # k8s-worker-3
├── vm-130.config                       # ci-1
└── vm-150.config                       # svc-1

docs/runbooks/
├── phase-1-bn.md                       # Bangla runbook
└── phase-1-en.md                       # English runbook
```

Note:

Mac `~/.ssh/config` is not committed to Git. It is local to the operator machine.

---

## Exit Criteria — all passed

- [x] VM 9001 hardened template created and validated
- [x] VM 9000 preserved as rollback baseline
- [x] 6 production VMs provisioned per v2.5 IP plan
- [x] every VM reachable by passwordless SSH from Mac
- [x] every VM passwordless sudo works
- [x] QEMU guest agent active on all VMs
- [x] unique machine-id per VM
- [x] hostnames match v2.5 naming convention
- [x] IPs match v2.5 plan: `10.10.0.10`, `.21`, `.22`, `.23`, `.30`, `.50`
- [x] reboot persistence verified: boot + IP + SSH all survive
- [x] configs + runbook committed
- [x] SSH aliases configured from Mac, local only

---

## Final understanding

Phase 1 turned a generic Ubuntu cloud image into a reusable VM factory.

You built:

1. **Rollback baseline** with VM 9000
2. **Hardened source template** with VM 9001
3. **Repeatable production VM provisioning** with full clones
4. **SSH-ready VM fleet** from Mac
5. **Identity-safe clones** with unique machine-id and host keys
6. **Phase 2-ready infrastructure** for kubeadm bootstrap

Without this phase, Phase 2 would require manually preparing every Kubernetes node and service VM one by one.

---

*Phase 1 complete. Move on to Phase 2 — kubeadm bootstrap + Calico CNI (control plane + 3 workers).* 