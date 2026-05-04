#!/usr/bin/env bash
# etcd-snapshot.sh — atomic, validated etcd snapshot with safe retention
#
# Exit codes:
#   0   success
#   10  etcdctl binary missing
#   11  etcdutl binary missing
#   12  CA cert not readable
#   13  client cert not readable
#   14  client key not readable
#   15  backup dir prep failed
#   16  backup dir not writable
#   20  snapshot save failed
#   21  snapshot file empty
#   22  snapshot below size threshold
#   23  snapshot status command failed
#   24-27 revision/totalKey missing or zero
#   30  atomic rename failed
#
# Invariant: retention (prune) ONLY runs after new snapshot verified + promoted.

set -Eeuo pipefail

# PATH guard — systemd/cron may start with minimal PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

BACKUP_DIR="/var/backups/etcd"
RETENTION=40
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
TMP_SNAP="${BACKUP_DIR}/snapshot-${STAMP}.db.tmp"
FINAL_SNAP="${BACKUP_DIR}/snapshot-${STAMP}.db"

CACERT="/etc/kubernetes/pki/etcd/ca.crt"
CERT="/etc/kubernetes/pki/etcd/healthcheck-client.crt"
KEY="/etc/kubernetes/pki/etcd/healthcheck-client.key"
ENDPOINT="https://127.0.0.1:2379"

fail() {
  echo "[ERROR] $1" >&2
  rm -f "${TMP_SNAP}" 2>/dev/null || true
  exit "${2:-1}"
}

# ---- Preflight: binaries ----
command -v etcdctl >/dev/null 2>&1 || fail "etcdctl not found" 10
command -v etcdutl >/dev/null 2>&1 || fail "etcdutl not found" 11

# ---- Preflight: certs ----
[ -r "${CACERT}" ] || fail "Missing CA cert" 12
[ -r "${CERT}" ]   || fail "Missing client cert" 13
[ -r "${KEY}" ]    || fail "Missing client key" 14

# ---- Preflight: backup dir (idempotent perms enforcement) ----
install -d -o root -g root -m 0700 "${BACKUP_DIR}" || fail "Cannot prep backup dir" 15
[ -w "${BACKUP_DIR}" ] || fail "Backup dir not writable" 16

echo "[INFO] Starting snapshot → ${TMP_SNAP}"

# ---- Snapshot (atomic via .tmp) ----
etcdctl \
  --endpoints="${ENDPOINT}" \
  --cacert="${CACERT}" \
  --cert="${CERT}" \
  --key="${KEY}" \
  snapshot save "${TMP_SNAP}" >/dev/null 2>&1 || fail "Snapshot save failed" 20

# ---- Validate: primary ----
[ -s "${TMP_SNAP}" ] || fail "Snapshot file empty" 21

SIZE_BYTES="$(stat -c%s "${TMP_SNAP}")"
[ "${SIZE_BYTES}" -gt 1048576 ] || fail "Snapshot smaller than 1 MiB sanity threshold" 22

STATUS_JSON="$(etcdutl snapshot status "${TMP_SNAP}" -w json 2>/dev/null)" \
  || fail "Snapshot status failed" 23

REVISION="$(echo "${STATUS_JSON}" | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)"
TOTAL_KEYS="$(echo "${STATUS_JSON}" | grep -o '"totalKey":[0-9]*' | head -1 | cut -d: -f2)"

[ -n "${REVISION}" ]    || fail "Revision missing from snapshot status" 24
[ -n "${TOTAL_KEYS}" ]  || fail "totalKey missing from snapshot status" 25
[ "${REVISION}" -gt 0 ] || fail "Revision is zero" 26
[ "${TOTAL_KEYS}" -gt 0 ] || fail "totalKey is zero" 27

echo "[INFO] Validated: revision=${REVISION}, keys=${TOTAL_KEYS}, size=${SIZE_BYTES}"

# ---- Atomic promotion ----
mv "${TMP_SNAP}" "${FINAL_SNAP}" || fail "Atomic rename failed" 30

# ---- Retention: only after success ----
PRUNED=$(ls -1t "${BACKUP_DIR}"/snapshot-*.db 2>/dev/null | tail -n +$((RETENTION + 1)) | wc -l)
ls -1t "${BACKUP_DIR}"/snapshot-*.db 2>/dev/null | tail -n +$((RETENTION + 1)) | xargs -r rm -f

echo "[OK] Snapshot saved: ${FINAL_SNAP}"
echo "[OK] Retention kept: ${RETENTION}, pruned: ${PRUNED}"
