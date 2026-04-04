# Service Debug Playbook

## Incident 1 — Service Selector Mismatch (Silent Failure)

### Date
April 3, 2026

### Symptom
- Pods are Running
- Service exists
- No obvious error messages
- Traffic is not reaching backend pods

### Root Cause
Service selector does not match pod labels.
A Service routes traffic by matching labels on pods.
If the selector does not match, endpoints list becomes empty.
The failure is silent — Service still exists but has no backend targets.

### Debug Commands

Step 1: Check endpoints first

    kubectl get endpoints nginx-test -n dev

If ENDPOINTS shows none — selector mismatch or pods not Ready.

Step 2: Check pod labels

    kubectl get pods -n dev --show-labels

Step 3: Check Service selector

    kubectl describe service nginx-test -n dev

Compare Selector field with pod labels.

### Expected vs Broken

Healthy:
    NAME         ENDPOINTS
    nginx-test   172.16.x.x:80,172.16.x.x:80,172.16.x.x:80

Broken:
    NAME         ENDPOINTS
    nginx-test   none

### Fix

    kubectl patch service nginx-test -n dev       -p '{"spec":{"selector":{"app":"nginx-test"}}}'

### Verification

    kubectl get endpoints nginx-test -n dev

Endpoints should show pod IPs again.

### AWS Parallel
Similar to an AWS Target Group with no healthy registered targets.
ALB returns 502/503 but pods show no errors.
Debug: EC2 → Target Groups → check health status.

### Key Lesson
Always check endpoints first when traffic is not reaching pods.
Pods Running does not mean traffic is flowing.
A healthy Service object does not guarantee healthy backend targets.
