# 10-minute recording script

Keep the browser, Jenkins stage view, Argo CD, Grafana or Prometheus, and one
terminal ready before recording. Run the Jenkins build and normal deployment in
advance; the failure is the only change to create live.

## 0:00–0:45 — Goal and architecture

“This is a minimal production-style stack on Azure Kubernetes Service. A user
hits an Nginx frontend, which calls a Python API, which writes to PostgreSQL.
Jenkins is CI and release automation; Argo CD is the only Kubernetes deployment
controller. Azure Key Vault supplies the database password through Workload
Identity and the Secrets Store CSI driver.”

Show the README architecture diagram.

## 0:45–2:30 — Working deployment

```bash
kubectl get application devops-challenge -n argocd
kubectl get deployments,statefulsets,pods,services,pvc -n devops-challenge
./scripts/smoke-test.sh
```

Open the frontend and click **Record a visit**. Explain that the changed counter
proves the complete frontend → backend → database path. Show that the two
frontend and two backend replicas are ready and PostgreSQL has an Azure Disk
PVC.

## 2:30–4:00 — CI/CD and version traceability

Show the Jenkins stages: unit test, multi-stage build, Trivy scans, Docker Hub
push, and GitOps update. Then show:

```bash
git show origin/gitops:helm/devops-challenge/values-production.yaml
kubectl get deployment backend -n devops-challenge \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
printf '\n'
```

“The release format contains semantic version, Jenkins build number, and Git
SHA. Jenkins pushes the exact tag to Docker Hub and commits that same tag to the
GitOps branch. Argo sees the Git change and applies the Helm chart. Jenkins has
no cluster credential, which separates CI compromise from direct cluster
control.”

## 4:00–5:15 — Reliability and security decisions

Open `helm/devops-challenge/templates/backend.yaml` and show the probes,
rolling-update settings, resources, and security context.

“Liveness checks only whether the process is alive. Readiness runs a real
database query. A database problem therefore removes a pod from traffic without
restarting a healthy process. `maxUnavailable: 0` keeps old replicas serving
during a failed rollout. The cost is one small database query every five
seconds per pod and tighter dependency coupling.”

Show `secret-provider-class.yaml`. Explain that only Key Vault identity metadata
is in Git; the password is neither in the repository nor Jenkins.

## 5:15–7:45 — Intentional failure and debugging

```bash
./scripts/simulate-failure.sh
```

Narrate the method before the answer:

1. “I first establish whether this is image pull, crash, probe, networking, DNS,
   or database availability.”
2. Show the newest pod as Running but `0/1`, not crash-looping.
3. Describe the pod and point to readiness HTTP 503 events.
4. Show logs containing `readiness_failed` and name resolution.
5. Prove `/health/live` returns 200.
6. Prove `postgres` resolves but `postgres-broken.invalid` does not.
7. Compare the Deployment override with `challenge-config`.

Use the exact commands in `docs/FAILURE_DEBUGGING.md`.

“My first assumption could be that PostgreSQL is down. The ready PostgreSQL pod,
successful resolution of the real Service, and old healthy backend endpoints
disprove that. The root cause is a direct `DB_HOST` override in the new Pod
template. It wins over the ConfigMap value.”

## 7:45–8:35 — Fix and recovery

```bash
./scripts/fix-failure.sh
./scripts/smoke-test.sh
```

Show all backend pods Ready, the rollout complete, Argo back to Synced, and the
database counter working. Mention that production Argo should use
`selfHeal: true`; it is disabled only so the live debugging fault is not removed
before it can be investigated.

## 8:35–9:20 — Observability

Open Prometheus and query:

```text
challenge_database_ready
challenge_http_requests_total
```

Show the `ChallengeDatabaseNotReady` rule or the application dashboard in
Grafana. Explain that the application exports metrics and structured logs while
kube-prometheus-stack supplies Prometheus, Alertmanager, Grafana, and Kubernetes
dashboards.

## 9:20–10:15 — Honest tradeoffs and production next steps

“I optimized this for a 90-minute challenge. PostgreSQL is persistent but still
single-replica, the frontend uses a public LoadBalancer rather than TLS ingress,
and monitoring storage is ephemeral. At scale I would use Azure Database for
PostgreSQL with backups and zone redundancy, private AKS and Key Vault
endpoints, TLS ingress, NetworkPolicies, HPA, persistent monitoring storage,
signed images, admission policy, and separate promotion branches with approval
gates. I would also enable Argo self-healing after the demo.”

End on the healthy application and successful Argo/Jenkins status.
