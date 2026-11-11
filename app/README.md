# CareGuide System Health Service

A minimal FastAPI service that exposes a banner, a liveness probe and Prometheus
metrics, with structured JSON logging and graceful shutdown on `SIGTERM`.

Built for the CareGuide DevOps assessment task defined in [`Prompt.md`](Prompt.md).

## Endpoints

### `GET /`

```json
{"message": "Hello from DevOps Task!", "status": "running", "version": "1.0.0"}
```

### `GET /health`

Liveness probe. Returns `200` with the running version and uptime.

```json
{"status": "healthy", "version": "1.0.0", "uptime_seconds": "12.34"}
```

### `GET /metrics`

Prometheus exposition format (`text/plain; version=0.0.4`). Includes the default
Python process and platform collectors plus:

| Metric | Type | Labels | Description |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `route`, `status_code` | Every served request |
| `http_request_errors_total` | Counter | `method`, `route`, `status_code` | Responses with status >= 400 |
| `http_request_duration_seconds` | Histogram | `method`, `route` | Request latency, buckets 5 ms to 10 s |

`route` carries the route template (`/`, `/health`) rather than the raw path, which
keeps label cardinality bounded. Scrapes of `/metrics` are excluded from the
counters so that reading the metrics never inflates them.

## Configuration

All settings are read from the environment; every one has a working default.

| Variable | Default | Purpose |
|---|---|---|
| `APP_NAME` | `system-health` | Service name used in logs |
| `APP_VERSION` | `1.0.0` | Version reported by `/`, `/health` and the OCI label |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Bind port |
| `LOG_LEVEL` | `INFO` | Root log level |
| `LOG_FORMAT` | `json` | Log format (only `json` is implemented) |
| `METRICS_PATH` | `/metrics` | Path the exposition is served on |
| `GRACEFUL_TIMEOUT` | `30` | Seconds uvicorn waits for in-flight requests on shutdown |
| `REQUEST_TIMEOUT` | `30` | Keep-alive timeout in seconds |

## Local development

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt

# run the service
python -m system_health.main          # uses PYTHONPATH=src below
```

The package lives under `src/`, so either install it or point `PYTHONPATH` at it:

```bash
PYTHONPATH=src python -m system_health.main
PYTHONPATH=src uvicorn system_health.main:app --host 0.0.0.0 --port 8080
```

Run the test suite:

```bash
PYTHONPATH=src pytest
```

`pyproject.toml` already sets `pythonpath = ["src"]`, so a plain `pytest` from this
directory is enough.

## Container image

The image is built in two stages. The builder resolves the pinned dependencies into
`/opt/venv` with `uv`; the runtime stage copies only that virtualenv and the
application source, runs as a non-root user (`uid 10001`) and drops `pip` entirely.

```bash
docker build -t careguide/system-health:1.0.0 \
  --build-arg APP_VERSION=1.0.0 \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  .

docker run -d --name system-health -p 8080:8080 careguide/system-health:1.0.0
```

Image properties:

- **Base image** — `python:3.13-alpine3.21`, pinned by version.
- **Non-root** — `USER app:app`, uid/gid `10001`.
- **Healthcheck** — `HEALTHCHECK` polls `http://127.0.0.1:8080/health` every 30 s
  using the interpreter from the virtualenv, so no extra package is needed in the image.
- **Stop signal** — `STOPSIGNAL SIGTERM`, which the service handles gracefully.
- **OCI labels** — `title`, `description`, `version`, `revision`, `created`, `source`,
  `url`, `vendor`, `licenses` and `base.name`.

## Logging

Every endpoint emits a structured JSON line. The format is stable and ready for
Loki and Grafana Alloy to ingest without a parsing stage:

```json
{"message": "request completed", "event": "request_completed", "request_id": "aae292fa93e34fc0aaa3efe611d3e770",
 "method": "GET", "route": "/", "path": "/", "status_code": 200, "duration_ms": 0.921,
 "client_ip": "10.0.0.5", "user_agent": "curl/8.7.1", "protocol": "1.1",
 "timestamp": "2026-11-11T14:32:43.491Z", "level": "INFO", "logger": "system_health.access"}
```

Stream split for the collectors:

| Stream | Levels | Typical use |
|---|---|---|
| `stdout` | `INFO` and below | Access logs, startup and shutdown events |
| `stderr` | `WARNING` and above | Errors and tracebacks |

Each response carries an `X-Request-ID` header. An incoming `X-Request-ID` is
honoured, otherwise a UUID4 is generated; the same value appears in the response
header and in the access log line, which is what makes request tracing across
services possible.

Startup and shutdown are logged as events with an `event` key:

```json
{"message": "startup", "event": "startup", "app_name": "system-health", "app_version": "1.0.0", ...}
{"message": "shutdown", "event": "shutdown", "signal": "SIGTERM", "reason": "signal", ...}
```

## Graceful shutdown

`SIGTERM` is handled by a `uvicorn.Server` subclass that logs the signal and then
delegates to uvicorn's normal exit path: the server stops accepting new connections
and waits up to `GRACEFUL_TIMEOUT` seconds for in-flight requests to finish. The
process then exits with code `0`.

```bash
docker stop system-health
# {"message": "shutdown", "event": "shutdown", "signal": "SIGTERM", "reason": "signal", ...}
```

## Notes on dependency pins

- `uvicorn` is installed without the `[standard]` extra on purpose: `uvloop` and
  `httptools` publish no musl wheels, so `[standard]` would force a source build on
  Alpine. The image stays small and the build stays fast.
- `python-json-logger` is pinned to `3.3.0`. The `2.9.0` version does not exist
  upstream; the highest published 2.x release is `2.0.7`.
- If a pinned wheel ever becomes unavailable for `cp313`/musl, add `build-base` to
  the builder stage (`RUN apk add --no-cache build-base`) — the runtime stage stays
  clean — or fall back to `PYTHON_VERSION=3.12`.

## Layout

```
app/
├── Dockerfile
├── .dockerignore
├── requirements.txt
├── requirements-dev.txt
├── pyproject.toml
├── src/system_health/
│   ├── __init__.py
│   ├── config.py
│   ├── logging_config.py
│   ├── metrics.py
│   ├── middleware.py
│   └── main.py
└── tests/
    ├── conftest.py
    ├── test_root.py
    ├── test_health.py
    └── test_metrics.py
```
