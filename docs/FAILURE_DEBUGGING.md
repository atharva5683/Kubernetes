# Intentional database DNS failure: debug and fix

This exercise creates a real failed rollout without deleting the old healthy
replicas. The backend process remains alive, but the dependency-aware readiness
probe fails because the new pod cannot resolve the intentionally invalid
database hostname.

## 1. Capture a healthy baseline

```bash
# All backend pods should be Running and Ready (for example, 1/1).
kubectl get pods -n devops-challenge \
  -l app.kubernetes.io/name=backend -o wide

# The Deployment should be fully available before creating the fault.
kubectl get deployment backend -n devops-challenge

# This verifies browser → frontend → backend → PostgreSQL.
./scripts/smoke-test.sh
```

Reasoning: without a known-good baseline, a later error could be an old problem
rather than the fault being demonstrated.

## 2. Inject the fault and show the failure

```bash
# Adds a direct DB_HOST override with a DNS name that cannot resolve.
./scripts/simulate-failure.sh

# The rollout stalls because the new ReplicaSet cannot become Ready.
kubectl rollout status deployment/backend -n devops-challenge --timeout=15s

# The newest backend pod should show Running but 0/1 Ready.
kubectl get pods -n devops-challenge \
  -l app.kubernetes.io/name=backend \
  --sort-by=.metadata.creationTimestamp

# Argo reports drift because the live override is not in Git.
kubectl get application devops-challenge -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Expected symptom: an old replica remains Ready, while the new pod is alive but
unready. The public application may still work because `maxUnavailable: 0`
protects availability during the bad rollout.

## 3. Debug from broad symptoms to the failing dependency

```bash
# Save the newest backend pod resource name for the next commands.
failure_pod="$(kubectl get pods -n devops-challenge \
  -l app.kubernetes.io/name=backend \
  --sort-by=.metadata.creationTimestamp \
  -o name | tail -n 1)"

# Events show repeated readiness probe HTTP 503 responses.
kubectl describe -n devops-challenge "$failure_pod"

# Logs should include readiness_failed and a name-resolution error.
kubectl logs -n devops-challenge "$failure_pod" --tail=100

# Liveness still returns 200, proving the Python process itself is healthy.
kubectl exec -n devops-challenge "$failure_pod" -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/health/live").status)'

# The real PostgreSQL Service name resolves from the same failing pod.
kubectl exec -n devops-challenge "$failure_pod" -- getent hosts postgres

# The injected hostname does not resolve; this command is expected to fail.
kubectl exec -n devops-challenge "$failure_pod" -- getent hosts postgres-broken.invalid

# Compare the direct override with the correct ConfigMap value.
kubectl get deployment backend -n devops-challenge \
  -o jsonpath='{.spec.template.spec.containers[0].env}'
printf '\n'
kubectl get configmap challenge-config -n devops-challenge \
  -o jsonpath='{.data.DB_HOST}'
printf '\n'

# Only Ready pods appear as serving endpoints.
kubectl get endpointslices -n devops-challenge \
  -l kubernetes.io/service-name=backend -o yaml
```

## 4. Explain the reasoning

The evidence separates four possible fault domains:

1. **Image/process failure is unlikely:** the pod is Running and liveness is
   HTTP 200, so this is not `CrashLoopBackOff` or an image pull problem.
2. **Kubernetes DNS is generally working:** `postgres` resolves from the same
   pod, so CoreDNS and the PostgreSQL Service are working.
3. **The database hostname is wrong only in the new pod:** logs contain the
   unresolved name, and the Deployment has a direct `DB_HOST` override that
   wins over `envFrom`.
4. **The rollout protection is working:** readiness returns 503, so Kubernetes
   excludes the bad pod; `maxUnavailable: 0` retains old ready replicas.

Root cause: `DB_HOST=postgres-broken.invalid` was injected into the backend Pod
template. It overrides `DB_HOST=postgres` from `challenge-config`.

A reasonable first assumption is that PostgreSQL is down. The successful
`getent hosts postgres`, ready PostgreSQL pod, and old serving endpoints disprove
that assumption. The fault is configuration and DNS resolution, not database
process availability.

## 5. Fix and verify

```bash
# Remove only the direct override. DB_HOST again comes from challenge-config.
kubectl set env deployment/backend -n devops-challenge DB_HOST-

# The replacement pods should pass readiness and finish the rollout.
kubectl rollout status deployment/backend -n devops-challenge --timeout=180s

# Every backend pod should now be Ready.
kubectl get pods -n devops-challenge \
  -l app.kubernetes.io/name=backend -o wide

# Argo should return to Synced after the live specification matches Git.
kubectl get application devops-challenge -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# Re-run the end-to-end database write/read test.
./scripts/smoke-test.sh
```

The packaged recovery script performs the same safe repair:

```bash
./scripts/fix-failure.sh
```

For normal production operation, set `selfHeal: true` so Argo automatically
reverts unapproved live drift. It is `false` here only to keep the intentional
fault available for a two-minute debugging demonstration.
