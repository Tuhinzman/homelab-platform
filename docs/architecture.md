# Homelab Architecture

## Hardware
- Host: Proxmox PVE 9.1
- CPU: i9-10850K
- RAM: 64GB
- Storage: 2x1TB NVMe

## Current Kubernetes Nodes
| Name        | IP         | Role          |
|-------------|------------|---------------|
| mk-master   | 10.0.1.10  | Control Plane |
| mk-worker-1 | 10.0.1.11  | Worker        |
| mk-worker-2 | 10.0.1.12  | Worker        |

## Network Design
- Management bridge: vmbr0 — 192.168.68.0/24
- Proxmox management IP: 192.168.68.200
- Lab bridge: vmbr2 — 10.0.1.0/24
- Lab gateway: 10.0.1.1
- MetalLB planned range: 10.0.1.50-10.0.1.59 (not yet configured)
- Pod CIDR: 172.16.0.0/16
- Service CIDR: 10.96.0.0/12

## Kubernetes Control Plane
- Endpoint: 10.0.1.10:6443
- Version: v1.31.14
- OS: Ubuntu 24.04.4 LTS (all nodes)
