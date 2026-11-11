write a web app in Python FastAPI with below features:
endpoint 1. GET / returns {"message": "Hello from DevOps Task!", "status": "running", "version": "<app version>"} 
endpoint 2. GET /health for liveness check
endpoint 3. GET /metrics for exposesing Prometheus-format metrics, including request count, error count, and a request latency histogram

add unit tests for the endpoints / and /health.

add structured (JSON) logs in each endpoint and emit  to stdout / stderr, and shut down gracefully on SIGTERM. for logs we are using Loki and Grafana Alloy

write a multi-stage build file targeting minimum image size, use base image with specific version, use non-root user for application image, with HEALTHCHECK in /health endpoint, proper OCI labels and dockerignore file
