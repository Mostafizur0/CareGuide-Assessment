# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build arguments (OCI label inputs)
# ---------------------------------------------------------------------------
ARG PYTHON_VERSION=3.13
ARG ALPINE_VERSION=3.21
ARG UV_VERSION=0.5.11
ARG APP_VERSION=1.0.0
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG APP_SOURCE=https://github.com/Mostafizur0/CareGuide-Assessment

# ---------------------------------------------------------------------------
# Builder: resolve and install the pinned dependency set into a virtualenv
# ---------------------------------------------------------------------------
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM python:${PYTHON_VERSION}-alpine${ALPINE_VERSION} AS builder

ARG PYTHON_VERSION
ARG ALPINE_VERSION

COPY --from=uv /uv /uvx /usr/local/bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /build

COPY requirements.txt ./

RUN uv venv /opt/venv \
    && uv pip install --no-cache --python /opt/venv/bin/python -r requirements.txt

# ---------------------------------------------------------------------------
# Runtime: minimal image, non-root user, healthcheck, OCI labels
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-alpine${ALPINE_VERSION} AS runtime

ARG PYTHON_VERSION
ARG ALPINE_VERSION
ARG APP_VERSION
ARG VCS_REF
ARG BUILD_DATE
ARG APP_SOURCE

LABEL org.opencontainers.image.title="CareGuide System Health" \
      org.opencontainers.image.description="FastAPI liveness and Prometheus metrics service for the CareGuide DevOps assessment." \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="${APP_SOURCE}" \
      org.opencontainers.image.url="${APP_SOURCE}" \
      org.opencontainers.image.vendor="CareGuide" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/python:${PYTHON_VERSION}-alpine${ALPINE_VERSION}"

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION="${APP_VERSION}" \
    HOST=0.0.0.0 \
    PORT=8080 \
    LOG_LEVEL=INFO \
    LOG_FORMAT=json \
    METRICS_PATH=/metrics \
    GRACEFUL_TIMEOUT=30

WORKDIR /app

# Non-root runtime user with a fixed uid/gid.
RUN addgroup -S -g 10001 app \
    && adduser -S -u 10001 -G app app

# Drop the package manager from the runtime image: dependencies are already
# resolved into /opt/venv by the builder stage.
RUN /usr/local/bin/python -m pip uninstall -y --no-cache-dir pip \
    && rm -rf /usr/local/lib/python3.13/site-packages/pip* \
    && rm -f /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.13

COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app src/ /app/src/

USER app:app

EXPOSE 8080

# SIGTERM is the container stop signal, handled by the graceful shutdown path.
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/opt/venv/bin/python", "-c", "import sys,urllib.request;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=3).status==200 else 1)"]

ENTRYPOINT ["/opt/venv/bin/python", "-m", "system_health.main"]
