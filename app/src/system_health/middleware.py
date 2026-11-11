"""Request instrumentation middleware.

A single pure-ASGI middleware provides request id propagation, the JSON
access log and the Prometheus instrumentation.  It is deliberately not
built on ``BaseHTTPMiddleware`` to avoid the extra task overhead and the
streaming edge cases that come with it.
"""

from __future__ import annotations

import logging
import time
import uuid

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .metrics import record_request

ACCESS_LOGGER = logging.getLogger("system_health.access")
REQUEST_ID_HEADER = "x-request-id"


class RequestContextMiddleware:
    """Attach a request id, time the request and emit the access log."""

    def __init__(self, app: ASGIApp, metrics_path: str = "/metrics") -> None:
        self.app = app
        self.metrics_path = metrics_path

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = self._resolve_request_id(scope)
        scope.setdefault("state", {})
        scope["state"]["request_id"] = request_id

        started = time.perf_counter()
        status_code = 500

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = int(message.get("status", 500))
                headers = list(message.get("headers", []))
                headers.append((REQUEST_ID_HEADER.encode(), request_id.encode()))
                message = {**message, "headers": headers}
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration_seconds = time.perf_counter() - started
            route = self._resolve_route(scope)
            self._record(scope, route, status_code, duration_seconds, request_id)

    @staticmethod
    def _resolve_request_id(scope: Scope) -> str:
        """Honour an incoming ``X-Request-ID`` or generate a new one."""
        for key, value in scope.get("headers", []):
            if key.decode("latin-1").lower() == REQUEST_ID_HEADER:
                candidate = value.decode("latin-1").strip()
                if candidate:
                    return candidate
        return uuid.uuid4().hex

    @staticmethod
    def _resolve_route(scope: Scope) -> str:
        """Return the route template, falling back to the raw path."""
        route = scope.get("route")
        path = getattr(route, "path", None)
        if path:
            return str(path)
        raw_path = scope.get("raw_path") or scope.get("path") or "/"
        return raw_path.decode("latin-1") if isinstance(raw_path, bytes) else str(raw_path)

    def _record(
        self,
        scope: Scope,
        route: str,
        status_code: int,
        duration_seconds: float,
        request_id: str,
    ) -> None:
        method = scope.get("method", "GET")
        path = scope.get("path", "/")

        # Scraping /metrics must not inflate the counters it exposes.
        if route != self.metrics_path and path != self.metrics_path:
            record_request(
                method=method,
                route=route,
                status_code=status_code,
                duration_seconds=duration_seconds,
            )

        client = scope.get("client")
        client_ip = client[0] if client else None
        headers = {
            key.decode("latin-1").lower(): value.decode("latin-1")
            for key, value in scope.get("headers", [])
        }

        ACCESS_LOGGER.info(
            "request completed",
            extra={
                "event": "request_completed",
                "request_id": request_id,
                "method": method,
                "route": route,
                "path": path,
                "status_code": status_code,
                "duration_ms": round(duration_seconds * 1000, 3),
                "client_ip": client_ip,
                "user_agent": headers.get("user-agent"),
                "protocol": scope.get("http_version"),
            },
        )


__all__ = ["RequestContextMiddleware", "ACCESS_LOGGER", "REQUEST_ID_HEADER"]
