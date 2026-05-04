#!/bin/bash
set -euo pipefail

TEMPLATE=9001
SSHKEYS=/root/.ssh/authorized_keys_tuhin.pub
CIUSER=tuhin
DNS=1.1.1.1
SEARCH=lab.local
GW=10.10.0.1
BRIDGE=vmbr1

VMS=(
  "110  k8s-cp-1        10.10.0.10      4      4096"
  "121  k8s-worker-1    10.10.0.21      4      8192"
  "122  k8s-worker-2    10.10.0.22      4      8192"
  "123  k8s-worker-3    10.10.0.23      2      4096"
  "130  ci-1            10.10.0.30      4      12288"
  "150  svc-1           10.10.0.50      2      4096"
)

for row in "${VMS[@]}"; do
  read -r VMID NAME IP CORES MEM <<< "$row"
  echo "=== Provisioning VM $VMID ($NAME @ $IP) ==="
  qm clone "$TEMPLATE" "$VMID" --name "$NAME" --full
  qm set "$VMID" \
    --cores "$CORES" \
    --memory "$MEM" \
    --net0 "virtio,bridge=$BRIDGE" \
    --ipconfig0 "ip=$IP/24,gw=$GW" \
    --nameserver "$DNS" \
    --searchdomain "$SEARCH" \
    --ciuser "$CIUSER" \
    --sshkeys "$SSHKEYS" \
    --agent enabled=1 \
    --onboot 1
  qm cloudinit update "$VMID"
  echo "=== VM $VMID configured ==="
done

echo "=== Starting VMs (staggered) ==="
for row in "${VMS[@]}"; do
  read -r VMID _ _ _ _ <<< "$row"
  qm start "$VMID"
  sleep 5
done

echo "=== All VMs started ==="
