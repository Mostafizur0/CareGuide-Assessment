#!/bin/sh
set -eu
new_image=$1 user=$2
container=devops-app
previous=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
aws ssm get-parameter --name /devops/ghcr-read-token --with-decryption --query Parameter.Value --output text | docker login ghcr.io -u "$user" --password-stdin
docker pull "$new_image"
docker rm -f "$container" >/dev/null 2>&1 || true
docker run -d --name "$container" --restart unless-stopped -p 80:8000 -e PORT=8000 -e ENVIRONMENT=production "$new_image"
sleep 8
if ! curl -fsS http://127.0.0.1/health >/dev/null; then
    docker rm -f "$container" >/dev/null
    if [ -n "$previous" ]; then docker run -d --name "$container" --restart unless-stopped -p 80:8000 -e PORT=8000 "$previous"; fi
    exit 1
fi
