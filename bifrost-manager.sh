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

run_root() {
  if [[ "$EUID" -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  bifrost                Open interactive terminal panel
  bifrost <command>

Commands:
  dashboard       Open interactive terminal panel
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
  ip              Query public IP endpoint
  change-license  Update license key in config and restart service
  uninstall       Remove service, binaries, manager, and config
  help            Show this help
USAGE
}

ensure_service_exists() {
  if ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
    echo "Service ${SERVICE_NAME} is not installed."
    exit 1
  fi
}

extract_json_value() {
  local key="$1"
  if [[ ! -f "$CONFIG_PATH" ]]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r "$key // empty" "$CONFIG_PATH" 2>/dev/null || true
    return 0
  fi

  case "$key" in
    '.api_key')
      grep -E '"api_key"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"api_key"\s*:\s*"([^"]+)".*/\1/'
      ;;
    '.admin.port')
      grep -E '"port"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"port"\s*:\s*([0-9]+).*/\1/'
      ;;
    '.admin.host')
      grep -E '"host"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"host"\s*:\s*"([^"]+)".*/\1/'
      ;;
    '.license.license_key')
      grep -E '"license_key"' "$CONFIG_PATH" | head -n1 | sed -E 's/.*"license_key"\s*:\s*"([^"]*)".*/\1/'
      ;;
    *)
      ;;
  esac
}

local_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip:-127.0.0.1}"
}

panel_info() {
  local host port ip
  host="$(extract_json_value '.admin.host')"
  port="$(extract_json_value '.admin.port')"
  host="${host:-0.0.0.0}"
  port="${port:-11001}"
  ip="$(local_ip)"

  echo "Panel login: http://${ip}:${port}/login"
  echo "Admin API:   http://${ip}:${port}/api/listeners"
  echo "Bind host:   ${host}:${port}"
}

fetch_public_ip_payload() {
  local endpoint="https://view.iranmonitor.net/api/v1.0/network/ip"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 8 "$endpoint" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$endpoint" 2>/dev/null || true
  fi
}

extract_public_ip() {
  local payload="$1"
  if [[ -z "$payload" ]]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '.ip // .remote_ip // .address // .data.ip // empty' <<<"$payload" 2>/dev/null || true
  else
    sed -nE 's/.*"(ip|remote_ip|address)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' <<<"$payload" | head -n1
  fi
}

show_public_ip() {
  local endpoint="https://view.iranmonitor.net/api/v1.0/network/ip"
  local payload ip
  payload="$(fetch_public_ip_payload)"
  ip="$(extract_public_ip "$payload")"

  echo "Endpoint: ${endpoint}"
  if [[ -n "$ip" ]]; then
    echo "Detected IP: ${ip}"
  elif [[ -n "$payload" ]]; then
    echo "Raw response: ${payload}"
  else
    echo "Failed to query public IP endpoint."
  fi
}

mask_value() {
  local value="$1"
  local len="${#value}"
  if (( len == 0 )); then
    echo "<empty>"
  elif (( len <= 12 )); then
    echo "$value"
  else
    echo "${value:0:8}...${value:len-4:4}"
  fi
}

change_license_key() {
  require_root "$@"
  [[ -f "$CONFIG_PATH" ]] || { echo "Config not found: $CONFIG_PATH"; exit 1; }

  local new_key
  read -r -p "New license key (leave empty for free demo): " new_key

  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq --arg key "$new_key" '(.license //= {}) | .license.license_key = $key' "$CONFIG_PATH" >"$tmp"
    install -m 600 "$tmp" "$CONFIG_PATH"
    rm -f "$tmp"
  else
    if ! grep -q '"license_key"' "$CONFIG_PATH"; then
      echo "Cannot update license key without jq when config has no license_key field."
      echo "Install jq or edit config manually: $CONFIG_PATH"
      exit 1
    fi
    local escaped
    escaped="$(printf '%s' "$new_key" | sed -e 's/[\/&]/\\&/g')"
    sed -i -E "0,/\"license_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/{s//\"license_key\": \"${escaped}\"/}" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH" || true
  fi

  echo "License key updated in $CONFIG_PATH"
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
    systemctl restart "$SERVICE_NAME"
    echo "Service restarted."
  fi
}

dashboard() {
  ensure_service_exists

  while true; do
    local active enabled pid started host port api_key license_key masked local_ip_val payload public_ip
    active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
    started="$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
    host="$(extract_json_value '.admin.host')"
    port="$(extract_json_value '.admin.port')"
    api_key="$(extract_json_value '.api_key')"
    license_key="$(extract_json_value '.license.license_key')"
    masked="$(mask_value "$license_key")"
    local_ip_val="$(local_ip)"
    payload="$(fetch_public_ip_payload)"
    public_ip="$(extract_public_ip "$payload")"

    clear
    echo "Bifrost Terminal Panel"
    echo "----------------------"
    echo "Service:      ${SERVICE_NAME}"
    echo "State:        ${active:-unknown}"
    echo "Enabled:      ${enabled:-unknown}"
    echo "PID:          ${pid:-0}"
    echo "Started:      ${started:-unknown}"
    echo "Binary:       ${BINARY_PATH}"
    echo "Config:       ${CONFIG_PATH}"
    echo "License key:  ${masked}"
    echo "Panel URL:    http://${local_ip_val}:${port:-11001}/login"
    echo "Admin API:    http://${local_ip_val}:${port:-11001}/api/listeners"
    echo "Bind host:    ${host:-0.0.0.0}:${port:-11001}"
    echo "Public IP:    ${public_ip:-unavailable}"

    if [[ -n "$api_key" ]]; then
      local api_host license_status license_plan license_reason
      api_host="${host:-127.0.0.1}"
      if [[ "$api_host" == "0.0.0.0" || "$api_host" == "::" ]]; then
        api_host="127.0.0.1"
      fi
      license_status="$(curl -fsS --max-time 4 -H "x-api-key: $api_key" "http://${api_host}:${port:-11001}/api/license/status" 2>/dev/null || true)"
      if [[ -n "$license_status" ]]; then
        if command -v jq >/dev/null 2>&1; then
          license_plan="$(jq -r '.plan // "-" ' <<<"$license_status" 2>/dev/null || echo '-')"
          license_reason="$(jq -r '.reason // "-" ' <<<"$license_status" 2>/dev/null || echo '-')"
        else
          license_plan="$(sed -nE 's/.*"plan"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<<"$license_status" | head -n1)"
          license_reason="$(sed -nE 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<<"$license_status" | head -n1)"
          license_plan="${license_plan:--}"
          license_reason="${license_reason:--}"
        fi
        echo "Plan:         ${license_plan}"
        echo "Plan reason:  ${license_reason}"
      fi
    fi

    echo
    echo "Actions:"
    echo "  1) Refresh"
    echo "  2) Start service"
    echo "  3) Stop service"
    echo "  4) Restart service"
    echo "  5) Change license key"
    echo "  6) Check public IP now"
    echo "  7) Show logs (last 120 lines)"
    echo "  8) Show config"
    echo "  9) Edit config"
    echo "  q) Quit"
    read -r -p "Select action: " choice

    case "$choice" in
      1|'')
        ;;
      2)
        run_root systemctl start "$SERVICE_NAME"
        read -r -p "Service start requested. Press Enter to continue..." _
        ;;
      3)
        run_root systemctl stop "$SERVICE_NAME"
        read -r -p "Service stop requested. Press Enter to continue..." _
        ;;
      4)
        run_root systemctl restart "$SERVICE_NAME"
        read -r -p "Service restart requested. Press Enter to continue..." _
        ;;
      5)
        "$0" change-license
        read -r -p "Press Enter to continue..." _
        ;;
      6)
        show_public_ip
        read -r -p "Press Enter to continue..." _
        ;;
      7)
        journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
        read -r -p "Press Enter to continue..." _
        ;;
      8)
        cat "$CONFIG_PATH"
        read -r -p "Press Enter to continue..." _
        ;;
      9)
        local editor
        editor="${EDITOR:-nano}"
        run_root "$editor" "$CONFIG_PATH"
        ;;
      q|Q)
        exit 0
        ;;
      *)
        echo "Unknown option: $choice"
        sleep 1
        ;;
    esac
  done
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
  local cmd="${1:-dashboard}"
  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    dashboard)
      dashboard
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
    ip)
      show_public_ip
      ;;
    change-license|license)
      change_license_key "$@"
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
