"""Tests for the service banner endpoint ``GET /``."""

from __future__ import annotations


def test_root_returns_200(client):
    response = client.get("/")

    assert response.status_code == 200


def test_root_returns_json_content_type(client):
    response = client.get("/")

    assert response.headers["content-type"].startswith("application/json")


def test_root_returns_exact_payload(client, settings):
    response = client.get("/")

    assert response.json() == {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": settings.app_version,
    }


def test_root_payload_has_exactly_three_keys(client):
    response = client.get("/")

    assert set(response.json().keys()) == {"message", "status", "version"}


def test_root_version_is_not_empty(client):
    response = client.get("/")

    assert response.json()["version"]


def test_root_echoes_incoming_request_id(client):
    response = client.get("/", headers={"X-Request-ID": "test-request-id"})

    assert response.headers["x-request-id"] == "test-request-id"


def test_root_generates_request_id_when_missing(client):
    response = client.get("/")

    assert response.headers.get("x-request-id")
