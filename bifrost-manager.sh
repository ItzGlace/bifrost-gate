#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="bifrost-gate.service"
CONFIG_PATH="/etc/bifrost/config.json"
INSTALL_DIR="/opt/bifrost"
BINARY_PATH="$INSTALL_DIR/bifrost-gate"

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}

usage() {
  cat <<'USAGE'
Usage: sudo bifrost <command>

Commands:
  status          Show service status
  start           Start service
  stop            Stop service
  restart         Restart service
  enable          Enable service on boot
  disable         Disable service on boot
  logs            Show last 200 log lines
  logs -f         Follow logs
  config          Edit config.json with $EDITOR (or nano)
  show-config     Print config.json
  panel           Show panel URL and admin API endpoint
  api-key         Print API key from config
  uninstall       Remove service, binaries, manager, and config
  help            Show this help
USAGE
}

ensure_service_exists() {
  if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    echo "Service ${SERVICE_NAME} is not installed."
    exit 1
  fi
}

extract_json_value() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$key // empty" "$CONFIG_PATH" 2>/dev/null || true
  else
    case "$key" in
      '.api_key') grep -E '"api_key"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"api_key"\s*:\s*"([^"]+)".*/\1/' ;;
      '.admin.port') grep -E '"port"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"port"\s*:\s*([0-9]+).*/\1/' ;;
      '.admin.host') grep -E '"host"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"host"\s*:\s*"([^"]+)".*/\1/' ;;
      *) ;;
    esac
  fi
}

panel_info() {
  local host port
  host="$(extract_json_value '.admin.host')"
  port="$(extract_json_value '.admin.port')"
  host="${host:-0.0.0.0}"
  port="${port:-11001}"

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip="${ip:-127.0.0.1}"

  echo "Panel login: http://${ip}:${port}/login"
  echo "Admin API:   http://${ip}:${port}/api/listeners"
  echo "Bind host:   ${host}:${port}"
}

uninstall_all() {
  require_root "$@"
  echo "This will remove bifrost service, binaries, manager, and config."
  read -r -p "Type 'yes' to continue: " answer
  if [[ "$answer" != "yes" ]]; then
    echo "Cancelled."
    exit 0
  fi

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload
  rm -f /usr/local/bin/bifrost
  rm -rf "$INSTALL_DIR"
  rm -rf /etc/bifrost
  echo "Bifrost uninstalled."
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    status)
      ensure_service_exists
      systemctl status "$SERVICE_NAME" --no-pager
      ;;
    start)
      require_root "$@"
      ensure_service_exists
      systemctl start "$SERVICE_NAME"
      systemctl status "$SERVICE_NAME" --no-pager
      ;;
    stop)
      require_root "$@"
      ensure_service_exists
      systemctl stop "$SERVICE_NAME"
      systemctl status "$SERVICE_NAME" --no-pager || true
      ;;
    restart)
      require_root "$@"
      ensure_service_exists
      systemctl restart "$SERVICE_NAME"
      systemctl status "$SERVICE_NAME" --no-pager
      ;;
    enable)
      require_root "$@"
      ensure_service_exists
      systemctl enable "$SERVICE_NAME"
      ;;
    disable)
      require_root "$@"
      ensure_service_exists
      systemctl disable "$SERVICE_NAME"
      ;;
    logs)
      ensure_service_exists
      if [[ "${2:-}" == "-f" ]]; then
        journalctl -u "$SERVICE_NAME" -f
      else
        journalctl -u "$SERVICE_NAME" -n 200 --no-pager
      fi
      ;;
    config)
      require_root "$@"
      local editor
      editor="${EDITOR:-nano}"
      "$editor" "$CONFIG_PATH"
      ;;
    show-config)
      cat "$CONFIG_PATH"
      ;;
    panel)
      panel_info
      ;;
    api-key)
      extract_json_value '.api_key'
      ;;
    uninstall)
      uninstall_all "$@"
      ;;
    *)
      echo "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
