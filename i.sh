#!/usr/bin/env bash
set -euo pipefail

# ─── Multi-instance Slipstream server setup ───
# Creates 21 services from a base domain label:
#   n00.e4h.ir -> n00..n20.e4h.ir
#   a.r4h.ir   -> a00..a20.r4h.ir

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ─── Pinned commit ───
PINNED_COMMIT="bc772dd07d9a136dbd7553b0da575526de207847"

# ─── Defaults ───
DOMAIN=""
DNS_PORT=53
SOCKS_PORT=1080
INSTALL_DIR="/opt/slipstream-rust"
CERT_DIR="/opt/slipstream-rust"
SERVICE_PREFIX="slipstream"
INSTANCE_COUNT=21

usage() {
    cat <<EOF
Usage: $0 --domain <tunnel-domain> [OPTIONS]

Required:
  --domain DOMAIN       Base tunnel domain (e.g. n00.e4h.ir or a.r4h.ir)

Options:
  --dns-port PORT       Starting DNS listen port (default: 53)
                        Services use PORT..PORT+20
  --socks-port PORT     Upstream SOCKS target port (default: 1080)
  --install-dir DIR     Install directory (default: /opt/slipstream-rust)
  --service-prefix PFX  Systemd service prefix (default: slipstream)
  --uninstall           Remove everything
  -h, --help            Show this help
EOF
    exit 0
}

uninstall() {
    log "Uninstalling ${SERVICE_PREFIX} services..."
    mapfile -t units < <(find /etc/systemd/system -maxdepth 1 -type f -name "${SERVICE_PREFIX}-*.service" -printf '%f\n' 2>/dev/null || true)
    units+=("${SERVICE_PREFIX}.service")
    for unit in "${units[@]}"; do
        [[ -z "$unit" ]] && continue
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit"
    done
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    log "Uninstalled."
    exit 0
}

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --dns-port)    DNS_PORT="$2"; shift 2 ;;
        --socks-port)  SOCKS_PORT="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; CERT_DIR="$2"; shift 2 ;;
        --service-prefix) SERVICE_PREFIX="$2"; shift 2 ;;
        --uninstall)   uninstall ;;
        -h|--help)     usage ;;
        *)             err "Unknown option: $1" ;;
    esac
done

[[ -z "$DOMAIN" ]] && err "Missing required --domain. Run with --help for usage."
[[ $(id -u) -ne 0 ]] && err "Must run as root."

# ─── Check OS ───
if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Proceed at your own risk."
fi

# ─── Stop conflicting services on port 53 ───
if systemctl is-active --quiet systemd-resolved 2>/dev/null && [[ "$DNS_PORT" -eq 53 ]]; then
    log "Stopping systemd-resolved to free DNS port 53..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    if [[ ! -f /etc/resolv.conf.bak ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    fi
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
fi

# ─── Install system dependencies ───
log "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential cmake pkg-config libssl-dev git python3 curl openssl >/dev/null 2>&1
log "System packages installed."

# ─── Install Rust ───
if ! command -v cargo &>/dev/null; then
    log "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
    source "$HOME/.cargo/env"
    log "Rust installed."
else
    source "$HOME/.cargo/env" 2>/dev/null || true
    log "Rust already installed."
fi

# ─── Clone and build slipstream ───
if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Existing install found at $INSTALL_DIR"
    cd "$INSTALL_DIR"
else
    log "Cloning slipstream-rust..."
    rm -rf "$INSTALL_DIR"
    git clone --quiet https://github.com/Mygod/slipstream-rust.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

log "Checking out pinned commit ${PINNED_COMMIT:0:12}..."
git fetch --quiet origin
git checkout --quiet "$PINNED_COMMIT"
git submodule update --init --recursive --quiet

COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=format:"%s")
COMMIT_DATE=$(git log -1 --pretty=format:"%ci")
log "Slipstream commit: ${COMMIT_HASH} - ${COMMIT_MSG} (${COMMIT_DATE})"

log "Building slipstream-server (this may take a few minutes)..."
cargo build --release -p slipstream-server --quiet 2>&1
log "Build complete."

if [[ ! -f "${CERT_DIR}/cert.pem" || ! -f "${CERT_DIR}/key.pem" ]]; then
    log "Generating self-signed TLS cert/key in ${CERT_DIR}..."
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${CERT_DIR}/key.pem" \
      -out "${CERT_DIR}/cert.pem" \
      -days 3650 \
      -subj "/CN=${DOMAIN}" >/dev/null 2>&1
fi

if [[ ! -f "${CERT_DIR}/reset-seed" ]]; then
    log "Generating reset-seed in ${CERT_DIR}/reset-seed..."
    openssl rand -hex 16 > "${CERT_DIR}/reset-seed"
    chmod 600 "${CERT_DIR}/reset-seed"
fi

FIRST_LABEL="${DOMAIN%%.*}"
PARENT="${DOMAIN#*.}"
[[ "$PARENT" != "$DOMAIN" ]] || err "--domain must contain at least one dot."

LABEL_PREFIX=""
START_NUM=0
WIDTH=2
if [[ "$FIRST_LABEL" =~ ^([[:alpha:]_-]*)([0-9]+)$ ]]; then
    LABEL_PREFIX="${BASH_REMATCH[1]}"
    START_NUM=$((10#${BASH_REMATCH[2]}))
    WIDTH=${#BASH_REMATCH[2]}
else
    LABEL_PREFIX="$FIRST_LABEL"
fi

declare -a CREATED_UNITS=()
declare -a CREATED_DOMAINS=()
for ((i=0; i<INSTANCE_COUNT; i++)); do
    index=$((START_NUM + i))
    numbered_label="$(printf "%s%0*d" "$LABEL_PREFIX" "$WIDTH" "$index")"
    domain_i="${numbered_label}.${PARENT}"
    dns_port_i=$((DNS_PORT + i))
    unit="${SERVICE_PREFIX}-${numbered_label}.service"
    unit_path="/etc/systemd/system/${unit}"

    cat > "$unit_path" <<EOF
[Unit]
Description=Slipstream DNS Tunnel Server (${domain_i})
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/target/release/slipstream-server \\
    --dns-listen-port ${dns_port_i} \\
    --target-address 127.0.0.1:${SOCKS_PORT} \\
    --domain ${domain_i} \\
    --cert ${CERT_DIR}/cert.pem \\
    --key ${CERT_DIR}/key.pem \\
    --reset-seed ${CERT_DIR}/reset-seed
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    CREATED_UNITS+=("$unit")
    CREATED_DOMAINS+=("$domain_i")
done

systemctl daemon-reload
for unit in "${CREATED_UNITS[@]}"; do
    systemctl enable "$unit" >/dev/null 2>&1
    systemctl restart "$unit"
done
sleep 2

for unit in "${CREATED_UNITS[@]}"; do
    if ! systemctl is-active --quiet "$unit"; then
        err "$unit failed to start. Check: journalctl -u $unit --no-pager -n 40"
    fi
done

# ─── Print summary ───
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Slipstream Multi-Service Setup Complete${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Server IP:     ${YELLOW}${SERVER_IP}${NC}"
echo -e "  Domain range:  ${YELLOW}${CREATED_DOMAINS[0]}${NC} .. ${YELLOW}${CREATED_DOMAINS[-1]}${NC}"
echo -e "  Parent zone:   ${YELLOW}${PARENT}${NC}"
echo -e "  DNS ports:     ${DNS_PORT}..$((DNS_PORT + INSTANCE_COUNT - 1))"
echo -e "  SOCKS target:  127.0.0.1:${SOCKS_PORT}"
echo -e "  Slipstream:    ${YELLOW}${COMMIT_HASH}${NC} - ${COMMIT_MSG} (${COMMIT_DATE})"
echo ""
echo -e "${YELLOW}  Client usage:${NC}"
echo -e "  slipstream-client --tcp-listen-port 7000 --domain ${FIRST_LABEL}.${PARENT}"
echo -e "  Then: curl -x socks5h://127.0.0.1:7000 http://ifconfig.me"
echo ""
echo -e "${YELLOW}  Management:${NC}"
echo -e "  systemctl status ${SERVICE_PREFIX}-*"
echo -e "  journalctl -fu ${CREATED_UNITS[0]}  # example"
echo -e "  bash install.sh --uninstall    # remove everything"
echo ""
