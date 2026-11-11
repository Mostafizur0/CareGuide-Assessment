"""Prometheus metrics for the system-health service.

Three metrics are exposed on the default registry:

``http_requests_total``
    Counter of every served request, labelled by method, route template and
    status code.
``http_request_errors_total``
    Counter of responses with a status code of 400 or above.
``http_request_duration_seconds``
    Histogram of request latency, labelled by method and route template.
"""

from __future__ import annotations

from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Histogram, generate_latest
from prometheus_client import REGISTRY as DEFAULT_REGISTRY

REQUEST_LATENCY_BUCKETS = (
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    0.5,
    1.0,
    2.5,
    5.0,
    10.0,
)

_REQUEST_LABELS = ("method", "route", "status_code")
_DURATION_LABELS = ("method", "route")

http_requests_total = Counter(
    "http_requests_total",
    "Total number of HTTP requests handled by the service.",
    _REQUEST_LABELS,
    registry=DEFAULT_REGISTRY,
)

http_request_errors_total = Counter(
    "http_request_errors_total",
    "Total number of HTTP requests answered with a 4xx or 5xx status code.",
    _REQUEST_LABELS,
    registry=DEFAULT_REGISTRY,
)

http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    _DURATION_LABELS,
    buckets=REQUEST_LATENCY_BUCKETS,
    registry=DEFAULT_REGISTRY,
)


def record_request(method: str, route: str, status_code: int, duration_seconds: float) -> None:
    """Record a single completed request."""
    status_label = str(status_code)
    http_requests_total.labels(method=method, route=route, status_code=status_label).inc()
    http_request_duration_seconds.labels(method=method, route=route).observe(duration_seconds)
    if status_code >= 400:
        http_request_errors_total.labels(method=method, route=route, status_code=status_label).inc()


def render_metrics(registry: CollectorRegistry = DEFAULT_REGISTRY) -> tuple[bytes, str]:
    """Return the Prometheus exposition body and its content type."""
    return generate_latest(registry), CONTENT_TYPE_LATEST
