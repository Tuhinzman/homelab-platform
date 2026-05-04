# Phase 4 — Internal CA Lifecycle Runbook (English)

> **Version:** v4 (S6.5 — etcd encryption-at-rest closed, D8 signing CA rotation, D9 root partial-exposure logged)  
> **Last updated:** 2026-04-30  
> **Owner:** Tuhin Zaman  
> **Status:** ACTIVE — authoritative runbook for Phase 4 CA  
> **Supersedes:** S2 session's initial CA setup notes (2026-04-25)

---

## 1. Overview

Two-tier internal CA hierarchy for the homelab:

```
┌─────────────────┐
│  Root CA        │  RSA 4096, 10y validity, pathlen:1, self-signed
│  (offline)      │  Subject: Homelab Root CA
└────────┬────────┘
         │ signs
         ▼
┌─────────────────┐
│  Signing CA     │  RSA 4096, 5y validity, pathlen:0
│  (intermediate) │  Subject: Homelab Signing CA
└────────┬────────┘
         │ signs
         ▼
┌─────────────────┐
│  Workload Certs │  cert-manager issues these
│  (end-entity)   │  *.lab domains, gitlab.lab, grafana.lab, etc.
└─────────────────┘
```

### Key facts

- **Subject base DN:** `C=US, ST=NY, L=Buffalo, O=Homelab, OU=Platform`
- **Workspace:** `~/Project/homelab-secrets/` (NOT in Git, gitignored)
- **Backup:** `homelab-ca-backup-v2.sparsebundle` on SanDisk Extreme Pro 2TB
- **Distribution:** Mac System Keychain + 6 VMs (`/usr/local/share/ca-certificates/`)
- **Recovery anchor:** Paper passphrases (drawer-stored)

---

## 2. Critical Discipline Rules (Non-negotiable)

S2 failure occurred because these rules were missing. S5 locks them in.

### Rule 1 — Paper = Source of Truth

3 passphrases written on paper (drawer):
- `SPARSEBUNDLE` — volume encryption
- `ROOT-KEY` — Root CA private key encryption
- `SIGNING-KEY` — Signing CA private key encryption

**Paper is never replaced.** Memory, Keychain, password manager — none are source of truth.

### Rule 2 — Keychain Scope Discipline

| Passphrase | Mac Keychain entry? | Reason |
|---|---|---|
| SPARSEBUNDLE | ✅ Yes | Volume encryption, daily mount convenience justified |
| ROOT-KEY | ❌ NO | Private key encryption — air-gap intent, online storage = compromised root |
| SIGNING-KEY | ❌ NO | Same as above |

**Lesson:** Storing the passphrase that decrypts a private key online is functionally equivalent to not encrypting the key at all if the host is compromised.

### Rule 3 — Mini Cold-Mount Gate

After every new sparsebundle creation — **mandatory cold-mount test:**
1. Detach sparsebundle
2. `Cmd+Q` to fully quit Terminal app
3. Launch new Terminal
4. Mount with paper-typed passphrase
5. Success = passphrase actually paper-recorded
6. Failure = halt, fix paper, regenerate sparsebundle

Same-terminal mount ≠ cold-mount. OS cache may contaminate the test.

### Rule 4 — Hash Format Clarity

Two hash formats — do not confuse them:

| Tool | Output | Format |
|---|---|---|
| `shasum -a 256 file.crt` | `475558d7eac6...` | sha256 of PEM-encoded **file bytes** |
| `openssl x509 ... -fingerprint -sha256` | `AD:41:06:B3:FA:BF...` | sha256 of **DER-encoded cert body** |

Both describe the same cert but with different inputs. Use first format for file integrity check, second for cert identification. Mixing them causes false alarms.

### Rule 5 — Sequence Discipline

```
Generate → Test → Backup → Test → Distribute
```

Explicit gate at every step. Skipping = future failure.

### Rule 6 — Irreversible Op Discipline

For key generation, cert signing, distribution operations:
- "This is irreversible — confirm direction before run" — explicit pause
- Direction shift = explicit retraction ("Earlier said X — retracted, new direction Y")
- Momentum execution refused

---

## 3. Initial CA Generation (or Reset Procedure)

This section applies to both initial CA setup and future reset operations.

### Step 1 — Workspace clean / archive old

```bash
# Old CA archive (do NOT delete — safety net)
mkdir -p ~/Project/homelab-secrets-archive-$(date +%Y%m%d-%H%M)
mv ~/Project/homelab-secrets/ca ~/Project/homelab-secrets-archive-*/

# Fresh structure
mkdir -p ~/Project/homelab-secrets/ca/{root,signing,certs,csr}
```

### Step 2 — 3 paper passphrases (CRITICAL MOMENT)

EFF wordlist download (one-time):

```bash
curl -fsSL -o ~/Project/homelab-secrets/eff_large_wordlist.txt \
  https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt

shasum -a 256 ~/Project/homelab-secrets/eff_large_wordlist.txt
# Expected: <REDACTED_SHA_1>
```

Generation script (per passphrase, one at a time):

```bash
words=()
for i in 1 2 3 4 5 6; do
  roll=""
  for d in 1 2 3 4 5; do
    roll="${roll}$(jot -r 1 1 6)"
  done
  word=$(awk -v r="$roll" '$1==r {print $2}' \
    ~/Project/homelab-secrets/eff_large_wordlist.txt)
  words+=("$word")
done
echo ""
echo "================================================"
echo "LABEL: ${words[*]}"
echo "================================================"
unset words word roll
```

**Discipline per passphrase:**
1. Generate (script displays)
2. Write to paper — label first (e.g., `ROOT-KEY:`), then 6 words verbatim
3. Read-back verify char-by-char (paper vs screen)
4. `clear && printf '\e[3J'` — wipe screen and scrollback
5. Move to next passphrase

3 passphrases sequence: SPARSEBUNDLE → ROOT-KEY → SIGNING-KEY.

### Step 3 — Root CA generation

```bash
cd ~/Project/homelab-secrets/ca/root

openssl genrsa -aes256 -out root.key 4096
# Prompt 2x — type ROOT-KEY from paper

chmod 600 root.key

openssl req -x509 -new -nodes -key root.key -sha256 \
  -days 3650 \
  -out root.crt \
  -subj "/C=US/ST=NY/L=Buffalo/O=Homelab/OU=Platform/CN=Homelab Root CA" \
  -extensions v3_ca \
  -config <(cat <<EOF
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
EOF
)
# Prompt 1x — type ROOT-KEY from paper
```

### Step 4 — HARD GATE A — root.key decrypt test

```bash
openssl rsa -in root.key -noout -check
# Expected: "RSA key ok", exit code 0
```

**Failure = halt. Redo Step 3.**

### Step 5 — Signing CA generation

```bash
cd ~/Project/homelab-secrets/ca/signing

# 5a: signing private key
openssl genrsa -aes256 -out signing.key 4096
chmod 600 signing.key

# 5b: CSR
openssl req -new -key signing.key -out signing.csr \
  -subj "/C=US/ST=NY/L=Buffalo/O=Homelab/OU=Platform/CN=Homelab Signing CA"

# 5c: Extension config file
cat > signing.ext <<'EXT_EOF'
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EXT_EOF

# 5d: Root signs the CSR
openssl x509 -req \
  -in signing.csr \
  -CA ~/Project/homelab-secrets/ca/root/root.crt \
  -CAkey ~/Project/homelab-secrets/ca/root/root.key \
  -CAcreateserial \
  -CAserial ~/Project/homelab-secrets/ca/root/root.srl \
  -days 1825 \
  -sha256 \
  -extfile signing.ext \
  -out signing.crt
# Prompt 1x — type ROOT-KEY (NOT SIGNING-KEY) from paper
```

### Step 6 — HARD GATE B — signing.key decrypt test

```bash
openssl rsa -in signing.key -noout -check
# Expected: "RSA key ok", exit code 0
```

### Step 7 — Chain build + verify

```bash
cd ~/Project/homelab-secrets/ca

cat signing/signing.crt root/root.crt > certs/homelab-ca-chain.crt
cp root/root.crt certs/homelab-root-ca.crt
chmod 644 certs/homelab-root-ca.crt

openssl verify -CAfile root/root.crt signing/signing.crt
openssl verify -CAfile root/root.crt certs/homelab-ca-chain.crt
# Both: OK
```

### Step 8 — Sparsebundle backup (with mini cold-mount gate)

```bash
# 8a: Detach existing
hdiutil detach /Volumes/homelab-ca-backup 2>/dev/null

# 8b: Create new sparsebundle
hdiutil create \
  -size 100g \
  -fs APFS \
  -encryption AES-256 \
  -volname homelab-ca-backup \
  -type SPARSEBUNDLE \
  "/Volumes/Tuhin's 2TB/homelab-ca-backup-v2.sparsebundle"

# 8c: MINI COLD-MOUNT GATE (mandatory)
hdiutil detach /Volumes/homelab-ca-backup
# Cmd+Q Terminal app, fresh Terminal launch (manual)
hdiutil attach "/Volumes/Tuhin's 2TB/homelab-ca-backup-v2.sparsebundle"
# Paper-typed SPARSEBUNDLE — failure = halt

# 8d: Artifact copy
cp -Rp ~/Project/homelab-secrets/ca /Volumes/homelab-ca-backup/

# 8e: Permission restore
chmod 644 /Volumes/homelab-ca-backup/ca/certs/*.crt
chmod 644 /Volumes/homelab-ca-backup/ca/root/root.crt
chmod 644 /Volumes/homelab-ca-backup/ca/root/root.srl
chmod 644 /Volumes/homelab-ca-backup/ca/signing/signing.crt
chmod 644 /Volumes/homelab-ca-backup/ca/signing/signing.csr
chmod 644 /Volumes/homelab-ca-backup/ca/signing/signing.ext
chmod 600 /Volumes/homelab-ca-backup/ca/root/root.key
chmod 600 /Volumes/homelab-ca-backup/ca/signing/signing.key

# 8f: sha256 verify (workspace vs backup)
diff <(find ~/Project/homelab-secrets/ca -type f | sort | xargs shasum -a 256 | awk '{print $1}') \
     <(find /Volumes/homelab-ca-backup/ca -type f | sort | xargs shasum -a 256 | awk '{print $1}')

# 8g: Detach for Gate C
hdiutil detach /Volumes/homelab-ca-backup
```

### Step 9 — HARD GATE C — Full restore drill

**Cmd+Q Terminal, fresh Terminal launch.**

```bash
# 9a: Cold mount with paper-typed SPARSEBUNDLE
hdiutil attach "/Volumes/Tuhin's 2TB/homelab-ca-backup-v2.sparsebundle"

# 9b: Backup root.key paper-typed decrypt
openssl rsa -in /Volumes/homelab-ca-backup/ca/root/root.key -noout -check

# 9c: Backup signing.key paper-typed decrypt
openssl rsa -in /Volumes/homelab-ca-backup/ca/signing/signing.key -noout -check

# 9d: Backup chain verification
openssl verify -CAfile /Volumes/homelab-ca-backup/ca/root/root.crt \
  /Volumes/homelab-ca-backup/ca/signing/signing.crt
openssl verify -CAfile /Volumes/homelab-ca-backup/ca/root/root.crt \
  /Volumes/homelab-ca-backup/ca/certs/homelab-ca-chain.crt

# 9e: Cleanup
hdiutil detach /Volumes/homelab-ca-backup
```

### Step 10 — Distribution (Mac + 6 VMs)

**Mac System Keychain:**

```bash
sudo security delete-certificate \
  -Z OLD_SHA1_HASH \
  /Library/Keychains/System.keychain

sudo security add-trusted-cert \
  -d \
  -r trustRoot \
  -k /Library/Keychains/System.keychain \
  -p ssl \
  ~/Project/homelab-secrets/ca/certs/homelab-root-ca.crt
```

**6 VMs (loop):**

```bash
VMS=(
  "10.10.0.10:k8s-cp-1"
  "10.10.0.21:k8s-worker-1"
  "10.10.0.22:k8s-worker-2"
  "10.10.0.23:k8s-worker-3"
  "10.10.0.30:ci-1"
  "10.10.0.50:svc-1"
)

set -euo pipefail
CERT=~/Project/homelab-secrets/ca/certs/homelab-root-ca.crt
SIGNING=~/Project/homelab-secrets/ca/signing/signing.crt
EXPECTED_HASH=$(shasum -a 256 "$CERT" | awk '{print $1}')

for entry in "${VMS[@]}"; do
  IP="${entry%%:*}"
  HOST="${entry##*:}"
  echo "=== $HOST ($IP) ==="

  scp -q "$CERT" "tuhin@${IP}:/tmp/homelab-root-ca.crt"
  scp -q "$SIGNING" "tuhin@${IP}:/tmp/signing.crt"

  REMOTE_HASH=$(ssh "tuhin@${IP}" "sha256sum /tmp/homelab-root-ca.crt | awk '{print \$1}'")
  [[ "$REMOTE_HASH" == "$EXPECTED_HASH" ]] || { echo "FATAL: hash mismatch on $HOST"; exit 1; }

  ssh "tuhin@${IP}" "sudo cp /tmp/homelab-root-ca.crt /usr/local/share/ca-certificates/ && \
                     sudo chmod 644 /usr/local/share/ca-certificates/homelab-root-ca.crt && \
                     sudo chown root:root /usr/local/share/ca-certificates/homelab-root-ca.crt && \
                     sudo update-ca-certificates --fresh"

  VERIFY=$(ssh "tuhin@${IP}" "openssl verify -CApath /etc/ssl/certs /tmp/signing.crt")
  [[ "$VERIFY" == *"OK"* ]] || { echo "FATAL: chain verify failed on $HOST"; exit 1; }

  ssh "tuhin@${IP}" "rm -f /tmp/homelab-root-ca.crt /tmp/signing.crt"
done
```

### Step 11 — Sparsebundle Keychain entry (CONVENIENCE ONLY)

**Only the sparsebundle passphrase goes into Keychain. Root + Signing key passphrases NEVER.**

```bash
read -rs "PASS?SPARSEBUNDLE passphrase (from paper): "
echo ""

security add-generic-password \
  -s "homelab-ca-sparsebundle-passphrase" \
  -a "tuhin" \
  -w "$PASS" \
  -j "Sparsebundle volume passphrase. Paper = source of truth. Created $(date '+%Y-%m-%d')." \
  -U \
  ~/Library/Keychains/login.keychain-db

unset PASS
```

**ROOT-KEY and SIGNING-KEY are NEVER stored in Keychain.** Paper-only.

---

## 4. Recovery Procedure

**Scenario:** Mac dies tonight. SanDisk + paper survive. New Mac.

```bash
# 1. Attach SanDisk to new Mac
# 2. Mount sparsebundle (paper-typed SPARSEBUNDLE)
hdiutil attach "/Volumes/Tuhin's 2TB/homelab-ca-backup-v2.sparsebundle"

# 3. Workspace restore
mkdir -p ~/Project/homelab-secrets/
cp -Rp /Volumes/homelab-ca-backup/ca ~/Project/homelab-secrets/

# 4. Permission restore
chmod 600 ~/Project/homelab-secrets/ca/root/root.key
chmod 600 ~/Project/homelab-secrets/ca/signing/signing.key

# 5. Decrypt verify (paper-typed)
openssl rsa -in ~/Project/homelab-secrets/ca/root/root.key -noout -check
openssl rsa -in ~/Project/homelab-secrets/ca/signing/signing.key -noout -check

# 6-8. Mac trust store install + 6 VMs distribution + Keychain entry (sparsebundle only)
# Follow Step 10 + Step 11 procedure above
```

**Time estimate:** ~30 min for full recovery.

---

## 5. Lessons Learned (from 2026-04-26 reset)

### S2 failure cause

In S2, the root CA was generated, but the **immediate decrypt test was skipped** at the passphrase generation moment, so it was never verified that what was typed matched what was recorded on paper. Result: `root.key` permanently locked, S2 backup useless (containing the same locked file).

### What S5 changed

| Lesson | S5 Implementation |
|---|---|
| Generation moment unverified | HARD GATE A + B immediately after each key generation |
| Backup integrity ≠ key recoverability | HARD GATE C — actual paper-only restore drill |
| Same-terminal "drill" not real | Mini cold-mount gate via Cmd+Q + fresh Terminal |
| Online passphrase = compromised root | Keychain scope rule (sparsebundle only) |
| Mixed hash format confusion | Explicit hash format documentation |

### Permanent rules going forward

1. After generating any private key, **immediate decrypt test mandatory**
2. After creating any backup, **cold-mount gate from fresh Terminal mandatory**
3. Private key passphrases — **online storage prohibited**
4. When rewriting paper — old paper crossed-out + new paper, same drawer
5. EFF wordlist sha256 verify on every download

---

## 6. Reference

### File paths

```
~/Project/homelab-secrets/                 # Workspace (gitignored)
├── ca/
│   ├── root/
│   │   ├── root.key                       # 600, encrypted RSA 4096
│   │   ├── root.crt                       # 644, self-signed root
│   │   └── root.srl                       # 644, serial ledger
│   ├── signing/
│   │   ├── signing.key                    # 600, encrypted RSA 4096
│   │   ├── signing.crt                    # 644, signed by root
│   │   ├── signing.csr                    # 644, audit reference
│   │   └── signing.ext                    # 644, extension config
│   └── certs/
│       ├── homelab-ca-chain.crt           # 644, signing+root concatenated
│       └── homelab-root-ca.crt            # 644, distribution-ready
└── eff_large_wordlist.txt                 # EFF dice-rolled wordlist

/Volumes/Tuhin's 2TB/                      # SanDisk Extreme Pro
├── homelab-ca-backup-v2.sparsebundle      # ACTIVE backup (S5)
└── homelab-ca-backup.sparsebundle.old     # DEAD archive (S2, passphrase lost)
```

### Hosts with root.crt installed

| Host | Path |
|---|---|
| Mac | System Keychain ("Homelab Root CA") |
| svc-1 (10.10.0.50) | `/usr/local/share/ca-certificates/homelab-root-ca.crt` |
| k8s-cp-1 (10.10.0.10) | same |
| k8s-worker-1 (10.10.0.21) | same |
| k8s-worker-2 (10.10.0.22) | same |
| k8s-worker-3 (10.10.0.23) | same |
| ci-1 (10.10.0.30) | same |

### Naming conventions

- Service names: `homelab-ca-<purpose>-passphrase`
- Subject DN: `C=US, ST=NY, L=Buffalo, O=Homelab, OU=Platform, CN=<role>`
- Sparsebundle volume: `homelab-ca-backup` (mount path constant across versions)

### Hash formats

- **`shasum -a 256 file.crt`** = sha256 of PEM file bytes (e.g., `475558d7eac6...`)
- **`openssl x509 ... -fingerprint -sha256`** = sha256 of DER cert body (e.g., `AD:41:06:B3:FA:BF...`)
- Both describe the same cert but with different inputs

### Drill log location

`docs/runbooks/phase-4/drills/` — actual reset events documented chronologically.

---

## 7. S6 — cert-manager + first issuance proof

> **Date:** 2026-04-28
> **Scope:** Step 5 — first leaf certificate issuance + external chain verification
> **Status:** PASS (openssl verify exit 0)
> **Steps 1–4 audit trail:** commits `cc5113f` (helm values), `eda8acc` (ClusterIssuer manifest), `30bfcfb` (test Certificate manifest)

### Why Step 5 needed a separate proof

Steps 1–4 (cert-manager Helm install, ClusterIssuer creation, signing CA Secret distribution) are all cluster-internal plumbing. ClusterIssuer `Ready=True` only proves cert-manager controller successfully loaded the signing CA Secret — that is **self-attestation**, not cryptographic correctness.

Step 5 is the first end-to-end test:
- Apply a Certificate resource
- cert-manager signs the leaf with the signing CA
- Leaf Secret materializes
- openssl verifies the chain against the backed-up root.crt

`openssl verify exit 0` = PKI cryptographically correct end-to-end. Anything less = S2-style root-cause investigation.

### Pre-flight (must be green before Step 5 starts)

- `kubectl get pods -n cert-manager` — three pods (controller, webhook, cainjector) all Running
- `kubectl get clusterissuer homelab-signing-ca` — READY=True, status "Signing CA verified", reason KeyPairVerified
- Signing CA Secret intact: `kubectl get secret homelab-signing-ca -n cert-manager` — keys `tls.crt` and `tls.key` present, base64 sizes plausible (cert ~2768, RSA-4096 key ~4360)

### Test Certificate manifest

File: `k8s/cert-manager/test-certificate.yaml` (commit `30bfcfb`)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: cert-manager
spec:
  commonName: test.lab
  dnsNames:
    - test.lab
  duration: 24h
  renewBefore: 12h
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  issuerRef:
    name: homelab-signing-ca
    kind: ClusterIssuer
    group: cert-manager.io
  secretName: test-cert-tls
```

**Design choices locked:**
- `rotationPolicy: Always` — fresh private key on every renewal. Project default standard going forward. `Never` (key reuse on renewal) is weaker production posture.
- `size: 2048` — leaf cert standard. 4096 reserved for CAs only.
- `duration: 24h` — short test cert; will not pollute renewal queue.
- Namespace `cert-manager` — test artifacts adjacent to issuer for easy cleanup.

### Apply + progression

```bash
# [k8s-cp-1]
kubectl apply -f k8s/cert-manager/test-certificate.yaml
kubectl wait --for=condition=Ready certificate/test-cert -n cert-manager --timeout=60s
```

**Expected timeline (CA issuer):** Ready=True within 5–15 seconds. Not long-running like ACME issuers.

**Event sequence (from describe):**
1. `Issuing` — cert-manager-certificates-trigger detects Certificate
2. `Generated` — cert-manager-certificates-key-manager stores private key in temporary Secret
3. `Requested` — CertificateRequest resource spawned
4. `Issuing` — "Certificate has been successfully issued"

### Negative validation (what must NOT spawn)

CA issuer = NOT ACME. Therefore:

```bash
# [k8s-cp-1]
kubectl get orders,challenges -n cert-manager
# Expected: "No resources found"
```

If Order or Challenge resources spawn = ClusterIssuer misconfigured as ACME → design bug, RCA mandatory.

### Leaf Secret structure (cert-manager default behavior)

```bash
# [k8s-cp-1]
kubectl get secret test-cert-tls -n cert-manager -o jsonpath='{.data}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('keys present:', sorted(d.keys()))
for k in sorted(d.keys()):
    print(f'  {k} b64 len: {len(d[k])}')
"
```

**Expected output:**
```
keys present: ['ca.crt', 'tls.crt', 'tls.key']
  ca.crt b64 len: 2768       # signing CA cert
  tls.crt b64 len: 4880      # leaf + signing CA bundled (2-cert PEM)
  tls.key b64 len: 2240      # RSA-2048 private key
```

**Critical learning:** cert-manager bundles the leaf + intermediate (signing CA) inline in `tls.crt` by default. The `tls.crt` size is roughly 3x a pure leaf because the chain is included. This benefits production applications — TLS servers load the chain already attached.

### Chain verification — THE proof

**Why on Mac, not in cluster:**
- Backed-up `root.crt` lives on Mac, paper-trusted source of truth
- Pulling root.crt into cluster blurs trust boundary
- Air-gap intent maintained (root CA isolation rule)

```bash
# [Mac terminal]
# Pre-flight: root.crt readable, self-signed verify
ls -la ~/Project/homelab-secrets/ca/certs/homelab-root-ca.crt
openssl x509 -in ~/Project/homelab-secrets/ca/certs/homelab-root-ca.crt -noout -subject -issuer
# Expected: subject == issuer (self-signed root)

# Pull bundle from cluster
kubectl get secret test-cert-tls -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/test-cert-bundle.pem

# Cert count
grep -c 'BEGIN CERTIFICATE' /tmp/test-cert-bundle.pem
# Expected: 2 (leaf + intermediate)

# Chain inspection
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' /tmp/test-cert-bundle.pem | \
  openssl crl2pkcs7 -nocrl -certfile /tmp/test-cert-bundle.pem | \
  openssl pkcs7 -print_certs -noout | grep -E 'subject|issuer'

# Expected output:
# subject=CN=test.lab                                     ← leaf
# issuer=...CN=Homelab Signing CA                         ← issued by signing CA
# subject=...CN=Homelab Signing CA                        ← intermediate
# issuer=...CN=Homelab Root CA                            ← issued by root

# THE verify
openssl verify \
  -CAfile ~/Project/homelab-secrets/ca/certs/homelab-root-ca.crt \
  -untrusted /tmp/test-cert-bundle.pem \
  /tmp/test-cert-bundle.pem
echo "exit code: $?"

# Expected:
# /tmp/test-cert-bundle.pem: OK
# exit code: 0
```

**Pass criteria — strict:**
- ✅ `OK` output
- ✅ `exit code: 0`
- ❌ Any warning ("unable to get issuer", "self signed in chain", "expired") = FAIL

`openssl verify` is smart enough to: take the leaf from the main input, pull intermediates from `-untrusted`, and walk the chain to the `-CAfile` trust anchor. The bundle serves dual purposes (input + untrusted source) — no need to split into separate files.

### Cleanup (mandatory after Step 5)

```bash
# [k8s-cp-1]
kubectl delete certificate test-cert -n cert-manager

# Cascade verify — Certificate and CertificateRequest deleted, but Secret survives!
kubectl get certificate test-cert -n cert-manager 2>&1     # NotFound
kubectl get certificaterequest test-cert-1 -n cert-manager 2>&1  # NotFound (cascade worked)
kubectl get secret test-cert-tls -n cert-manager 2>&1      # STILL EXISTS

# Manual Secret delete required
kubectl delete secret test-cert-tls -n cert-manager
```

```bash
# [Mac terminal]
rm /tmp/test-cert-bundle.pem
```

### Critical learning — cert-manager owner reference asymmetry

**cert-manager default behavior (Helm flag `--enable-certificate-owner-ref=false`):**

| Resource | Owner ref to Certificate? | Cascade on delete? |
|---|---|---|
| `CertificateRequest` | ✅ Yes | ✅ Auto-deleted |
| `Secret` (leaf) | ❌ **No** | ❌ **Manual delete required** |

**Why this asymmetric design:**
- Production scenario: someone accidentally deletes a Certificate resource
- Secret survives so downstream Pods and ingresses keep TLS working
- Manual recovery window — accidental deletion does not cause instant outage
- This default is actually safer; setting the flag to true enables aggressive cleanup behavior

**Lesson:** Never assume "cascade will handle it" in clusters. Always verify with explicit `kubectl get` post-delete sweep. Caught Secret survival today by doing exactly this.

### Today's six durable learnings

1. **`Certificate Ready=True ≠ chain valid`** — cluster-internal self-attestation and external cryptographic proof are different signals at different bars. In production, "cert-manager works fine, look Ready=True" is insufficient; always demand external `openssl verify`.

2. **cert-manager bundles chain in `tls.crt` by default** — expect a 2-cert PEM bundle (leaf + signing CA), not leaf-only. Application TLS load logic must accommodate this.

3. **cert-manager Secret has no owner reference by default** — cascade delete will not work. Explicit cleanup needed. Setting `--enable-certificate-owner-ref=true` changes behavior, but the default is safer.

4. **CertificateRequest does have owner reference** — Certificate deletion cascades to it. Asymmetric ownership: CertReq tied, Secret decoupled.

5. **External paste / IDE-edit discipline** — if you edit a file in an IDE after a heredoc write, mention the change explicitly before committing. Today's `rotationPolicy: Never → Always` change was caught via SHA-256 hash diff. Process discipline kept us safe.

6. **"Display ≠ data" twice today** — chat markdown auto-link rendering false-alarmed corruption twice. `xxd` and `shasum -a 256` both proved the file bytes were clean. Future: do not second-guess chat display; bytes don't lie.

### D7 status check (post-Step 5)

- D7 still **OPEN**
- Closure deadline: 2026-05-10
- ~12 days remaining
- Step 5 did not worsen D7 (signing.key was already plaintext in etcd; this Step exposed nothing new)
- **Next session priority:** S6.5 — etcd encryption-at-rest enablement

### S6 declared complete

Steps 1–5 all verified, audit trail committed to Git:
- `cc5113f` — cert-manager Helm values
- `eda8acc` — ClusterIssuer manifest
- `30bfcfb` — test Certificate manifest

**Phase 4 progression unblocked → S6.5 (D7 closure) next.**

---

## 8. S6.5 — etcd Encryption-at-Rest + D7 closure (2026-04-30)

### 8.1 Scope summary

Deviation D7 was explicitly accepted at S6 close-out (2026-04-26 → 2026-04-28): the signing CA private key was stored plaintext in etcd, with encryption-at-rest planned for a later session. S6.5 is that closure session.

**Locked deadline:** 2026-05-10 (D7 acceptance window)  
**Actual closure:** 2026-04-30, ~22:00 EDT

S6.5 core components:

- Step 5b: enable `--encryption-provider-config` flag in kube-apiserver static pod manifest
- Step 6: re-encrypt all existing Secrets in the cluster (rewrite etcd values as ciphertext)
- Drill 1: apiserver pod recovery — manifest persistence verification
- Drill 2: WITH key → validate kubectl decrypt path (recovery path)
- Drill 3: WITHOUT key → opaque ciphertext (D7 closure proof, negative control)
- D8 (added mid-session): signing CA private key leaked during Drill 2; rotation executed same session
- D9 (added mid-session): root CA private key partial display incident — OPEN, not closed

**Three forensic etcd snapshots from this session** (audit timeline):

| Snapshot | Time | State |
|---|---|---|
| `pre-s6.5-20260430-190106.db` | 19:01 | Plaintext Secrets, pre-Step-5b rollback insurance |
| `post-s6.5-20260430-195002.db` | 19:50 | Ciphertext with COMPROMISED signing CA bytes (pre-rotation) |
| `post-rotation-20260430-204348.db` | 20:43 | Ciphertext with rotated signing CA bytes |

### 8.2 Step 5b — kube-apiserver manifest edit (irreversibility gate)

**Goal:** instruct apiserver to encrypt Secret-class objects before storing in etcd. Static pod manifest edits are auto-detected by kubelet inotify, triggering an apiserver restart cycle.

**Pre-edit state captured:**

- Manifest backup: `/root/k8s-manifest-backups/kube-apiserver.yaml.preS6.5.20260430-190233`
- Backup SHA: `<REDACTED_SHA_2>`
- Fresh etcd snapshot: `/var/lib/etcd-snapshots/pre-s6.5-20260430-190106.db`

**Edit pattern (3 surgical insertions, alphabetical positioning preserved):**

1. `--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml` flag → after `--enable-bootstrap-token-auth`, before `--etcd-cafile`
2. `volumeMount` entry for `k8s-enc` → after `k8s-certs`, before `usr-local-share-ca-certificates`
3. `volume` entry for `k8s-enc` (hostPath, DirectoryOrCreate) → same alphabetical position as mount

**Validation gates before live apply:**

- YAML parse OK (Python `yaml.safe_load`)
- Diff against backup: exactly **8 lines added, 0 removed**
- Indentation matches surrounding entries (verified byte-by-byte)
- volume count 5 → 6, volumeMount count 5 → 6, command flag count 27 → 28

**Apply mechanism:** atomic `mv` from staging path `/etc/kubernetes/staging/kube-apiserver.yaml.edit` to `/etc/kubernetes/manifests/kube-apiserver.yaml` (same filesystem, single inotify event). NEVER edit in place — kubelet could catch partial writes.

**Recovery timing observed:**

- T+0s: `mv` executed (19:09)
- T~10s: API connection refused (apiserver pod terminating)
- T~12s: new pod Pending → Running
- T~21s: readiness probe passes, `1/1 Running`
- **Total downtime: ~21 seconds** (within the 30-60s expected window)

**Post-restart proof:**

- `--encryption-provider-config` flag visible in `ps -ef | grep kube-apiserver`
- `crictl inspect` shows `/etc/kubernetes/enc` hostPath mount, readonly
- `/healthz: ok`

**Workload impact during apiserver restart:** leader-election-bound controllers restarted (cert-manager, longhorn CSI provisioner/attacher/resizer/snapshotter — one replica each, the leader). Data plane (workers, ingress, MetalLB speakers, longhorn engines, non-leader CSI replicas) untouched. Standard pattern, no remediation needed.

### 8.3 Step 6 — re-encrypt existing Secrets (point of no return)

**Goal:** the Step 5b apiserver flag means only **new writes** are encrypted. Secrets already in etcd as plaintext (including the S6-era signing CA) must be rewritten through the apiserver's encryption envelope. A `kubectl get | kubectl replace` round-trip is the cleanest path: zero workload side effects (Secret content is byte-identical), only the etcd storage representation flips.

**Pre-Step-6 etcd state (the photographic proof of D7):**

Raw bytes of `/registry/secrets/cert-manager/homelab-signing-ca` in etcd:

```text
Offset 0x34: 6b 38 73 00              "k8s\x00"  (plaintext magic)
Offset 0x38: protobuf TypeMeta v1, kind: Secret
Offset 0x4c: "homelab-signing-ca"     READABLE
Offset 0x5b: "cert-manager"           READABLE
Offset 0x73: UID 1ceab968-...         READABLE
```

Anyone with etcd access (cp-1 root, a stolen snapshot file) could read this directly. **This was D7.**

**Execute:**

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

**Result:** 11 Secrets replaced cleanly:

- cert-manager: cert-manager-webhook-ca, homelab-signing-ca, sh.helm.release.v1.cert-manager.v1
- ingress-nginx: ingress-nginx-admission, sh.helm.release.v1.ingress-nginx.v1
- longhorn-system: longhorn-webhook-ca, longhorn-webhook-tls, sh.helm.release.v1.longhorn.v1
- metallb-system: metallb-memberlist, metallb-webhook-cert, sh.helm.release.v1.metallb.v1

**Post-Step-6 etcd state (encryption envelope):**

```text
Offset 0x34: "k8s:enc:aescbc:v1:key1:"   (encryption marker)
Offset 0x4b onwards: random ciphertext (22 90 71 43 75 03 0f...)
```

The etcd key path still includes namespace/name by design, but the stored value payload no longer exposes object metadata or Secret data.

**Critical learning — `kubectl replace` is the right idiom for encryption migration:**

- `apply` performs three-way merge; may skip writes if "no semantic change"
- `replace` forces a full PUT; apiserver routes through the encryption provider
- `get -o json | replace -f -` is idempotent: re-running after partial failure completes the rest

**Why kube-system has zero Secrets in modern kubeadm:** ServiceAccount tokens use `BoundServiceAccountTokenVolume` (projected, not Secret-backed) since k8s 1.22+. There are no legacy SA Secrets in kube-system; spot-check there returns an empty list.

**Workload sanity post-Step-6:** Secret content is byte-identical pre/post (only the etcd representation changed). Pods consuming Secret volumes see the same data, no restart is triggered. Verified: cert-manager, ingress-nginx, longhorn, and metallb pods all stable, no restarts traceable to Step 6.

### 8.4 Drill 1 — apiserver pod recovery (operational)

**Goal:** Step 5b was the cluster's first boot of apiserver-with-encryption. Drill 1 proves that future apiserver crash/restart cycles persistently load the encryption config — i.e. the static pod manifest is the durable source of truth and runtime state is ephemeral.

**Method:** delete the apiserver container directly at the containerd layer (`crictl rm -f`). The kubelet inotify watch detects the missing container under the static pod spec and recreates it from the manifest. This is a harsher stress test than `kubectl delete pod` — actual container destruction, not graceful pod termination.

**Procedure:**

```bash
# [k8s-cp-1]
CID=$(sudo crictl ps --name kube-apiserver -q)
sudo crictl rm -f "$CID"
```

**Recovery timeline:**

- 23:31:26 UTC: container killed
- 23:31:35 UTC: new container ready (`1/1 Running`)
- **Total: ~9 seconds**

**Verification gates:**

- New container ID differs from killed (`56a4e080...` → `4458e1aeca5ef...`)
- Static pod identity preserved (Pod ID `bf6fa62f41813` unchanged)
- `--encryption-provider-config` flag present in new container args
- `/healthz: ok` after recovery
- etcd peek post-restart: `k8s:enc:aescbc:v1:key1:` prefix unchanged → encryption persisted

**Subtle behavior — kubelet restart count semantics:**
`crictl rm -f` deletes the container at the containerd level. The kubelet's view becomes: "spec defines a container, runtime has none, create from manifest" → ATTEMPT 0, fresh creation. The Pod restart count is NOT incremented. A real apiserver crash (process exit) goes through the kubelet's restart loop and DOES bump the count. Both are legitimate recovery paths; this drill exercised the more drastic one.

**Result:** Drill 1 PASS — the static pod manifest is the durable source of truth for encryption configuration. Future apiserver disruptions self-heal with encryption intact.

### 8.5 Drill 2 — kubectl GET with key (recovery path validation)

**Goal:** prove that with the encryption key present, apiserver transparently decrypts Secrets from etcd ciphertext and returns plaintext to legitimate kubectl clients. This is the core of any real-world disaster recovery scenario: if cp-1 dies, fresh node + restored etcd + apiserver bring-up + key bundle = a functionally readable cluster.

**Setup (svc-1, isolated drill rig):**

- Standalone etcd v3.5.24 on `127.0.0.1:12379`, restored from `post-s6.5-20260430-195002.db`
- Standalone kube-apiserver v1.31.14 on `127.0.0.1:16443`, encryption-config + key transferred from cp-1 via Mac SSH pipe (no Mac disk write)
- Self-signed drill PKI: drill CA + apiserver server cert + admin client cert + SA signing keypair, all 1-day validity, under `/tmp/drill/pki/`
- kubeconfig pointing at drill apiserver with admin client cert auth
- Cluster ID `21f162d43af91e2d` ≠ prod cluster ID (isolation confirmed)

**Pre-drill substrate verification:**

- etcd raw query on the drill rig: `k8s:enc:aescbc:v1:key1:` prefix + ciphertext (NOT plaintext) → confirms post-Step-6 snapshot integrity was preserved through the Mac-piped transfer and restore cycle
- SHA-256 of all three encryption artifacts (config, key, snapshot) verified byte-exact between cp-1 and svc-1

**Execution:**

```bash
# [svc-1]
sudo kubectl --kubeconfig /tmp/drill/kubeconfig.yaml \
  -n cert-manager get secret homelab-signing-ca -o yaml | head -30
```

**Result:** PEM cert + key data returned in YAML; all 11 cluster Secrets enumerable; end-to-end decryption path proven.

**🔴 DISCIPLINE FAILURE — Drill 2 leak finding:**

The dictated command `... -o yaml | head -30` was intended as a "secret-blind" peek. YAML inline-base64 format puts ALL of `tls.crt` on a single (very long) line and ALL of `tls.key` on a single line. `head -30` truncates by **lines, not characters** — so the full base64-encoded `tls.crt` AND `tls.key` of the production `homelab-signing-ca` were emitted to:

- svc-1 terminal scrollback
- The Mac terminal (where the chat client runs) scrollback
- The chat transcript itself (persistent, off-host)

This was the same trap as the `encryption-key.txt` verify-command leak from 2026-04-29 (ref: §6 last entry, where the secret-blind rule was first locked). **The rule was correctly defined but incompletely applied** — secret-blind discipline existed for on-disk encryption-config files but was not extended to K8s Secret data displayed via `kubectl`.

**The cleaner Drill 2 proof (locked for future use):**

```bash
# Subject DN proves cert decoded — no PEM body
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -subject -issuer -fingerprint -sha256

# Key length proof — no bytes
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.tls\.key}' | \
  base64 -d | wc -c

# OpenSSL parse-and-validate the key WITHOUT printing it
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.tls\.key}' | \
  base64 -d | openssl pkey -in /dev/stdin -noout -check
```

**Threat model assessment of the leaked signing CA private key:**

- Lab-only signing CA, never connected to public PKI
- Threat surface: Anthropic chat infrastructure, Mac terminal scrollback
- Decision: rotate immediately (deviation D8 opened)
- Decision logic: principle-based (`leaked = compromised = rotate`), not risk-based — applied consistently to maintain a clean discipline anchor for future incidents

### 8.6 Drill 3 — kubectl GET without key (D7 closure proof)

**Goal:** the strongest possible proof that encryption-at-rest is mathematically real, not just configured. Negative control: same etcd substrate, same apiserver setup, but the encryption key replaced with a wrong (random) value. If apiserver still returns plaintext, the encryption configuration is broken; if apiserver fails to decrypt, encryption is real.

**Setup correction (mid-drill flaw caught):**

The first Drill 3 attempt shredded `/tmp/drill/enc/encryption-key.txt` and restarted apiserver, expecting decryption failure. **Apiserver started cleanly and `/healthz` returned `ok`.**

**Root cause analysis:** the `EncryptionConfiguration` schema inlines the key bytes directly:

```yaml
providers:
  - aescbc:
      keys:
        - name: key1
          secret: <base64 of 32-byte AES-256 key>   # key bytes HERE, inline
  - identity: {}
```

`encryption-key.txt` was the audit source of truth (paper-trail anchor for SHA verification), but **apiserver does not read it at runtime** — apiserver reads `encryption-config.yaml` once at startup and caches the inlined key in memory. Shredding `encryption-key.txt` had zero operational impact on the running apiserver.

**Corrected Drill 3 setup:**

1. Stop the drill apiserver
2. Use Python `yaml.safe_load` → modify `providers[0].aescbc.keys[0].secret` to `base64(os.urandom(32))` → `yaml.safe_dump` to `encryption-config-wrong.yaml` (secret-blind: `print("secret_printed:", False)` assertion)
3. Restart apiserver pointing at `encryption-config-wrong.yaml`
4. Apiserver booted cleanly (config syntactically valid, key still inline)

**Execution:**

```bash
# [svc-1]
sudo kubectl --kubeconfig /tmp/drill/kubeconfig.yaml \
  -n cert-manager get secret homelab-signing-ca -o name
```

**Result:**

```text
Error from server (InternalError): Internal error occurred: invalid padding on input
```

**Why this proves encryption:** AES-CBC decrypt with the wrong key produces junk plaintext bytes; PKCS#7 padding validation fails because the trailing bytes are not valid padding markers. Apiserver propagates the cryptographic error rather than returning Secret content. Without correct key bytes, no plaintext recovery is possible — D7 closure proven.

**Discipline note (positive deviation):** owner used Python YAML manipulation instead of the shell `cat <<EOF` heredoc dictated by Claude. The Python approach was structurally cleaner (no shell quoting, structured-data assertions, explicit secret-blind print assertion) and preserved the original `encryption-config.yaml` byte-for-byte by writing a separate `-wrong.yaml`. Logged as a positive deviation; pattern adopted for the runbook (use structured-language tools over shell heredoc when handling sensitive material).

**Drill 3 Result:** PASS — D7 cryptographic property proven.

### 8.7 Signing CA Rotation (D8 closure) — post-Drill-2 leak response

**Trigger:** Drill 2 leaked the production `homelab-signing-ca` private key bytes (full base64-encoded PEM) to terminal scrollback and chat transcript via the YAML-inline-base64 + `head -30` mistake (§8.5). Per project rule "leaked key = compromised key = rotate immediately," D8 was opened and rotation executed in the same session.

**Scope decision: Option A — signing CA only, root CA untouched.**

The leak surface contained only the `tls.key` of the `homelab-signing-ca` Secret. Root CA private key was never exposed in this leak path. Root rotation would have been over-correction (full Phase 4 S2 redo, root.crt redistribution to 6 VMs). Signing-only rotation: bounded scope, same root anchor, no VM redistribution.

**Compromised cert audit anchors (archived, not deleted):**

| Field | Value |
|---|---|
| Subject | `CN=Homelab Signing CA, O=Homelab, OU=Platform, L=Buffalo, ST=NY, C=US` |
| Issuer | `CN=Homelab Root CA` |
| SHA-256 fingerprint | `77:FB:B5:75:BB:70:7F:88:6D:61:85:74:85:53:24:F7:24:AF:71:A9:95:92:31:6F:32:11:FC:89:CD:26:FA:6A` |
| Serial | `675444223D04AD7E58D51187477809045EFA74CA` |
| Encrypted key blob SHA | `<REDACTED_SHA_3>` |
| Archive location | `/Volumes/homelab-ca-backup/ca/archive-signing-2026-04-30-leaked/` |

**Procedure (mirrors §3 Steps 5–10 of the S2 reset, Step 11 skipped — sparsebundle infrastructure unchanged):**

1. **Archive (rename, not copy):** `mv signing → archive-signing-2026-04-30-leaked`. Old key file in two places = double exposure risk; rename keeps the audit trail without duplication.
2. **New paper passphrase recorded:** `SIGNING-KEY-v2 (post-leak rotation 2026-04-30)` written to the paper journal alongside the original three passphrases (Rule 1: paper = source of truth). ROOT-KEY and SPARSEBUNDLE passphrases unchanged (Option A invariant).
3. **Generate new signing.key:** `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc`. Interactive passphrase prompts (twice for verification), no inline `-passout` (shell history hygiene).
4. **HARD GATE A (decrypt test):** the dictated `openssl pkey -in signing.key -noout` was implicitly satisfied by the next step — CSR generation requires decrypting the private key, and the CSR was successfully written, proving the paper passphrase matches the generated encrypted blob. Audit-acceptable de-facto pass.
5. **CSR + sign with root CA:** `openssl x509 -req -CA root/root.crt -CAkey root/root.key -CAcreateserial -out signing/signing.crt -days 1825 -extfile signing.ext`. Extension config: `basicConstraints=CA:TRUE,pathlen:0`, `keyUsage=critical,keyCertSign,cRLSign`, SKID/AKID hash chain.
6. **Step 7 — chain verify:** `openssl verify -CAfile root.crt signing.crt` → `signing.crt: OK`. MANDATORY gate, never skipped.
7. **Step 8 — sparsebundle backup verify (already present, since artifacts were generated directly inside the sparsebundle):** ejected sparsebundle (`hdiutil detach`).
8. **HARD GATE C — cold-mount drill (CRITICAL):** `Cmd+Q` the Terminal app entirely (fresh shell, no inherited Keychain unlock state) → fresh `hdiutil attach` (paper SPARSEBUNDLE passphrase OR Keychain auto-unlock, both valid per CLAUDE.md §8) → `openssl pkey -in signing.key -noout` decrypt test → exit 0. **Repeated successfully in TWO independent fresh sessions** — strongest possible recoverability proof, S2 trap definitively avoided this iteration.
9. **SHA cross-mount verification:** key + cert + root SHAs identical across mount cycles (filesystem integrity proof).

**New cert audit anchors:**

| Field | Value |
|---|---|
| Subject | `CN=Homelab Signing CA` (identity preserved, byte-different cert) |
| Issuer | `CN=Homelab Root CA` (same root) |
| SHA-256 fingerprint | `7E:E6:04:53:E2:BC:CC:C3:37:6F:B0:86:0C:59:38:95:17:20:ED:0E:D8:D4:B3:1C:48:8A:E3:99:4E:98:83:D3` |
| Serial | `675444223D04AD7E58D51187477809045EFA74CB` (incremented from old via `CAcreateserial`) |
| Encrypted key blob SHA | `<REDACTED_SHA_4>` |
| Cert SHA-256 (file) | `<REDACTED_SHA_5>` |
| notBefore / notAfter | 2026-05-01 UTC / 2031-04-30 UTC (5 years) |
| Root CA fingerprint (unchanged) | `AD:41:06:B3:FA:BF:D3:15:4D:76:61:82:47:1C:C2:49:2C:C8:37:DE:E0:94:B9:DB:19:CA:D8:AD:B6:1C:ED:4C` |

**Distribution to cluster:**

The K8s Secret `homelab-signing-ca` in `cert-manager` ns stores `tls.key` as **decrypted PKCS#8 PEM** (cert-manager cannot prompt for a passphrase at runtime). Distribution required extracting the decrypted PEM from the encrypted on-disk key:

```bash
umask 077
openssl pkey -in /Volumes/homelab-ca-backup/ca/signing/signing.key \
  -out /tmp/signing-decrypted.key       # mode 0600 via umask, paper passphrase prompt

kubectl create secret tls homelab-signing-ca \
  --cert=/Volumes/homelab-ca-backup/ca/signing/signing.crt \
  --key=/tmp/signing-decrypted.key \
  --dry-run=client -o yaml > /tmp/homelab-signing-ca-new.yaml

kubectl replace -f /tmp/homelab-signing-ca-new.yaml

# Immediate shred (BSD secure overwrite)
rm -P /tmp/signing-decrypted.key /tmp/homelab-signing-ca-new.yaml
```

**Critical secret-blind enforcement during distribution:** `umask 077`, no `cat`, no stdout redirect of decrypted bytes, manifest size + structure verified via Python `yaml.safe_load` printing only field lengths (not content), `rm -P` 3-pass overwrite immediately after `replace` success. Two transient files contained plaintext signing CA private key for ~30 seconds total.

**Cluster reconciliation finding (NON-OBVIOUS):**

After `kubectl replace`, the `homelab-signing-ca` Secret had new bytes (fingerprint `7E:E6:04:53:...` confirmed via `kubectl get secret -o jsonpath ... | openssl x509`), but **cert-manager ClusterIssuer status was stale**:

- ClusterIssuer `lastTransitionTime` still showed 2026-04-26T23:58:06Z (4 days old, original install)
- cert-manager controller logs showed NO reconcile activity for `homelab-signing-ca`
- A no-op annotation update bumped `resourceVersion` (436657 → 1197482) but did NOT trigger `KeyPairVerified` re-run

**Root cause:** cert-manager's ClusterIssuer reconciler responds to spec changes, not Secret-data changes. The CA Issuer caches the verified keypair and does not re-verify on Secret content updates.

**Forced reconcile (delete + reapply ClusterIssuer manifest):**

```bash
kubectl delete clusterissuer homelab-signing-ca
kubectl apply -f k8s/cert-manager/clusterissuer-homelab-signing-ca.yaml
```

Result: `lastTransitionTime: 2026-05-01T00:41:13Z` (fresh), `reason: KeyPairVerified`, log line `Setting lastTransitionTime for Issuer condition` confirmed fresh reconcile. ClusterIssuer is now actively using the NEW signing CA bytes.

**Workload impact assessment:** zero. `kubectl get certificates -A` and `kubectl get certificaterequests -A` returned `No resources found` — at the time of rotation, no Certificate resources existed in the cluster depending on `homelab-signing-ca`. The leaf TLS Secrets in the cluster (longhorn-webhook-tls, ingress-nginx-admission, metallb-webhook-cert, cert-manager-webhook-ca) were generated by their own Helm chart pre-install hooks with their own internal CAs, not by `homelab-signing-ca`. Rotation blast radius is effectively limited to the ClusterIssuer and any future Certificate resources.

**End-to-end issuance proof against rotated CA:**

Re-applied Phase 4 S6 Step 5 first-issuance test (`k8s/cert-manager/test-certificate.yaml`):

- Certificate `test-cert` Ready=True in 8 seconds
- CertificateRequest `test-cert-1` Approved=True, Ready=True
- Leaf cert subject `CN=test.lab`, issued by `CN=Homelab Signing CA`, fingerprint `16:A5:38:45:...`
- cert-manager-injected `ca.crt` in `test-cert-tls` Secret = NEW signing CA fingerprint `7E:E6:04:53:...` (not OLD `77:FB:B5:...`) → propagation confirmed
- **External chain validate:** `openssl verify -CAfile root.crt -untrusted ca-from-secret.crt leaf.crt → leaf.crt: OK`

This is the strongest closure proof: an independent `openssl verify` against three independently-sourced certs (root from sparsebundle, signing CA from cluster Secret, leaf from cert-manager-issued K8s Secret) chain-validates. Mathematical proof of rotation propagation.

**Cleanup:** `test-cert` Certificate deleted (cert-manager reaper handled the `test-cert-tls` Secret), public-cert scratch shredded, fresh post-rotation etcd snapshot taken (`post-rotation-20260430-204348.db`), sparsebundle ejected.

**D8 closure: trust anchor replaced and chain-verified end-to-end.**

### 8.8 D9 — Root CA private key partial display incident (OPEN)

**The exact deviation register block (do not soften, do not summarize):**

```text
D9 — Root CA private key partial display incident
Status: OPEN (lab-accepted, monitored)

Summary:
Partial plaintext exposure occurred during openssl rsa -check
without -noout, resulting in limited key material appearing in terminal.

Assessment:
- Exposure surface: terminal + chat transcript
- Extent: partial, not full key
- Reconstruction risk: low but non-zero, cannot be formally proven

Decision:
- No immediate root CA rotation (high blast radius)
- Incident logged for audit and future review

Monitoring:
- Re-evaluate if any additional exposure signals appear
- Mandatory revisit before any future CA lifecycle change

Principle:
Root CA remains highest-sensitivity asset; exposure is never silently closed.
```

**Context (what happened):**

During Drill 2 leak response, before the dictated HARD GATE A `openssl pkey -in signing.key -noout` test could execute, owner improvised `openssl rsa -in root.key -check` against `root.key` (different key than intended) WITHOUT `-noout`. OpenSSL `rsa -check` default behavior is to print the key after validation. Root CA private key plaintext PEM landed in the Mac terminal scrollback. Partial bytes (BEGIN line + ~3 base64 lines) ended up in the chat transcript before the next message was sent. Owner executed `⌘K` to clear scrollback.

**Why this happened (process forensics):**

- Trust deficit toward Claude after the Drill 2 leak (legitimate; my dictation caused that leak)
- Improvised away from the dictated command
- Wrong key file (`root.key` instead of `signing.key`)
- Wrong flag combination (`rsa -check` prints by default; `pkey -noout` is silent)
- The dictated command (`openssl pkey -in signing.key -noout`) would NOT have printed any bytes

**Why this stays OPEN, not closed-with-caveat:**

Closing D9 would introduce inconsistent decision logic in the deviation register:

- D8 closure was principle-based ("leaked = compromised = rotate")
- D9 closure-with-caveat would be risk-based ("partial, lab, low impact")
- Two artifacts in the same session classified by different logic = future ambiguity anchor

Additionally, "partial leak" is not a stable category. Self-reported quantity, no authoritative measurement of what landed in chat transcript / client logs / context buffers / future training filters. Calling it "closed" claims certainty unavailable to verify.

Most importantly, the runbook signal matters: a future reader pattern-matches "Root key exposure → CLOSED-WITH-CAVEAT" as "negotiable when convenient" — which is the exact wrong lesson to encode in the source of truth.

**Layer separation (locked):**

- D7 closure = cryptographic property proven (Drill 3 invalid padding)
- D8 closure = trust anchor replaced (rotation + external chain-verify)
- D9 = trust anchor integrity uncertainty (cannot be retroactively proven absent)

Different proof types, different closure criteria, never substitutable.

### 8.9 Permanent rules added to §2 (retroactive lock-in)

The discipline failures and corrections from S6.5 surface three new permanent rules. These extend §2 (Critical Discipline Rules), retroactively numbered Rule 7–9 to maintain section sequencing.

**Rule 7 — Secret-blind discipline applies to K8s Secret data, not just on-disk keys**

The original secret-blind rule (post-2026-04-29 `encryption-key.txt` incident) was scoped to on-disk encryption material. The Drill 2 leak proved this scope was incomplete: K8s Secret data displayed via `kubectl get -o yaml` is an identical exposure surface. YAML inline-base64 format puts entire field contents on single very long lines, defeating `head -N` line-based truncation.

**Lock:** any kubectl operation against a Secret containing private key material must use jsonpath extraction + targeted openssl validation (subject DN, fingerprint, length, parse-and-validate), NEVER full `-o yaml` or `-o json` output to terminal regardless of intended truncation.

**Permitted patterns:**

```bash
kubectl get secret <n> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -fingerprint -sha256
kubectl get secret <n> -o jsonpath='{.data.tls\.key}' | base64 -d | wc -c
kubectl get secret <n> -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -in /dev/stdin -noout -check
```

**Forbidden patterns:**

```bash
kubectl get secret <n> -o yaml             # YAML inline base64, single long lines
kubectl get secret <n> -o yaml | head -N   # truncation by lines fails on long lines
kubectl get secret <n> -o yaml | tee ...   # writes to disk, persists exposure
```

**Rule 8 — Decision logic for trust artifacts must be principle-based, not risk-based**

When a private key is exposed, the rotation decision MUST follow the principle "leaked = compromised = rotate" without risk-model negotiation. Risk-based reasoning ("partial leak, low impact, lab only") creates inconsistent decision logic in the deviation register. Two artifacts classified by different logic in the same session = future ambiguity anchor → bad precedent encoded in source-of-truth.

**Why this matters more than today's risk:** future readers (including future-self at the 6-month horizon) pattern-match deviation register entries to learn "what is acceptable practice here." A "CLOSED-WITH-CAVEAT" classification on a key exposure teaches "exposure can be negotiated when inconvenient to rotate." This is the exact wrong lesson to encode.

**Lock:**

- Full key exposure → rotate immediately, no risk negotiation
- Partial key exposure → OPEN deviation, monitor, no silent closure
- Trust artifact integrity uncertainty is never silently downgraded

**Rule 9 — "Partial exposure" is not a closeable category**

Self-reported exposure quantity is not authoritative measurement. Surfaces beyond the owner's control: terminal scrollback, chat transcript, client log buffers, training data filters, OS clipboard history, terminal multiplexer logs (tmux/screen/asciinema). Calling a partial leak "closed" claims certainty that cannot be retroactively verified.

**Lock:**

- Partial exposure → OPEN deviation with explicit monitoring trigger
- Closure language ("CLOSED", "CLOSED-WITH-CAVEAT", "RESOLVED") forbidden for any incident where exposure quantity is self-reported and unverifiable
- Mandatory revisit before any related lifecycle operation

**Cross-reference:** D9 (§8.8) is the canonical example of this rule applied.

### 8.10 Forensic etcd snapshots — audit timeline

Three snapshots from this session form a forensic timeline of the encryption + rotation work. All preserved at `/var/lib/etcd-snapshots/` on `k8s-cp-1`. Each represents a distinct cluster state and is referenced in the §8.2–8.7 procedures.

| File | Time | State | Purpose |
|---|---|---|---|
| `pre-s6.5-20260430-190106.db` | 19:01:06 | Plaintext Secrets, no encryption flag | Step 5b irreversibility-gate rollback insurance |
| `post-s6.5-20260430-195002.db` | 19:50:02 | Ciphertext Secrets, COMPROMISED signing CA bytes | Drill 2/3 substrate; pre-rotation reference |
| `post-rotation-20260430-204348.db` | 20:43:48 | Ciphertext Secrets, ROTATED signing CA bytes | Post-rotation cluster baseline |

**Snapshot sizes uniform 14,618,656 bytes** (15 MB) across all three. This reflects etcd's overhead consistency at the homelab cluster scale (2,175–2,319 keys, 8-day-old cluster), not coincidence.

**Retention policy decision:** all three snapshots are retained until Phase 13 (Backup) implementation defines a formal retention schedule. The audit-relevant span — the full S6.5 + D8 closure cycle — is visible in three discrete artifacts.

**SHA-256 of snapshots (for integrity reference):**

- `pre-s6.5`: SHA captured in the Step 5b backup (re-compute when accessing)
- `post-s6.5`: `<REDACTED_SHA_6>`
- `post-rotation`: not captured live (recompute via `sha256sum`)

**Use cases for these snapshots:**

- D7 audit: `pre-s6.5` proves the baseline plaintext state (deviation existed)
- D7 closure proof: `post-s6.5` is the substrate that produced the Drill 3 invalid-padding result
- D8 audit: comparing `post-s6.5` vs `post-rotation` shows the ciphertext bytes for the `homelab-signing-ca` Secret are different (re-encrypted with new key bytes via the Step 5b apiserver flag), proving rotation propagated through the encryption layer
- Forensic: any future incident can be reconstructed against these three known states

---

## 9. Related Documents

- DNS runbook: `docs/runbooks/phase-4/dns-en.md`
- Bangla version: `docs/runbooks/phase-4/ca-bn.md`
- 2026-04-26 reset drill log: `docs/runbooks/phase-4/drills/ca-reset-2026-04-26.md`

---

*Phase 4 CA runbook v3 — Tuhin Zaman — 2026-04-28*
---

## Deviation D7 — etcd Encryption-at-Rest Deferred

**Status:** OPEN · Accepted with locked timeline
**Logged:** 2026-04-26 (Phase 4 S6, before cert-manager install)
**Closure target:** Phase 4 S6.5 (between S6 cert-manager and S7 NetworkPolicy)
**Closure deadline:** 2026-05-10 (2 weeks from log date)

### Decision
etcd encryption-at-rest NOT enabled before signing.key lands in K8s Secret.
signing.key sits in plaintext etcd from Phase 4 S6 until S6.5 closes.

### Rationale
- One irreversible cluster-wide op per session (S5 lesson; apiserver static pod
  edit deserves dedicated drill, not sidecar to cert-manager install)
- etcd encryption requires its own validation: apiserver crash-recovery drill,
  snapshot-restore-with-encryption-key drill, key rotation rehearsal
- Lab threat model: vmbr1 isolated, cp-1 single-host, no etcd snapshot egress,
  physical pve access required for compromise — marginal risk reduction in
  this specific topology during short deferral window

### Blast radius if exploited during deviation window
- etcd snapshot exfiltration OR cp-1 disk read = signing.key leak
- Full internal CA private trust compromised
- ALL *.lab certs must be re-issued from new CA
- Trust distribution refresh on Mac + 6 VMs required (S5 procedure replay)

### Mitigations active during deviation window
- vmbr1 isolated (no inbound internet)
- cp-1 etcd local-only (no remote etcd peers)
- Physical pve host security (Buffalo home, locked)
- Phase 2.5 etcd snapshots stored on cp-1 only, not egressed off-host
- No etcd snapshot transfer to external systems until S6.5 closes

### Closure criteria (S6.5)
- AES-256 encryption key generated, stored mode 0600 root-only on cp-1
- /etc/kubernetes/enc/encryption-config.yaml in place
- kube-apiserver manifest updated with --encryption-provider-config
- All existing Secrets re-encrypted via kubectl replace
- Drill: kill apiserver pod, verify recovery
- Drill: take snapshot, restore on test host with key, verify Secrets readable
- Drill: restore on test host WITHOUT key, verify Secrets unreadable
- Documentation: encryption key backup procedure added to Phase 13 backup scope

### Escalation
If S6.5 slips beyond 2026-05-10, pause Phase 4 progression and review plan.

**Status update 2026-04-30:** D7 CLOSED.

- Cryptographic property proven via Drill 3 invalid-padding negative-control test (§8.6)
- All 11 cluster Secrets re-encrypted via Step 6 (§8.3)
- Forensic snapshot `post-s6.5-20260430-195002.db` is the audit anchor
- Closure layer: cryptographic property (per §8.8 layer separation lock)

---

## Deviation D8 — Signing CA leak via Drill 2 secret-blind violation

**Status:** CLOSED (2026-04-30)

**Trigger:** §8.5 Drill 2 dictated `kubectl get secret -o yaml | head -30` leaked
`homelab-signing-ca` `tls.key` full PEM to terminal scrollback + chat transcript.

**Closure:** §8.7 — signing CA rotated (Option A scope: signing only, root untouched),
chain-verified end-to-end via independent `openssl verify` against root, signing CA from
cluster Secret, and a fresh leaf cert. Compromised cert archived at
`/Volumes/homelab-ca-backup/ca/archive-signing-2026-04-30-leaked/`.

**Closure layer:** trust anchor replaced (per §8.8 layer separation lock).

---

## Deviation D9 — Root CA private key partial display incident

**Status:** OPEN (lab-accepted, monitored)

```text
D9 — Root CA private key partial display incident
Status: OPEN (lab-accepted, monitored)

Summary:
Partial plaintext exposure occurred during openssl rsa -check
without -noout, resulting in limited key material appearing in terminal.

Assessment:
- Exposure surface: terminal + chat transcript
- Extent: partial, not full key
- Reconstruction risk: low but non-zero, cannot be formally proven

Decision:
- No immediate root CA rotation (high blast radius)
- Incident logged for audit and future review

Monitoring:
- Re-evaluate if any additional exposure signals appear
- Mandatory revisit before any future CA lifecycle change

Principle:
Root CA remains highest-sensitivity asset; exposure is never silently closed.
```

**Closure layer:** trust anchor integrity uncertainty (per §8.8 layer separation lock).
Cannot be retroactively proven absent. Mandatory revisit before any future CA lifecycle change.

---

## Deviation D11 — Root CA encrypted private key file retained on Mac filesystem

**Status:** CLOSED (2026-05-03, partial remediation)

**Logged:** 2026-05-03 (discovered during Phase 5 S2 work)

```text
D11 — Root CA encrypted private key file retained on Mac filesystem
Status: CLOSED (2026-05-03, partial remediation — APFS limitation)

Summary:
After Phase 4 §S2 (initial CA generation, 2026-04-26), the root CA
encrypted private key file (root.key, 3446 bytes, RSA 4096, encrypted
under aes256 with paper-stored ROOT-KEY passphrase) was retained at
~/Project/homelab-secrets/ca/root/root.key on the Mac, in addition
to its intended location inside the encrypted sparsebundle backup.

Architectural intent (per Phase 4 design): root.key file lives ONLY
inside the encrypted sparsebundle on the external drive, accessed
via paper passphrase, with no copy on online filesystems after
generation + immediate decrypt test (HARD GATE B).

Actual state Apr 26 → May 3 (7 days): online filesystem copy retained
on Mac, contradicting the isolation rule. The file itself was
encrypted at rest under aes256; the deviation is about ISOLATION
CONTROL, not cryptographic exposure of key material.

Discovery:
2026-05-03 during Phase 5 S2 chunk 9 path-discovery for the Mac trust
store add operation (`ls -la ~/Project/homelab-secrets/ca/root/`).

Assessment:
- Exposure surface: Mac filesystem, plus any backup tool that touched
  the homelab-secrets/ tree (Time Machine if enabled on user volume,
  iCloud Drive if mirrored, manual backups, repository accidents)
- Extent: full encrypted root.key file was exposed to the Mac
  filesystem. The private key material remained passphrase-protected
  (aes256 + paper-stored ROOT-KEY passphrase), but the isolation
  control failed because the key file was retained outside the
  external encrypted sparsebundle.
- Reconstruction risk: gated by ROOT-KEY passphrase strength
  (paper-stored, EFF-wordlist diceware). File alone insufficient
  without passphrase. Compromise scenario requires BOTH file leak
  AND passphrase compromise — same threat model as the sparsebundle
  copy. Net additional cryptographic risk from this deviation: an
  attacker who exfiltrated Mac filesystem during the 7-day window
  obtained an encrypted blob already protected by the same paper
  passphrase that protects the sparsebundle copy.

Net additional risk: LOW for cryptographic exposure (encryption-at-rest
held), but the deviation eliminated a defense-in-depth layer
(sparsebundle isolation on external drive, drive disconnected when
not in use). The isolation property — "key file not on online disk" —
was violated regardless of cipher strength.

Remediation (2026-05-03):
1. Sparsebundle re-mounted, root.key paper-passphrase decrypt test
   (Step-9b-style verify) — backup recoverability confirmed
   (`openssl rsa -in root.key -noout -check` → "RSA key ok")
2. Mac online filesystem copy of root.key removed via `rm`
   (NOTE: APFS `rm` = unlink only, no overwrite — true secure
   deletion not possible on APFS COW filesystem; blocks may
   persist until reuse. This is platform limitation, accepted)
3. Sparsebundle unmounted, secret window closed

Why "CLOSED" despite partial deletion:
- File no longer in active filesystem index
- Encryption-at-rest (aes256) protects raw blocks even if recoverable
- ROOT-KEY passphrase remains paper-only (never typed online,
  never in shell history, never in chat transcripts)
- No additional remediation possible without full disk wipe
  (disproportionate for HOMELAB threat model)
- Future Phase 14+ migration to fresh AWS environment will create
  natural reset point for any residual concerns

Mitigations going forward:
- Phase 4 runbook §3 procedure must be revised to mandate
  removal-from-online-disk immediately after generation +
  HARD GATE B (this gap allowed D11 to occur)
- Pre-flight checks for any future CA-touching session must include:
  `find ~/Project/homelab-secrets -name "*.key" -not -path "*/ca-backup/*"`
  → expect empty result; non-empty = stop, investigate
- D11 reinforces architectural principle: encrypted-at-rest is
  insufficient defense alone; sparsebundle isolation is the
  baseline, not a luxury

Closure criteria:
- [x] File removed from Mac active filesystem
- [x] Sparsebundle backup verified recoverable (paper passphrase)
- [x] D11 entry documented in Phase 4 CA runbook
- [x] Phase 5 S2 lessons reference D11 in state notes
- [ ] Memory update after S2 close-out
- [ ] Phase 4 runbook §3 procedure update (deferred — separate edit)
- [ ] Pre-flight check command added to session protocol (deferred)

Operator: Tuhin
Discovered + remediated within: same session (2026-05-03 Phase 5 S2)
```
