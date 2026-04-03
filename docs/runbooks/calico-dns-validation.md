# Calico CNI and DNS Validation

## Date
April 2, 2026

## CNI
- Provider: Calico
- Mode: VXLAN overlay
- Pod CIDR: 172.16.0.0/16
- Service CIDR: 10.96.0.0/12

## Node Pod CIDR Allocation (verified)
| Node        | Pod CIDR Block |
|-------------|----------------|
| mk-master   | 172.16.0.0/24  |
| mk-worker-1 | 172.16.1.0/24  |
| mk-worker-2 | 172.16.2.0/24  |

## DNS Validation
- kubernetes service ClusterIP: 10.96.0.1
- CoreDNS service IP: 10.96.0.10
- Resolution verified: kubernetes.default.svc.cluster.local

## Connectivity Validation
- Cross-node pod-to-pod communication verified
- Pod egress verified
- NAT/MASQUERADE functioning

## Evidence Commands
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" => "}{.spec.podCIDR}{"\n"}{end}'
kubectl cluster-info
kubectl get svc -A
