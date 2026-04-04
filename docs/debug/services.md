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

A Service routes traffic by matching labels on pods. If the selector does not match any pod labels, the endpoints list becomes empty.
The failure is silent: the Service still exists, but it has no backend targets.

### Debug Commands

Step 1: Check endpoints first

```bash
kubectl get endpoints nginx-test -n dev
