# homelab-platform

Proxmox-based homelab platform engineering project.
Kubernetes → GitLab → ArgoCD → Observability → EKS.

## Stack
- Proxmox PVE 9.1
- Kubernetes v1.31.14 (kubeadm, 3-node)
- Calico CNI (VXLAN)
- Google Online Boutique (planned workload)

## Structure
- `docs/` — architecture, runbooks, debug playbooks, progress log
- `kubernetes/` — manifests
- `infrastructure/` — proxmox, networking, terraform
- `scripts/` — automation scripts
- `monitoring/` — Prometheus/Grafana configs
- `cicd/` — pipeline definitions
