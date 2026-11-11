"""Structured JSON logging setup.

The service emits one JSON object per line so that Loki and Grafana Alloy
can ingest it without a parsing stage:

* ``stdout`` carries ``INFO`` and below.
* ``stderr`` carries ``WARNING`` and above.
"""

from __future__ import annotations

import logging
import sys
from datetime import datetime, timezone
from typing import Any

from pythonjsonlogger.json import JsonFormatter as _BaseJsonFormatter


def _utc_timestamp(record: logging.LogRecord) -> str:
    """Render the record timestamp as ISO-8601 UTC with a ``Z`` suffix."""
    moment = datetime.fromtimestamp(record.created, tz=timezone.utc)
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


class JsonFormatter(_BaseJsonFormatter):
    """Render a log record as a single-line JSON object.

    The record shape is stable across the whole service:
    ``timestamp``, ``level``, ``logger``, ``message`` plus any ``extra``
    keyword passed to the logging call.
    """

    def add_fields(
        self,
        log_record: dict[str, Any],
        record: logging.LogRecord,
        message_dict: dict[str, Any],
    ) -> None:
        super().add_fields(log_record, record, message_dict)

        # uvicorn attaches an ANSI coloured copy of the message; it is noise
        # in a JSON payload and confuses log pipelines.
        log_record.pop("color_message", None)

        log_record["timestamp"] = _utc_timestamp(record)
        log_record["level"] = record.levelname
        log_record["logger"] = record.name
        log_record["message"] = record.getMessage()

        if record.exc_info:
            exc_type, exc_value, _ = record.exc_info
            log_record["error_type"] = exc_type.__name__ if exc_type else "Exception"
            log_record["error_message"] = str(exc_value)
            log_record["traceback"] = self.formatException(record.exc_info)


def configure_logging(level: str = "INFO") -> None:
    """Attach the stdout/stderr JSON handlers to the root logger.

    The function is idempotent: repeated calls replace the handlers instead
    of duplicating every log line.
    """
    root = logging.getLogger()
    root.setLevel(level)

    for handler in list(root.handlers):
        if getattr(handler, "_system_health", False):
            root.removeHandler(handler)
            handler.close()

    formatter = JsonFormatter("%(message)s")

    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setLevel(logging.INFO)
    stdout_handler.setFormatter(formatter)
    stdout_handler._system_health = True  # type: ignore[attr-defined]

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(logging.WARNING)
    stderr_handler.setFormatter(formatter)
    stderr_handler._system_health = True  # type: ignore[attr-defined]

    root.addHandler(stdout_handler)
    root.addHandler(stderr_handler)

    # uvicorn installs its own plaintext handlers; drop them so the JSON
    # formatter stays the single source of truth.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers = []
        uvicorn_logger.propagate = True


def log_event(logger: logging.Logger, level: int, event: str, **fields: Any) -> None:
    """Emit a structured event with a consistent ``event`` key."""
    logger.log(level, event, extra={"event": event, **fields})
