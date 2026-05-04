# Phase 5 — GitLab CE on ci-1

> **Owner:** Tuhin Zaman
> **Status:** S1 + S1.5 complete · S2–S8 pending
> **Last updated:** 2026-05-02
> **Host:** ci-1 (10.10.0.30)
> **Reference plan:** Homelab Architecture v2.5 §Phase 5

---

## Overview

Phase 5 stands up the CI baseline on ci-1: GitLab CE, Runner, and Trivy. This runbook covers S1 (install + hardening) and S1.5 (tuning). S2 (HTTPS migration), S3 (Runner), and S4–S8 land in the next session.

---

## Pre-flight checks

### 1. Disk resize (D3 deviation, repeat)

ci-1 was provisioned from the template (VM 9001), but the default disk is only 13.5G — not enough for the GitLab CE Omnibus install plus registry storage. Grow the disk inline on the running VM:

```bash
# [pve]
qm snapshot 130 pre-resize-80g --description "before disk grow 13.5G -> 80G"
qm resize 130 scsi0 80G

# [ci-1]
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
df -h /     # expect 75G+ free
```

**Deviation note (D3 repeat):** The template VM 9001 disk gap (13.5G undersized) showed up again. Resized inline on the running VM. Template refresh is deferred to a separate maintenance window.

### 2. DNS verify (svc-1)

A records in `/etc/dnsmasq.d/lab.conf` follow this pattern:

- `gitlab.lab → 10.10.0.30` (already in lab.conf since Phase 4)
- Naming: `cp.lab`, `worker-N.lab`, `gitlab.lab`, `ci.lab` (no `k8s-` prefix in DNS, even though it may appear in hostnames)

```bash
# [Mac terminal]
dig +short gitlab.lab @10.10.0.50    # expect 10.10.0.30
```

### 3. sshd hardening verify (Phase 1 baseline still intact)

```bash
# [Mac terminal]
ssh ci-1 'sudo sshd -T 2>/dev/null | grep -E "^(permitrootlogin|passwordauthentication|pubkeyauthentication)"'
# permitrootlogin no, passwordauthentication no, pubkeyauthentication yes
```

**Drift noted:** `x11forwarding=yes` — non-blocking, will be cleaned up in a batch fix later (other VMs get checked at the same time).

---

## S1 — GitLab CE install

### Step 1: Prerequisites

```bash
# [ci-1]
sudo apt update
sudo apt install -y curl ca-certificates gnupg
```

### Step 2: GPG key + fingerprint verify

**Important:** The GPG key is the trust anchor — fingerprint verification is mandatory before install.

```bash
# [ci-1]
curl -fsSL https://packages.gitlab.com/gitlab/gitlab-ce/gpgkey -o /tmp/gitlab.gpgkey.asc
gpg --show-keys /tmp/gitlab.gpgkey.asc
```

**Expected fingerprint:** `F6403F6544A38863DAA0B6E03F01618A51312F3F`
**Source of truth:** https://docs.gitlab.com/omnibus/installation/

Only dearmor and install if it matches. On mismatch → STOP.

```bash
# [ci-1]
sudo gpg --dearmor -o /usr/share/keyrings/gitlab.gpg /tmp/gitlab.gpgkey.asc
echo "deb [signed-by=/usr/share/keyrings/gitlab.gpg] https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu/ noble main" | \
  sudo tee /etc/apt/sources.list.d/gitlab.list
rm /tmp/gitlab.gpgkey.asc
sudo apt update
```

### Step 3: Package install

```bash
# [ci-1]
sudo apt install -y gitlab-ce
```

**Note:** GitLab Omnibus 18.x ships with `external_url 'http://gitlab.example.com'` by default (placeholder, uncommented). Auto-reconfigure is **skipped** while the placeholder is in place — intentional behavior, so the user is forced to customize external_url.

### Step 4: external_url edit (single-line surgical)

```bash
# [ci-1]
sudo cp /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.template-original
sudo sed -i "s|^external_url 'http://gitlab.example.com'$|external_url 'http://gitlab.lab'|" /etc/gitlab/gitlab.rb
sudo diff /etc/gitlab/gitlab.rb.template-original /etc/gitlab/gitlab.rb
# expect 32c32 — single-line change
```

### Step 5: First reconfigure (irreversible)

```bash
# [ci-1]
sudo bash -o pipefail -c 'gitlab-ctl reconfigure 2>&1 | tee /var/log/gitlab/reconfigure-first-run.log'
# ~170 seconds, 630/1731 resources updated
# ends with "gitlab Reconfigured!"
```

### Step 6: Service health validation

```bash
# [ci-1]
sudo gitlab-ctl status        # 15 services, all 'run:'
sudo ss -tlnp | grep -E ':(80|22)\s'
# Bundled monitoring (9090, 9100, 9168, 9229) all bind to 127.0.0.1 by default — secure
```

### Step 7: UI smoke test

```bash
# [Mac terminal]
curl -sI http://gitlab.lab | head -5
# expect HTTP/1.1 302 Found, Location: /users/sign_in
```

---

## S1 — Post-install Hardening

### Initial root password rotation

`/etc/gitlab/initial_root_password` has a 24h TTL. Log in via browser → Edit profile → Password → change immediately.

**Secret-blind discipline:**

```bash
# [ci-1]
sudo wc -l /etc/gitlab/initial_root_password    # metadata only
sudo awk -F': ' '/^Password:/ {print "len:", length($2)}' /etc/gitlab/initial_root_password
# 44-char default in GitLab 18.x
```

Once the password change is confirmed:

```bash
# [ci-1]
sudo shred -u /etc/gitlab/initial_root_password
```

### Reconfigure log password leak audit

GitLab Omnibus warns: "credentials might be present in your log files in plain text". Verify:

```bash
# [ci-1]
sudo grep -ic "password" /var/log/gitlab/reconfigure-first-run.log
sudo grep -in "password" /var/log/gitlab/reconfigure-first-run.log | cut -c1-100
```

**Confirmed clean:** Chef Cinc Client redacts secrets (`password: ******`). The 14 password-related lines are config diffs and meta-banner only.

### Browser-side hardening (two security advisories)

GitLab 18.x self-flags two advisories on first login:

1. **Public sign-up enabled** — Admin → Settings → General → "New user account restrictions" → uncheck "Allow new user accounts"
2. **Web IDE single-origin fallback enabled (high-severity)** — Admin → Settings → General → "Web IDE" section → uncheck "Enable single origin fallback"

Save changes and both advisories disappear from the dashboard.

---

## S1.5 — Resource tuning

**Why:** The default Omnibus config is heavy (~5.5GB RAM idle on a 4C/12GB box). Once the platform Prometheus arrives in Phase 8, the bundled stack will cause duplicate scrape conflicts and add resource pressure.

### Append the tuning block

```bash
# [ci-1]
sudo cp /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.s1-baseline
sudo tee -a /etc/gitlab/gitlab.rb > /dev/null <<'EOF'

# === Phase 5 S1.5 — homelab tuning (2026-05-02) ===
prometheus_monitoring['enable'] = false
puma['worker_processes'] = 2
sidekiq['max_concurrency'] = 10
EOF
```

**Note:** The Omnibus key is `sidekiq['max_concurrency']` (not `concurrency`).

### Second reconfigure

```bash
# [ci-1]
sudo bash -o pipefail -c 'gitlab-ctl reconfigure 2>&1 | tee /var/log/gitlab/reconfigure-s1-5-tuning.log'
# ~65 seconds, 17/703 resources updated
```

### Validation

```bash
# [ci-1]
sudo gitlab-ctl status | wc -l            # 9 services (was 15, minus 6 monitoring)
ps aux | grep "puma.*worker" | grep -v grep   # exactly 2 workers + 1 master
free -h                                     # ~2.5Gi used (was 5.5Gi)
```

**Result:** RAM reclaim **~3.0GB**, services trimmed 15 → 9, ports 9090/9093/9100/9168/9229 closed.

---

## S2–S8 — Pending (next session)

### S2 — HTTPS migration (signing CA workflow)

- **Status:** pending
- **Scope:** sparsebundle mount, signing CA cert issuance for `gitlab.lab`, placement under `/etc/gitlab/ssl/`, set `external_url 'https://...'`, third reconfigure.
- **Pre-flight:** D9 monitoring on, signing.key decrypt test before sign attempt (HARD GATE A).

### S3 — Runner registration

- **Status:** pending
- **Scope:** Shell executor first (simpler), K8s executor later (Phase 6 dependency).

### S4 — Trivy install

### S5 — Sample `.gitlab-ci.yml` pipeline

### S6 — Container Registry verify

### S7 — Break-it drills (3)

### S8 — Final commit + tag (`phase-5-complete`)

---

## Deviations and state notes

| ID | Description | Status |
|---|---|---|
| D3 (repeat) | ci-1 disk inline resize 13.5G → 80G | accepted, snapshot `pre-resize-80g` retained |
| Phase 1 drift | `x11forwarding=yes` on ci-1 | deferred (batch fix across VMs) |
| Bundled monitoring | Disabled in S1.5 | revisit in Phase 8 (platform Prometheus integration) |
| D11 | Root CA encrypted key file retained on Mac (see Phase 4 CA runbook) | CLOSED (2026-05-03) |

**Backups in place (ci-1):**

- `/etc/gitlab/gitlab.rb.template-original` — vendor-untouched template
- `/etc/gitlab/gitlab.rb.s1-baseline` — post-S1, pre-S1.5
- `/var/log/gitlab/reconfigure-first-run.log.gz` — first reconfigure forensic log
- `/var/log/gitlab/reconfigure-s1-5-tuning.log` — second reconfigure log

**Snapshot (pve):**

- `pve:130 pre-resize-80g` — pre-disk-resize, retain until S2 is complete

---

*Phase 5 S1+S1.5 complete · 2026-05-02*

---

## S2 close-out lessons (2026-05-03)

### Sign zone discipline held; post-zone discipline degraded

S2 execution had two distinct discipline regions:

**Pre-zone (chunks 1-3):** 6 off-script read-only commands across path
discovery and verification. Low stakes, low impact, tolerated.

**Sign zone (chunks 4-7, sparsebundle mounted):** zero off-script
commands. Discipline held under explicit gate. HARD GATE A passed,
sign + chain + verify clean, unmount on schedule. The gate worked.

**Post-zone (chunks 8-9 boundary onward):** discipline degraded.
6+ off-script commands during security finding triage, including:
- Chain validation against local artifacts (premature, no new info)
- Sparsebundle re-mount (re-opened secret window)
- root.key decrypt (Step-9b-style, sanctioned but unauthorized this turn)
- root.key `rm` removal (irreversible, executed during explicit STOP)

**Pattern:** discipline holds when a zone is named with explicit gates
("sign zone, claude-dictated only"). Discipline degrades in regions
that are not named — even regions that ARE security-sensitive but
not labeled as such.

**Lesson:** future runbook procedure must explicitly name the
"security finding triage zone" as a discipline-equivalent zone to
the sign zone. The zone is open from the moment a finding is
identified until remediation is complete and confirmed.

### root.key online-filesystem-copy discovery (D11)

Path-discovery for chunk 9 trust store add surfaced a 7-day-old
architectural deviation: encrypted root.key file retained on Mac
online filesystem. See Phase 4 CA runbook for full D11 entry.

The discovery itself is healthy — slow systematic procedure exposed
a long-running gap. The remediation, however, ran ahead of strict
mode procedure. In strict mode the operator would have:
1. Stopped at finding identification
2. Authorized scoped triage commands one at a time
3. Confirmed sparsebundle backup BEFORE removing Mac copy

Instead the operator self-executed sparsebundle re-mount, decrypt,
and remove sequence in a single off-script burst. Outcome was
correct (sparsebundle verified, redundant copy removed) but the
process bypassed the gates that exist precisely for security ops.

Strict mode reaffirmed mid-session after this surfaced.

### Strict mode reaffirmation

After the post-zone drift, strict mode was explicitly re-locked:
- Off-script execution → halt, even if outcome looks correct
- Irreversible op gates → no exception
- Security discipline → priority over momentum
- Flow control → pre-execution, not post-hoc reconciliation

This reaffirmation now applies session-default forward, per CLAUDE.md.

### Anti-pattern locked

**"Yes/No questions in hot zones"** — when triaging an active finding,
asking the operator yes/no questions creates ambiguous gate state.
Operator may interpret silence as permission and pull ahead. Future
hot-zone triage must use **scoped prescriptive sequences**:

> "Run THIS exact 4-command sequence, paste output, then I will plan
> the next step based on what we see."

Not:
> "Is X true? Was Y verified? YES/NO?"

The first model is execution-clear. The second model leaks decision
authority into the operator's hands during a moment when claude-
dictated control is precisely what's required.

---

*Phase 5 S2 close-out · 2026-05-03*
