# CareGuide — Observability Runbook

Two Compose stacks share one Docker bridge network:

| Stack | File | Published ports |
|---|---|---|
| Application | `docker-compose.yml` | `8080` (app) |
| Observability | `docker-compose.monitoring.yml` | `3000` (Grafana only) |

Everything else — Prometheus, Loki, Alloy, Node Exporter, cAdvisor — is reachable
only from inside the `app-bridge` network.

## Prerequisites

- Docker Engine with the Compose v2 plugin (`docker compose version`).
- The application image builds from `app/` and needs no extra tooling.
- On macOS, allocate at least 4 GB of memory to the Docker VM: the stack runs
  Prometheus, Loki, Grafana, Alloy, Node Exporter, cAdvisor and the app.

## Bootstrap

`app-bridge` is a **fixed-name** network. The application stack creates it;
the monitoring stack attaches to it as an external network. Create it by hand
when you want to start the monitoring stack first:

```bash
docker network create app-bridge
```

The command is idempotent enough for a first run — if the network already
exists, Docker reports the existing id and you can continue.

## Start the application stack

```bash
docker compose up -d --build
docker compose ps
curl -s http://localhost:8080/health
curl -s http://localhost:8080/metrics | head -20
```

The app is published on `8080:8080`. The image serves FastAPI on port 8080
with the code under `/app`, runs as a non-root user, restarts unless stopped
and is capped at 256 MB / 0.5 CPU.

## Start the monitoring stack

```bash
docker compose -f docker-compose.monitoring.yml up -d
docker compose -f docker-compose.monitoring.yml ps
```

| Service | URL (inside the network) | Purpose |
|---|---|---|
| Grafana | <http://localhost:3000> | Dashboards and alerting |
| Prometheus | `http://prometheus:9090` | Metrics store, 30 day retention |
| Loki | `http://loki:3100` | Log store, 7 day retention |
| Alloy | `http://alloy:12345` | Log collection pipeline |
| Node Exporter | `http://node-exporter:9100` | Host metrics |
| cAdvisor | `http://cadvisor:8080` | Container metrics |

## Grafana credentials

The admin password is a Docker Compose **secret**, mounted at
`/run/secrets/grafana_admin_password` and read through
`GF_SECURITY_ADMIN_PASSWORD__FILE`. No plaintext password is passed in the
environment or baked into the image.

- User: `admin`
- Password: the content of `secrets/grafana_admin_password.txt`

Rotate it with:

```bash
openssl rand -base64 24 | tr -d '\n' > secrets/grafana_admin_password.txt
docker compose -f docker-compose.monitoring.yml up -d --force-recreate grafana
```

The repository ships `secrets/grafana_admin_password.txt.example` as a
template. Replace the committed placeholder before any real deployment.

## Dashboards

Provisioned from `monitoring/grafana/provisioning/dashboards/`, in the
`CareGuide` folder, referenced by a fixed UID:

| Dashboard | UID | Panels |
|---|---|---|
| CareGuide — Application | `careguide-application` | request rate, error rate, 5xx rate, latency p50/p95/p99, error logs panel, full logs panel |
| CareGuide — Host | `careguide-host` | CPU, memory, disk by mountpoint, network throughput |
| CareGuide — Containers | `careguide-containers` | per-container CPU, memory, memory vs configured limit, configured limit |

The Application dashboard places the Loki logs panel next to the error-rate
panel, so an error spike can be investigated in the same view.

On a healthy stack the *Server error rate (5xx)* panel and the *Error logs*
panel legitimately read **No data** — the application returns no 5xx responses
and logs no ERROR entries. Both light up as soon as a real failure occurs.

## Alerts

Provisioned from `monitoring/grafana/provisioning/alerting/alerting.yaml`.
Six rules across four groups:

| Rule | Condition | For |
|---|---|---|
| App instance down | `up{job="app"} < 0.5` | 1m |
| Application high error rate | error ratio `> 0.05` | 5m |
| Application latency p95 above 1s | `histogram_quantile(0.95, ...) > 1` | 5m |
| Host disk usage above 80% | highest usage on a real filesystem `> 80` | 5m |
| Host CPU saturation above 90% | host CPU `> 90` | 10m |
| Container memory close to its limit | usage / limit `> 0.9` | 5m |

The disk rule takes the **maximum** usage across the real filesystems instead
of pinning `mountpoint="/"`: on Docker Desktop the host root is exposed as
`/oldroot` (an `erofs` snapshot) and a `/`-scoped query returns no data at all.

Each rule is a three-node expression — a Prometheus query (`A`), a reduce
(`C`, `reducer: last`) and a threshold (`D`). Grafana 11 expects `reducer` as a
**top-level field** of the reduce node; nesting it inside `conditions` makes
every rule fail with `failed to parse expression 'C': no reducer specified`.
The threshold node must reference the reduce output (`params: [C]`), never its
own refId. Check the rules with:

```bash
docker compose -f docker-compose.monitoring.yml exec grafana \
  wget -qO- --header='Authorization: Bearer <token>' http://localhost:3000/api/prometheus/grafana/api/v1/rules
```

Every rule should report `health=ok`. A rule stuck at `health=error` carries
the parse error in `lastError`.

The contact point `careguide-webhook` posts to
`http://host.docker.internal:9093/alerts`, a placeholder. Point it at the
real endpoint (Slack, PagerDuty, Alertmanager) by editing
`monitoring/grafana/provisioning/alerting/contact-points.yaml` and recreating
Grafana. Until then the rules evaluate and appear in the UI, but delivery
fails.

## Label policy

Alloy keeps the Loki label set small on purpose:

- **Labels** (indexed): `container`, `service`, `level`, `route`, `stream`
- **Structured metadata** (queryable, not indexed): `request_id`, `status_code`, `method`, `duration_ms`

The raw `path` field is never promoted to a label — unmatched paths would
create an unbounded number of streams. The `route` field is a route template
(`/`, `/health`), so it stays bounded.

## Host access caveats

- **cAdvisor** runs `privileged` with `/`, `/sys`, `/var/run`, `/var/lib/docker`
  and `/dev/disk` mounted. That is the standard requirement for container
  metrics, and it is a meaningful privilege on the host.
- **cAdvisor also needs the containerd socket** (`/run/containerd/containerd.sock`).
  Docker Desktop 4.34+ and Docker Engine 29 use the containerd image store, which
  reports the storage driver as `overlayfs`; cAdvisor ≥ v0.55 then builds a
  containerd client before it registers the Docker factory, and the whole
  Docker factory is skipped when that client cannot be created. The symptom is
  silent: the `cadvisor` Prometheus target stays **up** while
  `container_memory_usage_bytes` has **no series at all**. Override the socket
  paths with `DOCKER_SOCK` and `CONTAINERD_SOCK` if your host differs:

  ```bash
  DOCKER_SOCK=/var/run/docker.sock CONTAINERD_SOCK=/run/containerd/containerd.sock \
    docker compose -f docker-compose.monitoring.yml up -d cadvisor
  ```

  The socket is mounted at `/containerd/containerd.sock` inside the container,
  not under `/run`: `/var/run` is a read-only mount, so a mountpoint created
  there fails with `read-only file system`.
- **Node Exporter** mounts `/proc`, `/sys` and `/` read-only into `/host` and
  runs with `pid: host`.
- **Alloy** mounts `/var/run/docker.sock` read-only so it can discover and tail
  containers. Read-only still allows reading every container's environment
  and logs — treat the host as trusted, or place Alloy on a dedicated host.

## Pinned images

| Service | Image |
|---|---|
| App | `careguide/system-health:1.0.0` (built from `app/`) |
| Prometheus | `prom/prometheus:v2.54.1` |
| Loki | `grafana/loki:3.2.1` |
| Grafana | `grafana/grafana:11.2.0` |
| Alloy | `grafana/alloy:v1.5.1` |
| Node Exporter | `prom/node-exporter:v1.8.2` |
| cAdvisor | `ghcr.io/google/cadvisor:v0.60.6` |

## Troubleshooting

**`network app-bridge was found but has incorrect label`**
A second Compose project tried to create the same network. Run
`docker network create app-bridge` once and make sure the monitoring file keeps
`external: true`.

**No logs in Grafana**
Check `docker compose -f docker-compose.monitoring.yml logs alloy`. A missing
socket mount is the usual cause; the Docker socket path differs on Docker
Desktop for Windows.

**Prometheus targets are down**
`docker compose -f docker-compose.monitoring.yml exec prometheus wget -qO- 'http://localhost:9090/api/v1/targets'`.
The `app` target resolves `app:8080` through the shared network, so the
application stack must be running.

**cAdvisor target is up but the Containers dashboard is empty**
The `cadvisor` scrape target can be healthy while exposing no container
metrics. Look for `Registration of the docker container factory failed` in
`docker compose -f docker-compose.monitoring.yml logs cadvisor` — that means
cAdvisor could not build its containerd client, which happens on every host
using the containerd image store (`overlayfs` driver). Mount the containerd
socket as described under *Host access caveats* and recreate the service.

**Alert rules show `health=error`**
`failed to parse expression 'C': no reducer specified` means the reduce node
is missing its top-level `reducer` field. `failed to parse expression 'D'`
usually means the threshold node points at itself instead of at the reduce
output.

**Dashboards do not appear**
Grafana logs a provisioning error when a dashboard JSON is malformed. Check
`docker compose -f docker-compose.monitoring.yml logs grafana | grep -i provisioning`.

## Teardown

```bash
docker compose -f docker-compose.monitoring.yml down
docker compose down
# keep the metric and log history:
docker compose -f docker-compose.monitoring.yml down -v
```
