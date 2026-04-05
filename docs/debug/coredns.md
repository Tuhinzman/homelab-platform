# CoreDNS Failure - Debug Playbook

## Scenario
CoreDNS unavailable → cluster-internal DNS resolution fails → name-based service discovery broken

## Failure Modes
1. CoreDNS pods down (scaled to 0, crashed, OOMKilled)
2. CoreDNS pods running but not responding (health check passing, but queries failing)
3. kube-dns Service exists but endpoints empty (pods not matching selector)
4. CoreDNS config (Corefile) broken (bad plugin, syntax error)
5. Upstream DNS broken (external resolution fails, cluster-internal still works)

## What Breaks vs What Works

| Access Method | Works? | Why |
|---|---|---|
| DNS name (svc.cluster.local) | ❌ | CoreDNS provides cluster-internal service discovery via DNS |
| ClusterIP (direct IP) | ✅ | kube-proxy iptables handles routing, no DNS involved |
| Pod IP (direct IP) | ✅ | Calico routes directly, no DNS involved |

### Nuance
- Existing established connections may still work (already resolved)
- Applications with DNS caching (Java, Go) may partially work — failure can be delayed
- Pod IPs are ephemeral — they change on restart. Never hardcode Pod IPs.

## Isolation Logic

| Test | Meaning |
|---|---|
| DNS name fails, ClusterIP works | CoreDNS issue |
| DNS name fails, ClusterIP fails, Pod IP works | Service / kube-proxy issue |
| All fail | Application or network issue |

## Debug Steps

### 1. Check CoreDNS pods
```
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

### 2. Check pod DNS config
```
kubectl exec <pod> -- cat /etc/resolv.conf
```
Expected:
```
nameserver 10.96.0.10
search <namespace>.svc.cluster.local svc.cluster.local cluster.local
```
If this is wrong → DNS broken even if CoreDNS is healthy.

### 3. Check kube-dns Service and Endpoints
```
kubectl get svc -n kube-system kube-dns
kubectl get endpoints -n kube-system kube-dns
```
If endpoints empty → CoreDNS pods not backing the Service.
Service IP reachable ≠ Service working. Service works only when endpoints exist.
(Same pattern as Day 4 selector mismatch)

### 4. Test DNS resolution from a pod
```
kubectl exec <pod> -- nslookup kubernetes.default
kubectl exec <pod> -- nslookup <service>.<namespace>.svc.cluster.local
```

### 5. Check CoreDNS logs
```
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```
Look for:
- plugin errors
- loop detection errors
- upstream DNS failures
- SERVFAIL responses

## Fix

### 1. If pods down — restart
```
kubectl rollout restart deployment coredns -n kube-system
```

### 2. If pods scaled to 0
```
kubectl scale deployment coredns -n kube-system --replicas=2
```

### 3. Verify endpoints restored
```
kubectl get endpoints -n kube-system kube-dns
```

### 4. Validate DNS working
```
kubectl exec <pod> -- nslookup kubernetes.default
```

Note: DNS not instantly available after restore — wait for pods to reach Running/Ready state.

## AWS Parallel (EKS)
- EKS also runs CoreDNS as a managed addon in kube-system
- Same failure pattern: DNS names fail, IP-based access still works
- EKS auto-heals CoreDNS — managed addon restarts automatically
- Debug commands identical: kubectl get pods, logs, endpoints
- Fix: restart addon via EKS console or eksctl, check node health
- CoreDNS = cluster-internal DNS only (svc.cluster.local)
- Route53 = external DNS (myapp.example.com) — completely separate layer
