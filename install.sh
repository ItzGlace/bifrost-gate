#!/usr/bin/env bash
set -euo pipefail

APP_NAME="bifrost-gate"
SERVICE_NAME="bifrost-gate.service"
INSTALL_DIR="/opt/bifrost"
BINARY_PATH="$INSTALL_DIR/bifrost-gate"
CONFIG_DIR="/etc/bifrost"
CONFIG_PATH="$CONFIG_DIR/config.json"
MANAGER_PATH="/usr/local/bin/bifrost"
SCRIPT_SOURCE="${BASH_SOURCE[0]-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  printf '[install] %s\n' "$*"
}

fail() {
  printf '[install] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "run as root (example: sudo bash install.sh)"
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  echo unknown
}

install_packages() {
  local pm="$1"
  shift
  local pkgs=("$@")
  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_cmd() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  local pm
  pm="$(detect_pkg_manager)"
  if [[ "$pm" == "unknown" ]]; then
    fail "missing '$cmd' and no supported package manager found"
  fi
  log "installing dependency: $pkg"
  install_packages "$pm" "$pkg" || fail "failed installing $pkg"
  command -v "$cmd" >/dev/null 2>&1 || fail "dependency '$cmd' still missing"
}

generate_hex() {
  local len="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$((len / 2))"
    return
  fi
  tr -dc 'a-f0-9' </dev/urandom | head -c "$len"
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
      fail "unsupported architecture '$arch'. supported: amd64, arm64, armv7"
      ;;
  esac
}

download_binary() {
  local asset_name="$1"
  local output_path="$2"

  if [[ -f "$SCRIPT_DIR/$asset_name" ]]; then
    log "using local asset: $SCRIPT_DIR/$asset_name"
    cp "$SCRIPT_DIR/$asset_name" "$output_path"
    return
  fi

  if [[ -f "$SCRIPT_DIR/${asset_name}.zip" ]]; then
    log "using local asset archive: $SCRIPT_DIR/${asset_name}.zip"
    extract_binary_from_zip "$SCRIPT_DIR/${asset_name}.zip" "$asset_name" "$output_path"
    return
  fi

  local url="${BIFROST_DOWNLOAD_URL:-}"

  if [[ -z "$url" ]]; then
    local raw_base="${BIFROST_RAW_BASE_URL:-https://raw.githubusercontent.com/ItzGlace/bifrost-gate/main}"
    url="${raw_base%/}/${asset_name}.zip"
  fi

  local downloaded="$TMP_DIR/${asset_name}.download"
  if [[ "$url" == *.zip ]]; then
    downloaded="$TMP_DIR/${asset_name}.zip"
  fi

  log "downloading binary: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$downloaded" || fail "download failed from $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$downloaded" "$url" || fail "download failed from $url"
  else
    fail "curl or wget is required"
  fi

  if [[ "$url" == *.zip ]]; then
    extract_binary_from_zip "$downloaded" "$asset_name" "$output_path"
  else
    cp "$downloaded" "$output_path"
  fi
}

extract_binary_from_zip() {
  local zip_path="$1"
  local asset_name="$2"
  local output_path="$3"

  ensure_cmd unzip unzip

  if unzip -p "$zip_path" "$asset_name" >"$output_path" 2>/dev/null; then
    return
  fi

  local zip_entry
  zip_entry="$(unzip -Z1 "$zip_path" | awk 'NF {print; exit}')"
  [[ -n "$zip_entry" ]] || fail "zip archive is empty: $zip_path"

  unzip -p "$zip_path" "$zip_entry" >"$output_path" || fail "failed to extract binary from $zip_path"
}

download_manager_script() {
  local manager_name="${BIFROST_MANAGER_NAME:-bifrost-manager.sh}"
  local manager_url="${BIFROST_MANAGER_URL:-}"
  local manager_tmp="$TMP_DIR/${manager_name##*/}"

  if [[ -f "$SCRIPT_DIR/$manager_name" ]]; then
    log "using local manager script: $SCRIPT_DIR/$manager_name"
    install -m 755 "$SCRIPT_DIR/$manager_name" "$MANAGER_PATH"
    return
  fi

  if [[ -z "$manager_url" ]]; then
    local raw_base="${BIFROST_RAW_BASE_URL:-https://raw.githubusercontent.com/ItzGlace/bifrost-gate/main}"
    manager_url="${raw_base%/}/${manager_name}"
  fi

  log "downloading manager script: $manager_url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$manager_url" -o "$manager_tmp" || fail "manager download failed from $manager_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$manager_tmp" "$manager_url" || fail "manager download failed from $manager_url"
  else
    fail "curl or wget is required"
  fi

  chmod 755 "$manager_tmp"
  install -m 755 "$manager_tmp" "$MANAGER_PATH"
}

main() {
  require_root

  [[ "$(uname -s)" == "Linux" ]] || fail "Linux only"
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required"

  ensure_cmd sed sed
  ensure_cmd awk gawk
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    local pm
    pm="$(detect_pkg_manager)"
    [[ "$pm" != "unknown" ]] || fail "curl or wget required"
    case "$pm" in
      apt) install_packages "$pm" curl ca-certificates ;;
      dnf|yum|zypper) install_packages "$pm" curl ca-certificates ;;
      pacman) install_packages "$pm" curl ca-certificates ;;
      apk) install_packages "$pm" curl ca-certificates ;;
    esac
  fi

  local asset_name
  asset_name="${BIFROST_ASSET_NAME:-$(normalize_arch_to_asset)}"

  local panel_user panel_pass panel_pass2 license_key required_host rewrite_host admin_port license_timeout
  read -r -p "Panel username [admin]: " panel_user
  panel_user="${panel_user:-admin}"

  while true; do
    read -r -s -p "Panel password: " panel_pass
    echo
    read -r -s -p "Confirm panel password: " panel_pass2
    echo
    [[ -n "$panel_pass" ]] || { echo "Password cannot be empty"; continue; }
    [[ "$panel_pass" == "$panel_pass2" ]] || { echo "Passwords do not match"; continue; }
    break
  done

  read -r -p "License key [optional, empty = free demo plan]: " license_key
  license_key="${license_key:-}"

  read -r -p "Required host [bifrost.gate]: " required_host
  required_host="${required_host:-bifrost.gate}"

  read -r -p "Rewrite host [${required_host}]: " rewrite_host
  rewrite_host="${rewrite_host:-$required_host}"

  read -r -p "Admin panel/API port [11001]: " admin_port
  admin_port="${admin_port:-11001}"
  [[ "$admin_port" =~ ^[0-9]+$ ]] || fail "admin port must be numeric"
  (( admin_port >= 1 && admin_port <= 65535 )) || fail "admin port out of range"

  read -r -p "License timeout seconds [10]: " license_timeout
  license_timeout="${license_timeout:-10}"
  [[ "$license_timeout" =~ ^[0-9]+$ ]] || fail "timeout must be numeric"

  local api_key machine_id
  api_key="$(generate_hex 48)"
  machine_id="$(hostname)-$(uname -m)"

  install -d -m 755 "$INSTALL_DIR"
  install -d -m 755 "$CONFIG_DIR"

  local downloaded="$TMP_DIR/$asset_name"
  download_binary "$asset_name" "$downloaded"
  install -m 755 "$downloaded" "$BINARY_PATH"

  download_manager_script

  if [[ -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "$CONFIG_PATH.bak.$(date +%s)"
  fi

  cat > "$CONFIG_PATH" <<JSON
{
  "api_key": "$api_key",
  "required_host": "$required_host",
  "rewrite_host_to": "$rewrite_host",
  "admin": {
    "host": "0.0.0.0",
    "port": $admin_port
  },
  "license": {
    "license_key": "$license_key",
    "machine_id": "$machine_id",
    "timeout_seconds": $license_timeout
  },
  "panel": {
    "username": "$panel_user",
    "password": "$panel_pass"
  },
  "listeners": []
}
JSON

  chmod 600 "$CONFIG_PATH"

  cat > "/etc/systemd/system/$SERVICE_NAME" <<SERVICE
[Unit]
Description=Bifrost Gate Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PORT_FORWARDER_CONFIG=$CONFIG_PATH
ExecStart=$BINARY_PATH
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=$CONFIG_DIR

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip="${ip:-127.0.0.1}"

  log "install complete"
  log "service: $SERVICE_NAME"
  log "binary:  $BINARY_PATH"
  log "config:  $CONFIG_PATH"
  log "manager: bifrost"
  log "panel:   http://${ip}:${admin_port}/login"
  log "api key: $api_key"

  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

main "$@"
