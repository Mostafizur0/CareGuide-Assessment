write a docker compose file in docker-compose.yml with these settings:
port 8080 expose app application in /app folder
add health check for /health endpoint of the app, 
restart policy is unless-stopped,
resource limits mem_limit: 256m, cpus: 0.5
in a bridge network named app-bridge

write another docker compose file in docker-compose.monitoring.yml with these settings:
in the same bridge network named app-bridge as above
add Prometheus, Grafana, Loki, Grafana Alloy, Node Exporter, and cAdvisor
with retention period of 7 days
1. Metrics collection:
– Prometheus scrapes the app's /metrics endpoint, Node Exporter (host metrics), and cAdvisor (container metrics).
–  Prometheus data retention period is 30 days
2. Log collection:
– Grafana Alloy collects logs from all containers (via Docker service discovery) and ships them to Loki.
– Parse the app's structured JSON logs so that fields such as log level and request path can be used as labels or filters in Grafana. Keep label cardinality low.
– retention period for Loki data is 7 days
3. Visualization (Grafana):
– add Prometheus and Loki as Data sources and dashboards configs
– export these three dashboards as JSON
• Application: request rate, error rate, and latency (p50/p95/p99).
• Host: CPU, memory, disk, and network usage from Node Exporter.
• Containers: per-container CPU and memory usage from cAdvisor, including memory usage relative to the configured limit.
– add a Loki logs panel next to the related metrics, so an error spike can be investigated in the same view for one dashboard.
4. Alerting:
– Define at least four alerting rules (Prometheus rules or Grafana alerting), for example: app instance down, high error rate, host disk usage above 80%, and container memory close to its limit.
5. Hygiene and security:
– put Grafana admin credentials in environment variables or a secret
– Only Grafana is exposed to the host. Prometheus, Loki, Alloy, Node Exporter, and cAdvisor communicate over an internal Docker network.
– Pin all image versions.
– provide host resources access for cAdvisor and Node Exporter. 
