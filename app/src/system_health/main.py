"""FastAPI application factory, routes and the uvicorn entrypoint.

Endpoints
---------
``GET /``        service banner with the running version
``GET /health``  liveness probe
``GET /metrics`` Prometheus exposition of request count, error count and latency
"""

from __future__ import annotations

import logging
import signal
import time
from contextlib import asynccontextmanager
from typing import AsyncIterator

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

from . import __version__
from .config import Settings, get_settings
from .logging_config import configure_logging, log_event
from .metrics import render_metrics
from .middleware import RequestContextMiddleware

LOGGER = logging.getLogger("system_health")


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the FastAPI application."""
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    started_at = time.monotonic()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        log_event(
            LOGGER,
            logging.INFO,
            "startup",
            app_name=settings.app_name,
            app_version=settings.app_version,
            host=settings.host,
            port=settings.port,
            metrics_path=settings.metrics_path,
        )
        yield
        log_event(
            LOGGER,
            logging.INFO,
            "shutdown",
            app_name=settings.app_name,
            app_version=settings.app_version,
            uptime_seconds=round(time.monotonic() - started_at, 3),
        )

    app = FastAPI(
        title="CareGuide System Health",
        description="Liveness and Prometheus metrics endpoints for the DevOps task app.",
        version=settings.app_version,
        lifespan=lifespan,
    )

    app.add_middleware(RequestContextMiddleware, metrics_path=settings.metrics_path)

    @app.get("/", tags=["service"], summary="Service banner")
    async def read_root() -> JSONResponse:
        """Return the service banner."""
        return JSONResponse(
            {
                "message": "Hello from DevOps Task!",
                "status": "running",
                "version": settings.app_version,
            }
        )

    @app.get("/health", tags=["service"], summary="Liveness probe")
    async def read_health() -> JSONResponse:
        """Return the liveness state of the process."""
        return JSONResponse(
            {
                "status": "healthy",
                "version": settings.app_version,
                "uptime_seconds": round(time.monotonic() - started_at, 3),
            }
        )

    @app.get(settings.metrics_path, tags=["service"], summary="Prometheus metrics")
    async def read_metrics() -> Response:
        """Return the Prometheus exposition format."""
        body, content_type = render_metrics()
        return Response(content=body, media_type=content_type)

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        """Log an unhandled error and answer with a JSON error body."""
        LOGGER.error(
            "unhandled exception",
            extra={
                "event": "unhandled_exception",
                "error_type": type(exc).__name__,
                "error_message": str(exc),
                "path": request.url.path,
            },
            exc_info=exc,
        )
        return JSONResponse(
            status_code=500,
            content={
                "status": "error",
                "message": "internal server error",
                "version": settings.app_version,
            },
        )

    return app


class GracefulServer(uvicorn.Server):
    """Uvicorn server that reports the shutdown signal as a structured event."""

    def handle_exit(self, sig: int, frame: object) -> None:
        try:
            signal_name = signal.Signals(sig).name
        except ValueError:  # pragma: no cover - defensive, signal is always known
            signal_name = str(sig)

        log_event(
            LOGGER,
            logging.INFO,
            "shutdown",
            signal=signal_name,
            reason="signal",
        )
        super().handle_exit(sig, frame)  # type: ignore[arg-type]


def main() -> None:
    """Run the service with uvicorn."""
    settings = get_settings()
    configure_logging(settings.log_level)

    config = uvicorn.Config(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        log_config=None,
        access_log=False,
        timeout_graceful_shutdown=settings.graceful_timeout,
        timeout_keep_alive=settings.request_timeout,
    )
    GracefulServer(config).run()


app = create_app()


if __name__ == "__main__":  # pragma: no cover - process entrypoint
    main()
