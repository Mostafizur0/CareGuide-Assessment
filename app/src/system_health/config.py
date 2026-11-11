"""Environment driven application settings.

Kept dependency free on purpose: the image ships only the runtime wheels
listed in requirements.txt, so configuration is read straight from the
process environment with the standard library.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env_str(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value else default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    """Runtime configuration for the service."""

    app_name: str = field(default_factory=lambda: _env_str("APP_NAME", "system-health"))
    app_version: str = field(default_factory=lambda: _env_str("APP_VERSION", "1.0.0"))
    host: str = field(default_factory=lambda: _env_str("HOST", "0.0.0.0"))
    port: int = field(default_factory=lambda: _env_int("PORT", 8000))
    log_level: str = field(default_factory=lambda: _env_str("LOG_LEVEL", "INFO").upper())
    log_format: str = field(default_factory=lambda: _env_str("LOG_FORMAT", "json").lower())
    metrics_path: str = field(default_factory=lambda: _env_str("METRICS_PATH", "/metrics"))
    graceful_timeout: int = field(default_factory=lambda: _env_int("GRACEFUL_TIMEOUT", 30))
    request_timeout: int = field(default_factory=lambda: _env_int("REQUEST_TIMEOUT", 30))


def get_settings() -> Settings:
    """Return a fresh settings snapshot from the current environment."""
    return Settings()
