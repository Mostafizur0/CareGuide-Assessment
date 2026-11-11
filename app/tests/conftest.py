"""Shared pytest fixtures."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from system_health.config import get_settings
from system_health.main import app


@pytest.fixture()
def client() -> TestClient:
    """A test client without lifespan handling, for plain request assertions."""
    return TestClient(app)


@pytest.fixture()
def lifespan_client() -> TestClient:
    """A test client that runs the startup and shutdown lifespan events."""
    with TestClient(app) as running_client:
        yield running_client


@pytest.fixture()
def settings():
    """The settings snapshot the application was built with."""
    return get_settings()
