# Kubernetes deployment — CareGuide system-health

Manifest set for the FastAPI service in `app/`, answering `k8s/prompt.md`.

| File | Contents |
|---|---|
| `00-namespace.yaml` | Namespace `careguide-system-health`, ServiceAccount `system-health`, ResourceQuota, LimitRange |
| `01-configmap-secret.yaml` | ConfigMap `system-health-config` (non-secret settings), Secret `system-health-secrets` (placeholders) |
| `02-deployment.yaml` | Deployment `system-health`, 3 replicas, probes, hardened securityContext, rolling update |
| `03-service.yaml` | ClusterIP Service `system-health`, port 8080 → 8080 |
| `04-ingress.yaml` | Ingress `system-health`, `ingressClassName: traefik`, host `system-health.local` |
| `05-hpa.yaml` | HorizontalPodAutoscaler `system-health`, 3–10 replicas, CPU 70% / memory 75% |
| `06-cronjob.yaml` | Namespace + ServiceAccount + ConfigMap + CronJob running `system_health.sh` with `hostPID` |
| `kustomization.yaml` | Ties the set together for `kubectl apply -k k8s/` |

## Prerequisites

- A Kubernetes cluster ≥ 1.25 (verified on **kind** with Kubernetes v1.30.2, two nodes).
- `kubectl` with `kustomize` support (kubectl ≥ 1.14).
- **Traefik** as the ingress controller — the Ingress in `04-ingress.yaml` uses `ingressClassName: traefik`.
- **metrics-server** — the HPA cannot compute CPU/memory utilization without it.
- The application image available in the cluster.

### Install the controllers

```bash
# Traefik
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik -n traefik --create-namespace --set service.spec.type=NodePort

# metrics-server (needed by the HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

If the target cluster already runs ingress-nginx instead, change `ingressClassName` in
`04-ingress.yaml` to `nginx` and set `pathType: ImplementationSpecific`.

## Two namespaces, and why

The application pods fully satisfy the Pod Security **restricted** profile, so the
application namespace is enforced at `restricted`:

```
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

The node-level CronJob needs `hostPID: true` and a `hostPath` log volume. **Both are
forbidden by `baseline`**, so the node agent cannot live in that namespace. There is
no per-namespace Pod Security exemption — exemptions are configured in the
AdmissionController config file, not as a label — so the agent gets its own
namespace instead:

| Namespace | Pod Security | Contents |
|---|---|---|
| `careguide-system-health` | `restricted` | Deployment, Service, Ingress, HPA, ConfigMap, Secret |
| `careguide-system-health-nodeagent` | `privileged` | CronJob and its script ConfigMap |

The privileged namespace holds exactly one workload. That is a deliberate, visible
trade-off rather than a hidden one.

## The image

The manifests reference `ghcr.io/mostafizur0/careguide-assessment:1.0.0`, published
by `.github/workflows/release.yml`.

> **That tag is not published yet.** An anonymous pull from GHCR returns `denied`,
> so the image must be built locally for a first deployment.

```bash
# build from app/ and tag it exactly as the manifests expect
docker build -t ghcr.io/mostafizur0/careguide-assessment:1.0.0 app/

# load it into a kind cluster (no registry needed)
kind load docker-image ghcr.io/mostafizur0/careguide-assessment:1.0.0 --name kind

# the node agent image
docker build -t careguide/system-health-agent:1.0.0 system_health_app/
kind load docker-image careguide/system-health-agent:1.0.0 --name kind
```

For a real cluster, push to GHCR/ECR and let the nodes pull:

```bash
kubectl -n careguide-system-health set image deployment/system-health \
  system-health=ghcr.io/mostafizur0/careguide-assessment:sha-<commit>
```

## Apply

```bash
kubectl apply -k k8s/
```

Output on an already-applied cluster:

```
namespace/careguide-system-health unchanged
namespace/careguide-system-health-nodeagent unchanged
resourcequota/node-agent-quota unchanged
resourcequota/system-health-quota unchanged
serviceaccount/node-agent unchanged
serviceaccount/system-health unchanged
configmap/system-health-script unchanged
configmap/system-health-config unchanged
secret/system-health-secrets configured
service/system-health configured
limitrange/node-agent-limits unchanged
limitrange/system-health-limits unchanged
deployment.apps/system-health unchanged
cronjob.batch/system-health-check unchanged
horizontalpodautoscaler.autoscaling/system-health unchanged
ingress.networking.k8s.io/system-health unchanged
```

The files are numbered so a plain `kubectl apply -f k8s/` also applies them in a
working order, but `-k` is preferred: it resolves the whole set and the image tag in
one step.

### Static validation

```bash
$ for f in k8s/0*.yaml; do printf "%-28s " "$f"; \
    kubectl apply --dry-run=client -f "$f" >/dev/null 2>&1 && echo OK || echo FAIL; done
k8s/00-namespace.yaml        OK
k8s/01-configmap-secret.yaml OK
k8s/02-deployment.yaml       OK
k8s/03-service.yaml          OK
k8s/04-ingress.yaml          OK
k8s/05-hpa.yaml              OK
k8s/06-cronjob.yaml          OK
```

## Configuration and secrets

### ConfigMap — every non-sensitive setting

`config.py` reads its settings from the environment, and every one has a working
default. The ConfigMap carries all of them:

| Variable | Value | Purpose |
|---|---|---|
| `APP_NAME` | `system-health` | Service name used in logs |
| `APP_VERSION` | `1.0.0` | Version reported by `/`, `/health` and the OCI label |
| `HOST` | `0.0.0.0` | Bind address — must not be `127.0.0.1`, or the Service cannot reach it |
| `PORT` | `8080` | Bind port; the Service and Ingress both target it |
| `LOG_LEVEL` | `INFO` | Root log level |
| `LOG_FORMAT` | `json` | Log format (only `json` is implemented) |
| `METRICS_PATH` | `/metrics` | Path the Prometheus exposition is served on |
| `GRACEFUL_TIMEOUT` | `30` | Seconds uvicorn waits for in-flight requests on shutdown |
| `REQUEST_TIMEOUT` | `30` | Keep-alive timeout in seconds |

The pod consumes it with `envFrom.configMapRef`.

### Secret — placeholders only

The committed Secret contains **placeholder** values:

```yaml
stringData:
  SECRET_KEY: "replace-me-with-a-real-secret-key"
  API_TOKEN: "replace-me-with-a-real-api-token"
```

The pod references them with `secretKeyRef`; no secret value is ever written as a
literal into the pod spec.

**Replace before any real deployment.** Three supported paths:

```bash
# 1. kubectl — value never touches git
kubectl -n careguide-system-health create secret generic system-health-secrets \
  --from-literal=SECRET_KEY="$(openssl rand -base64 32)" \
  --from-literal=API_TOKEN="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Sealed Secrets — encrypts into the repo, only the cluster can decrypt
# 3. External Secrets Operator — pulls from AWS Secrets Manager / Vault
```

With the External Secrets Operator on EKS the Secret becomes a
`ExternalSecret` that syncs from AWS Secrets Manager, and the real material never
enters the cluster as a static object.

### Resource quota and limit range

`ResourceQuota` is sized for the HPA ceiling (10 replicas) plus rollout surge:

| Resource | Hard limit |
|---|---|
| `requests.cpu` | 8 |
| `requests.memory` | 4Gi |
| `limits.cpu` | 16 |
| `limits.memory` | 8Gi |
| `pods` | 30 |
| `persistentvolumeclaims` | 4 |

The `LimitRange` gives any pod that omits explicit resources a default of
`500m` / `256Mi` request and `1` CPU / `600Mi` limit, so a stray pod in the
namespace cannot consume an unbounded amount of the node.

## Units — a trap worth documenting

**Kubernetes' `m` suffix means *milli*, not *mega*.** `600m` is 0.6 **bytes**, not
600 MB. The API server warns:

```
Warning: fractional byte value "600m" is invalid, must be an integer
```

and a pod created with it gets a cgroup `memory.max = 0`, which makes the
container fail to start.

The manifests therefore use the binary suffix `Mi` for memory:

| Setting | Value |
|---|---|
| Deployment request / limit | `256Mi` / `600Mi` |
| CronJob request / limit | `64Mi` / `128Mi` |
| LimitRange default request / limit | `256Mi` / `600Mi` |

The same trap applies to CPU: the task asked for `cpus: 1m` as the limit, but `1m`
is **one millicore** — far below the `500m` request. The API server rejects a limit
lower than the request, so the limit is `cpu: "1"` (one full core). CPU uses `m`
legitimately: `500m` really is half a core.

## Verification

All commands below were run against the kind cluster; the output is real.

### Workloads are healthy

```bash
$ kubectl -n careguide-system-health get pods
NAME                                 READY   STATUS    RESTARTS   AGE
system-health-6d9f575f56-bvs5n       1/1     Running   0          66m
system-health-6d9f575f56-krqgd       1/1     Running   0          66m
system-health-6d9f575f56-vpqs9       1/1     Running   0          69m

$ kubectl -n careguide-system-health get deploy,svc,ingress,hpa,cronjob
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/system-health   3/3     3            3           94m

NAME                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/system-health   ClusterIP   10.96.111.193   <none>        8080/TCP   94m

NAME                                      CLASS     HOSTS                 ADDRESS   PORTS   AGE
ingress.networking.k8s.io/system-health   traefik   system-health.local             80      94m

NAME                                                REFERENCE                  TARGETS                                     MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/system-health   Deployment/system-health   cpu: <unknown>/70%, memory: <unknown>/75%   3         10        3          94m

NAME                            SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
cronjob.batch/system-health-check   */5 * * * *   Etc/UTC    False     0        3m5s            59m
```

The HPA shows `<unknown>` **because metrics-server is not installed in this
cluster** — that is the documented prerequisite, not a manifest defect. With
metrics-server present the columns show a current and target percentage.

### Health and metrics

```bash
$ kubectl -n careguide-system-health port-forward svc/system-health 8080:8080 &

$ curl -s http://localhost:8080/
{"message":"Hello from DevOps Task!","status":"running","version":"1.0.0"}

$ curl -s http://localhost:8080/health
{"status":"healthy","version":"1.0.0","uptime_seconds":2987.407}

$ curl -s http://localhost:8080/metrics | grep -E '^http_requests_total'
http_requests_total{method="GET",route="/health",status_code="200"} 897.0
http_requests_total{method="GET",route="/",status_code="200"} 1.0
```

### Ingress

With `127.0.0.1 system-health.local` in `/etc/hosts`, or with an explicit Host
header:

```bash
$ kubectl -n traefik port-forward svc/traefik 8081:80 &
$ curl -s -H 'Host: system-health.local' http://127.0.0.1:8081/health
{"status":"healthy","version":"1.0.0","uptime_seconds":3001.413}
```

Traefik resolved the backend to all three ready pods
(`10.244.1.108:8080,10.244.1.148:8080,10.244.1.153:8080`).

### Node health agent

```bash
$ kubectl -n careguide-system-health-nodeagent create job \
    --from=cronjob/system-health-check manual-1

$ kubectl -n careguide-system-health-nodeagent get job manual-1
NAME       STATUS     COMPLETIONS   DURATION   AGE
manual-1   Complete   1/1           5s         30s

$ kubectl -n careguide-system-health-nodeagent logs job/manual-1
{"timestamp":"2026-11-11T22:34:10+00:00","status":"healthy","cpu_pct":2,"memory_pct":37,
 "load":"4.47 4.59 4.59","disks":[{"mount":"/","usage_pct":9},{"mount":"/etc/hosts","usage_pct":9}],
 "top_processes":"traefik(pid=50775,mem=1.4%) kubelet(pid=350,mem=1.2%) ...",
 "warnings":[]}
```

The log lands on the node and survives the pod:

```bash
$ docker exec kind-worker cat /var/log/system-health/health_log.txt
{"timestamp":"2026-11-11T22:34:10+00:00","status":"healthy","cpu_pct":2,...}
```

### Rollback drill

```bash
# 1. break the deployment
$ kubectl -n careguide-system-health set image deployment/system-health \
    system-health=ghcr.io/mostafizur0/careguide-assessment:does-not-exist
deployment.apps/system-health image updated

$ kubectl -n careguide-system-health get pods
NAME                                 READY   STATUS      RESTARTS   AGE
system-health-6d9f575f56-bvs5n       1/1     Running    0          53m
system-health-6d9f575f56-krqgd       1/1     Running    0          53m
system-health-6d9f575f56-vpqs9       1/1     Running    0          56m
system-health-d8b84f448-ggl6q        0/1     ErrImagePull   0          3m13s

# 2. roll back
$ kubectl -n careguide-system-health rollout undo deployment/system-health
deployment.apps/system-health rolled back

$ kubectl -n careguide-system-health rollout status deployment/system-health --timeout=180s
deployment "system-health" successfully rolled out
```

Three healthy replicas were restored, and the bad ReplicaSet was scaled to zero.

## Deployment and rollback strategy

| Setting | Value | Why |
|---|---|---|
| `strategy.type` | `RollingUpdate` | No downtime on image change |
| `maxUnavailable` | `25%` | With 3 replicas, at most one pod is taken down at a time |
| `maxSurge` | `25%` | One extra pod is created before one is removed |
| `minReadySeconds` | `10` | A pod must stay ready 10 s before it counts as available |
| `progressDeadlineSeconds` | `600` | A wedged rollout is marked failed instead of hanging forever |
| `revisionHistoryLimit` | `10` | Keeps the last ten ReplicaSets, which is what makes undo possible |
| `terminationGracePeriodSeconds` | `45` | Longer than `GRACEFUL_TIMEOUT=30`, so in-flight requests drain |

Probes all target `/health` on port 8080:

| Probe | Timing | Purpose |
|---|---|---|
| `startupProbe` | period 5 s, failureThreshold 30 | Up to 150 s for a slow first start |
| `readinessProbe` | delay 5 s, period 5 s, failureThreshold 3 | Removes the pod from the Service when it is not serving |
| `livenessProbe` | delay 10 s, period 10 s, failureThreshold 3 | Restarts a hung pod |

```bash
# what happened
kubectl -n careguide-system-health rollout history deployment/system-health
# roll back one revision
kubectl -n careguide-system-health rollout undo deployment/system-health
# roll back to a specific revision
kubectl -n careguide-system-health rollout undo deployment/system-health --to-revision=3
# wait for it to settle
kubectl -n careguide-system-health rollout status deployment/system-health --timeout=300s
```

## The node agent image

The approved plan originally chose `alpine:3.21` with `bash`, `procps` and
`coreutils` installed **at run time**. That cannot work under the approved
security context: `apk add` must write and lock `/lib/apk/db`, but the container
runs as uid 10001 with `readOnlyRootFilesystem: true`:

```
ERROR: Unable to lock database: Permission denied
ERROR: Failed to open apk database: Permission denied
```

`system_health_app/Dockerfile` therefore builds a small image with those three
packages baked in, and the CronJob runs `/bin/bash /opt/scripts/system_health.sh
--json` with no package manager in the runtime path. Every security property is
kept: non-root uid 10001, read-only root filesystem, `drop: [ALL]`,
`allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`.

`procps` is not optional: the script calls
`ps -eo pid,comm,%mem --sort=-%mem`, and BusyBox's `ps` has no `--sort`.

### The hostPath ownership fix

`hostPath` volumes ignore `fsGroup`: kubelet creates `/var/log/system-health` as
`root:root`, so uid 10001 cannot write there. An initContainer hands the directory
to the agent's group:

```yaml
initContainers:
  - name: prepare-log-dir
    command: ["/bin/bash", "-c", "chown 10001:10001 /var/log/system-health"]
    securityContext:
      runAsUser: 0
      capabilities:
        drop: [ALL]
        add: [CHOWN]
```

`chmod` is deliberately not used — it would need `CAP_FOWNER` as well, and the
directory keeps its `0755` mode, which still gives the owner write access.

### The script ConfigMap

The script is delivered as a ConfigMap (`system-health-script`, `defaultMode: 0555`)
rather than a `hostPath`, so it stays versioned with the manifests. After editing
`system_health_app/scripts/system_health.sh`, regenerate it:

```bash
kubectl create configmap system-health-script \
  --from-file=system_health.sh=system_health_app/scripts/system_health.sh \
  --namespace=careguide-system-health-nodeagent \
  --dry-run=client -o yaml
```

## Troubleshooting

**Pods stuck in `ContainerCreating` with a cgroup error**
The memory limit was written as `600m` instead of `600Mi`. See *Units* above.

**`Error creating: pods "..." is forbidden: violates PodSecurity "baseline:latest":
host namespaces (hostPID=true)`**
The CronJob is in the wrong namespace, or the node-agent namespace is missing its
`privileged` label. The agent must live in
`careguide-system-health-nodeagent`.

**CronJob fails with `Failed to open apk database`**
The runtime `apk add` is still in the manifest. Use the agent image from
`system_health_app/Dockerfile` and drop the `apk add` from the command.

**CronJob fails with `tee: /var/log/system-health/health_log.txt: Permission denied`**
The initContainer that fixes the hostPath ownership is missing.

**HPA shows `<unknown>/70%`**
metrics-server is not installed. See *Prerequisites*.

**Ingress returns 404**
Traefik is not installed, or the `Host` header does not match `system-health.local`.

**`ImagePullBackOff`**
The image is not in the cluster. Build and `kind load` it, or push it to a
registry the nodes can reach.
