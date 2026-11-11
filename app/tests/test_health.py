"""Tests for the liveness endpoint ``GET /health``."""

from __future__ import annotations


def test_health_returns_200(client):
    response = client.get("/health")

    assert response.status_code == 200


def test_health_reports_healthy(client):
    response = client.get("/health")

    assert response.json()["status"] == "healthy"


def test_health_reports_version_and_uptime(client, settings):
    payload = client.get("/health").json()

    assert payload["version"] == settings.app_version
    assert "uptime_seconds" in payload
    assert payload["uptime_seconds"] >= 0


def test_health_needs_no_query_parameters_or_auth(client):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "healthy"


def test_health_returns_json_content_type(client):
    response = client.get("/health")

    assert response.headers["content-type"].startswith("application/json")


def test_health_runs_startup_and_shutdown_events(lifespan_client):
    assert lifespan_client.get("/health").status_code == 200
