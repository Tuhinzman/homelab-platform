# Kubeadm Bootstrap — 3-Node Cluster

## Date
April 2, 2026

## Kubernetes Version
v1.31.14

## OS
Ubuntu 24.04.4 LTS (all nodes)

## Control Plane Configuration
- Control plane endpoint: 10.0.1.10:6443
- Pod subnet: 172.16.0.0/16
- Service subnet: 10.96.0.0/12

## Cluster Initialization
sudo kubeadm init \
  --pod-network-cidr=172.16.0.0/16 \
  --apiserver-advertise-address=10.0.1.10 \
  --control-plane-endpoint=10.0.1.10 \
  --kubernetes-version=v1.31.14

## kubeconfig Setup
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

## Worker Join
sudo kubeadm join 10.0.1.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>

## Validation Commands
kubectl get nodes -o wide
kubectl get pods -n kube-system

## Result
- mk-master: Ready (control-plane)
- mk-worker-1: Ready
- mk-worker-2: Ready
