#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="bifrost-gate.service"
CONFIG_PATH="/etc/bifrost/config.json"
INSTALL_DIR="/opt/bifrost"
BINARY_PATH="$INSTALL_DIR/bifrost-gate"
DEFAULT_PUBLIC_IP="185.239.2.22"
DEFAULT_RAW_BASE_URL="https://raw.githubusercontent.com/ItzGlace/bifrost-gate/main"
DEFAULT_UPDATE_VERSION="v1.0-released"

PUBLIC_IP_ENDPOINT=""
PUBLIC_IP_VALUE=""
PUBLIC_IP_PAYLOAD=""

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
  update          Download and install latest binary for this architecture
  uninstall       Remove service, binaries, manager, and config
  help            Show this help
USAGE
}

ensure_service_exists() {
  local load_state
  load_state="$(systemctl show "$SERVICE_NAME" -p LoadState --value 2>/dev/null || true)"

  if [[ -n "$load_state" && "$load_state" != "not-found" ]]; then
    return 0
  fi

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    return 0
  fi

  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    return 0
  fi

  if systemctl list-units --all --no-legend 2>/dev/null | awk '{print $1}' | grep -q "^${SERVICE_NAME}$"; then
    return 0
  fi

  if [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]] || [[ -f "/lib/systemd/system/${SERVICE_NAME}" ]]; then
    return 0
  fi

  if [[ -f "$CONFIG_PATH" || -x "$BINARY_PATH" ]]; then
    return 0
  fi

  if [[ "${1:-}" == "--soft" ]]; then
    return 1
  fi

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
    *)
      ;;
  esac
}

local_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip:-$DEFAULT_PUBLIC_IP}"
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

normalize_arch_to_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "bifrost-gate-linux-amd64"
      ;;
    aarch64|arm64)
      echo "bifrost-gate-linux-arm64"
      ;;
    armv7l|armv7|armhf)
      echo "bifrost-gate-linux-armv7"
      ;;
    *)
      echo ""
      ;;
  esac
}

fetch_url() {
  local endpoint="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 8 --connect-timeout 4 "$endpoint" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=8 "$endpoint" 2>/dev/null || true
  fi
}

extract_public_ip() {
  local payload="$1"
  payload="$(printf '%s' "$payload" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$payload" ]] || return 0

  if [[ "$payload" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "$payload"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local from_jq
    from_jq="$(jq -r '.ip // .remote_ip // .address // .data.ip // .query // .origin // empty' <<<"$payload" 2>/dev/null || true)"
    from_jq="$(printf '%s' "$from_jq" | cut -d',' -f1 | xargs)"
    if [[ -n "$from_jq" ]]; then
      echo "$from_jq"
      return 0
    fi
  fi

  local from_sed
  from_sed="$(sed -nE 's/.*"(ip|remote_ip|address|query|origin)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' <<<"$payload" | head -n1 | cut -d',' -f1 | xargs)"
  if [[ -n "$from_sed" ]]; then
    echo "$from_sed"
    return 0
  fi

  grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$payload" | head -n1
}

detect_public_ip() {
  PUBLIC_IP_ENDPOINT=""
  PUBLIC_IP_VALUE=""
  PUBLIC_IP_PAYLOAD=""

  local endpoint payload ip
  local endpoints=(
    "https://view.iranmonitor.net/api/v1.0/network/ip"
    "https://api.ipify.org?format=json"
    "https://ifconfig.co/json"
    "https://ipinfo.io/json"
    "https://ifconfig.me/ip"
  )

  for endpoint in "${endpoints[@]}"; do
    payload="$(fetch_url "$endpoint")"
    if [[ -z "$payload" ]]; then
      continue
    fi
    ip="$(extract_public_ip "$payload")"
    if [[ -n "$ip" ]]; then
      PUBLIC_IP_ENDPOINT="$endpoint"
      PUBLIC_IP_VALUE="$ip"
      PUBLIC_IP_PAYLOAD="$payload"
      return 0
    fi
    PUBLIC_IP_PAYLOAD="$payload"
  done

  return 1
}

show_public_ip() {
  if detect_public_ip; then
    echo "Endpoint: ${PUBLIC_IP_ENDPOINT}"
    echo "Detected IP: ${PUBLIC_IP_VALUE}"
    return 0
  fi

  if [[ -n "$PUBLIC_IP_PAYLOAD" ]]; then
    echo "Endpoint: unavailable"
    echo "Raw response: ${PUBLIC_IP_PAYLOAD}"
  else
    echo "Failed to query public IP endpoint."
  fi
}

extract_binary_from_zip() {
  local zip_path="$1"
  local asset_name="$2"
  local output_path="$3"

  if ! command -v unzip >/dev/null 2>&1; then
    echo "update requires 'unzip' command"
    return 1
  fi

  if unzip -p "$zip_path" "$asset_name" >"$output_path" 2>/dev/null; then
    return 0
  fi

  local zip_entry
  zip_entry="$(unzip -Z1 "$zip_path" | awk 'NF {print; exit}')"
  [[ -n "$zip_entry" ]] || return 1
  unzip -p "$zip_path" "$zip_entry" >"$output_path"
}

update_binary() {
  require_root "$@"

  local asset_name
  asset_name="${BIFROST_ASSET_NAME:-$(normalize_arch_to_asset)}"
  if [[ -z "$asset_name" ]]; then
    echo "Unsupported architecture: $(uname -m)"
    exit 1
  fi

  local raw_base update_version
  raw_base="${BIFROST_RAW_BASE_URL:-$DEFAULT_RAW_BASE_URL}"
  update_version="${BIFROST_UPDATE_VERSION:-$DEFAULT_UPDATE_VERSION}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local downloaded="$tmp_dir/download"
  local selected_url=""
  local url

  if [[ -n "${BIFROST_UPDATE_URL:-}" ]]; then
    local explicit_url
    explicit_url="${BIFROST_UPDATE_URL}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$explicit_url" -o "$downloaded" && selected_url="$explicit_url" || true
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$downloaded" "$explicit_url" && selected_url="$explicit_url" || true
    fi
  fi

  if [[ -z "$selected_url" ]]; then
    for url in \
      "${raw_base%/}/${update_version}/${asset_name}.zip" \
      "${raw_base%/}/${asset_name}.zip" \
      "${raw_base%/}/${update_version}/${asset_name}" \
      "${raw_base%/}/${asset_name}"; do
      if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$url" -o "$downloaded"; then
          selected_url="$url"
          break
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -qO "$downloaded" "$url"; then
          selected_url="$url"
          break
        fi
      fi
    done
  fi

  if [[ -z "$selected_url" ]]; then
    rm -rf "$tmp_dir"
    echo "Failed to download update binary"
    exit 1
  fi

  local new_binary="$tmp_dir/${asset_name}"
  if [[ "$selected_url" == *.zip ]]; then
    extract_binary_from_zip "$downloaded" "$asset_name" "$new_binary" || {
      rm -rf "$tmp_dir"
      echo "Failed to extract updated binary from zip"
      exit 1
    }
  else
    cp "$downloaded" "$new_binary"
  fi

  if [[ ! -s "$new_binary" ]]; then
    rm -rf "$tmp_dir"
    echo "Downloaded update binary is empty"
    exit 1
  fi

  chmod 755 "$new_binary"
  install -d -m 755 "$INSTALL_DIR"

  local backup_path=""
  if [[ -x "$BINARY_PATH" ]]; then
    backup_path="${BINARY_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$BINARY_PATH" "$backup_path" || true
  fi

  install -m 755 "$new_binary" "$BINARY_PATH"

  if ensure_service_exists --soft; then
    systemctl daemon-reload || true
    systemctl restart "$SERVICE_NAME" || {
      echo "Service restart failed after update"
      [[ -n "$backup_path" && -f "$backup_path" ]] && cp "$backup_path" "$BINARY_PATH" || true
      rm -rf "$tmp_dir"
      exit 1
    }
  fi

  # Best-effort manager refresh.
  local manager_tmp="$tmp_dir/bifrost-manager.sh"
  for url in \
    "${raw_base%/}/${update_version}/bifrost-manager.sh" \
    "${raw_base%/}/bifrost-manager.sh"; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL "$url" -o "$manager_tmp"; then
        install -m 755 "$manager_tmp" /usr/local/bin/bifrost
        break
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO "$manager_tmp" "$url"; then
        install -m 755 "$manager_tmp" /usr/local/bin/bifrost
        break
      fi
    fi
  done

  rm -rf "$tmp_dir"
  echo "Updated binary from: ${selected_url}"
  if [[ -n "$backup_path" ]]; then
    echo "Backup saved as: ${backup_path}"
  fi
  systemctl status "$SERVICE_NAME" --no-pager || true
}

dashboard() {
  ensure_service_exists

  while true; do
    local active enabled pid started host port api_key local_ip_val
    active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
    started="$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
    host="$(extract_json_value '.admin.host')"
    port="$(extract_json_value '.admin.port')"
    api_key="$(extract_json_value '.api_key')"
    local_ip_val="$(local_ip)"

    detect_public_ip || true

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
    echo "Panel URL:    http://${local_ip_val}:${port:-11001}/login"
    echo "Admin API:    http://${local_ip_val}:${port:-11001}/api/listeners"
    echo "Bind host:    ${host:-0.0.0.0}:${port:-11001}"
    echo "Public IP:    ${PUBLIC_IP_VALUE:-unavailable}"

    if [[ -n "$api_key" ]]; then
      local api_host license_status license_plan license_reason
      api_host="${host:-$DEFAULT_PUBLIC_IP}"
      if [[ "$api_host" == "0.0.0.0" || "$api_host" == "::" ]]; then
        api_host="$DEFAULT_PUBLIC_IP"
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
    echo "  5) Update binary"
    echo "  6) Check public IP now"
    echo "  7) Show logs (last 120 lines)"
    echo "  8) Show config"
    echo "  9) Edit config"
    echo " 10) Uninstall"
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
        "$0" update
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
      10)
        "$0" uninstall
        read -r -p "Press Enter to continue..." _
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
    update)
      update_binary "$@"
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
