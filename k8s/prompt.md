In k8s/ directory write manifest files to deploy the app in /app folder with below configuration:
1. Deployment the app as a deployment with /health endpoint check, production grade securityContext, resource request and limit, replica 3
2. resource requests memory: 256m, cpus: 0.5 and limits as memory: 600m, cpus: 1m
3. expose the app using Service nad Ingress
4. use ConfigMap and Secret for config and secret management
5. set HorizontalPodAutoscaler for high avaiability
6. use rolling update with 25% availability, and rollback if any update fails
7. deploy system_health_app/scripts/system_health.sh as cronjob in the node
