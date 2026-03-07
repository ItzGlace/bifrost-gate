#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash /var/www/restart-slip-server.sh [service-prefix]
# Default service-prefix is "slipstream".

SERVICE_PREFIX="${1:-${SERVICE_PREFIX:-slipstream}}"
SYSTEMD_DIR="/etc/systemd/system"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2; }

if [[ "$(id -u)" -ne 0 ]]; then
    err "Run as root (needed for systemctl restart)."
    exit 1
fi

mapfile -t SLIP_UNITS < <(
    find "$SYSTEMD_DIR" -maxdepth 1 -type f -name "${SERVICE_PREFIX}-*.service" -printf '%f\n' 2>/dev/null | sort
)
if [[ -f "${SYSTEMD_DIR}/${SERVICE_PREFIX}.service" ]]; then
    SLIP_UNITS+=("${SERVICE_PREFIX}.service")
fi

if [[ "${#SLIP_UNITS[@]}" -eq 0 ]]; then
    err "No services found for prefix '${SERVICE_PREFIX}' in ${SYSTEMD_DIR}."
    exit 1
fi

log "Restarting ${#SLIP_UNITS[@]} slipstream service(s) with prefix '${SERVICE_PREFIX}'..."
for unit in "${SLIP_UNITS[@]}"; do
    systemctl restart "$unit"
done

log "Restarting dnsdist..."
systemctl restart dnsdist

declare -a FAILED_UNITS=()
for unit in "${SLIP_UNITS[@]}"; do
    if ! systemctl is-active --quiet "$unit"; then
        FAILED_UNITS+=("$unit")
    fi
done
if ! systemctl is-active --quiet dnsdist; then
    FAILED_UNITS+=("dnsdist")
fi

if [[ "${#FAILED_UNITS[@]}" -gt 0 ]]; then
    err "Some services are not active after restart: ${FAILED_UNITS[*]}"
    exit 1
fi

log "Restart completed successfully."
