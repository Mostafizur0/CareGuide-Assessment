# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Node health agent image.
#
# Runs system_health_app/scripts/system_health.sh against the NODE it is
# scheduled on. The script needs:
#
#   bash      - the script is a bash script, not a POSIX sh script
#   procps    - `ps -eo pid,comm,%mem --sort=-%mem`; BusyBox's ps has no
#               --sort option, so the procps implementation is required
#   coreutils - GNU `df -P`, `tee`, `wc`, `mv`, `date -Is`; BusyBox's df and
#               date differ in the flags the script relies on
#
# The dependencies are baked in at build time on purpose. Installing them at
# run time with `apk add` cannot work under the hardened security context the
# CronJob uses: apk must write and lock /lib/apk/db, but the container runs as
# a non-root user (uid 10001) with a read-only root filesystem, so apk fails
# with "Failed to open apk database: Permission denied".
#
# Publishing an image with the dependencies pre-installed keeps the security
# context intact and removes the package manager from the runtime path.
# ---------------------------------------------------------------------------

FROM alpine:3.21

LABEL org.opencontainers.image.title="CareGuide System Health Node Agent" \
      org.opencontainers.image.description="Node-level health check agent running system_health.sh with hostPID." \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.source="https://github.com/Mostafizur0/CareGuide-Assessment" \
      org.opencontainers.image.vendor="CareGuide" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.21"

RUN apk add --no-cache bash procps coreutils

# The script is delivered through a ConfigMap and mounted at /opt/scripts, so
# the image itself does not carry a copy. The entrypoint below is overridden by
# the CronJob command; it only exists so the image is runnable on its own.
ENTRYPOINT ["/bin/bash"]
CMD ["/opt/scripts/system_health.sh", "--json"]
