"""Smoke tests for the Prometheus endpoint ``GET /metrics``."""

from __future__ import annotations

from system_health.metrics import http_requests_total


def test_metrics_returns_200(client):
    response = client.get("/metrics")

    assert response.status_code == 200


def test_metrics_uses_prometheus_content_type(client):
    response = client.get("/metrics")

    assert response.headers["content-type"].startswith("text/plain")
    assert "version=0.0.4" in response.headers["content-type"]


def test_metrics_exposes_request_counter(client):
    body = client.get("/metrics").text

    assert "http_requests_total" in body


def test_metrics_exposes_error_counter(client):
    body = client.get("/metrics").text

    assert "http_request_errors_total" in body


def test_metrics_exposes_latency_histogram(client):
    body = client.get("/metrics").text

    assert "http_request_duration_seconds_bucket" in body
    assert "http_request_duration_seconds_count" in body


def test_request_to_root_increments_request_counter(client):
    before = http_requests_total.labels(method="GET", route="/", status_code="200")._value.get()

    client.get("/")

    after = http_requests_total.labels(method="GET", route="/", status_code="200")._value.get()
    assert after == before + 1


def test_metrics_scrape_does_not_count_itself(client):
    client.get("/metrics")
    before = http_requests_total.labels(method="GET", route="/metrics", status_code="200")._value.get()

    client.get("/metrics")

    after = http_requests_total.labels(method="GET", route="/metrics", status_code="200")._value.get()
    assert after == before
