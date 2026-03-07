#!/usr/bin/env bash
set -euo pipefail

# ─── Multi-instance Slipstream server setup ───
# Modes:
# 1) Legacy range mode:
#      --domain n00.example.com --instance-count 21
#      -> n00..n20.example.com
# 2) Multi-root-domain mode (same approach as slipstream-mux):
#      --root-domains d1.com,d2.com --subdomain-labels n01,n02,n03,n04
#      -> n01.d1.com,n01.d2.com,n02.d1.com,...

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
ROOT_DOMAINS=""
SUBDOMAIN_LABELS=""
DNS_PORT=53
SOCKS_PORT=1080
INSTALL_DIR="/opt/slipstream-rust"
CERT_DIR="/opt/slipstream-rust"
SERVICE_PREFIX="slipstream"
INSTANCE_COUNT=21
SUBDOMAINS_PER_DOMAIN=0
INTERNAL_DNS_PORT_BASE=10000
DNSDIST_CONF="/etc/dnsdist/dnsdist.conf"

port_in_use() {
    local p="$1"
    ss -H -lupn 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$" && return 0
    ss -H -ltpn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 0
    return 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

split_csv() {
    local input="$1"
    local -n out_ref="$2"
    out_ref=()
    IFS=',' read -r -a _tmp <<< "$input"
    for item in "${_tmp[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        out_ref+=("$item")
    done
}

usage() {
    cat <<EOF
Usage: $0 [--domain <tunnel-domain> | --root-domains <csv>] [OPTIONS]

Required (choose one mode):
  --domain DOMAIN             Legacy base tunnel domain (e.g. n00.e4h.ir)
  --root-domains CSV          Multi-domain roots (e.g. d1.ir,d2.ir,d3.ir)

Options:
  --subdomain-labels CSV      Labels for multi-domain mode (e.g. n01,n02,n03,n04)
  --subdomains-per-domain N   Use only first N labels from --subdomain-labels (default: 0 = all)
  --instance-count N          Legacy mode instance count (default: 21)
  --dns-port PORT             Public DNS listen port for dnsdist (default: 53)
                              Slipstream instances always use internal ports from 10000
  --socks-port PORT           Upstream SOCKS target port (default: 1080)
  --install-dir DIR           Install directory (default: /opt/slipstream-rust)
  --service-prefix PFX        Systemd service prefix (default: slipstream)
  --uninstall                 Remove everything
  -h, --help                  Show this help
EOF
    exit 0
}

cleanup_existing_install() {
    log "Cleaning up previous/partial ${SERVICE_PREFIX} installation..."

    mapfile -t units < <(find /etc/systemd/system -maxdepth 1 -type f -name "${SERVICE_PREFIX}-*.service" -printf '%f\n' 2>/dev/null || true)
    units+=("${SERVICE_PREFIX}.service")

    for unit in "${units[@]}"; do
        [[ -z "$unit" ]] && continue
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit"
    done

    systemctl reset-failed "${SERVICE_PREFIX}"*.service 2>/dev/null || true

    # Stop and clear front DNS router config so this run can recreate it cleanly.
    systemctl stop dnsdist 2>/dev/null || true
    rm -f "$DNSDIST_CONF"

    systemctl daemon-reload
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
    systemctl stop dnsdist 2>/dev/null || true
    systemctl disable dnsdist 2>/dev/null || true
    rm -f "$DNSDIST_CONF"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    log "Uninstalled."
    exit 0
}

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --root-domains) ROOT_DOMAINS="$2"; shift 2 ;;
        --subdomain-labels) SUBDOMAIN_LABELS="$2"; shift 2 ;;
        --subdomains-per-domain) SUBDOMAINS_PER_DOMAIN="$2"; shift 2 ;;
        --instance-count) INSTANCE_COUNT="$2"; shift 2 ;;
        --dns-port)    DNS_PORT="$2"; shift 2 ;;
        --socks-port)  SOCKS_PORT="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; CERT_DIR="$2"; shift 2 ;;
        --service-prefix) SERVICE_PREFIX="$2"; shift 2 ;;
        --uninstall)   uninstall ;;
        -h|--help)     usage ;;
        *)             err "Unknown option: $1" ;;
    esac
done

if [[ -n "$DOMAIN" && -n "$ROOT_DOMAINS" ]]; then
    err "Use either --domain (legacy mode) or --root-domains (multi-domain mode), not both."
fi
if [[ -z "$DOMAIN" && -z "$ROOT_DOMAINS" ]]; then
    err "Missing required mode. Use --domain or --root-domains."
fi
if [[ -n "$ROOT_DOMAINS" && -z "$SUBDOMAIN_LABELS" ]]; then
    err "--subdomain-labels is required when using --root-domains."
fi
[[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || err "--instance-count must be a non-negative integer."
[[ "$SUBDOMAINS_PER_DOMAIN" =~ ^[0-9]+$ ]] || err "--subdomains-per-domain must be a non-negative integer."
[[ $(id -u) -ne 0 ]] && err "Must run as root."

cleanup_existing_install

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
apt-get install -y -qq build-essential cmake pkg-config libssl-dev git python3 curl openssl dnsdist >/dev/null 2>&1
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

if [[ ! -f "${CERT_DIR}/reset-seed" ]]; then
    log "Generating reset-seed in ${CERT_DIR}/reset-seed..."
    openssl rand -hex 16 > "${CERT_DIR}/reset-seed"
    chmod 600 "${CERT_DIR}/reset-seed"
fi

declare -a TARGET_DOMAINS=()
declare -a ROOT_DOMAIN_LIST=()
declare -a SUBDOMAIN_LABEL_LIST=()
PARENT="(multiple)"

if [[ -n "$ROOT_DOMAINS" ]]; then
    split_csv "$ROOT_DOMAINS" ROOT_DOMAIN_LIST
    split_csv "$SUBDOMAIN_LABELS" SUBDOMAIN_LABEL_LIST
    [[ ${#ROOT_DOMAIN_LIST[@]} -gt 0 ]] || err "--root-domains is empty after parsing."
    [[ ${#SUBDOMAIN_LABEL_LIST[@]} -gt 0 ]] || err "--subdomain-labels is empty after parsing."

    if [[ "$SUBDOMAINS_PER_DOMAIN" =~ ^[0-9]+$ ]] && (( SUBDOMAINS_PER_DOMAIN > 0 )); then
        if (( SUBDOMAINS_PER_DOMAIN < ${#SUBDOMAIN_LABEL_LIST[@]} )); then
            SUBDOMAIN_LABEL_LIST=("${SUBDOMAIN_LABEL_LIST[@]:0:SUBDOMAINS_PER_DOMAIN}")
        fi
    fi

    for root in "${ROOT_DOMAIN_LIST[@]}"; do
        [[ "$root" == *.* ]] || err "Invalid root domain: ${root}"
    done
    for label in "${SUBDOMAIN_LABEL_LIST[@]}"; do
        [[ "$label" == *.* ]] && err "Invalid subdomain label '${label}' (must not contain dots)"
    done

    # Interleaved order (label-major) to match slipstream-mux approach.
    for label in "${SUBDOMAIN_LABEL_LIST[@]}"; do
        for root in "${ROOT_DOMAIN_LIST[@]}"; do
            TARGET_DOMAINS+=("${label}.${root}")
        done
    done
else
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

    for ((i=0; i<INSTANCE_COUNT; i++)); do
        index=$((START_NUM + i))
        numbered_label="$(printf "%s%0*d" "$LABEL_PREFIX" "$WIDTH" "$index")"
        TARGET_DOMAINS+=("${numbered_label}.${PARENT}")
    done
fi

[[ ${#TARGET_DOMAINS[@]} -gt 0 ]] || err "No domains generated."

CERT_CN="${TARGET_DOMAINS[0]}"
if [[ ! -f "${CERT_DIR}/cert.pem" || ! -f "${CERT_DIR}/key.pem" ]]; then
    log "Generating self-signed TLS cert/key in ${CERT_DIR} (CN=${CERT_CN})..."
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${CERT_DIR}/key.pem" \
      -out "${CERT_DIR}/cert.pem" \
      -days 3650 \
      -subj "/CN=${CERT_CN}" >/dev/null 2>&1
fi

declare -a CREATED_UNITS=()
declare -a CREATED_DOMAINS=()
declare -a CREATED_PORTS=()
next_dns_port="$INTERNAL_DNS_PORT_BASE"
for ((i=0; i<${#TARGET_DOMAINS[@]}; i++)); do
    domain_i="${TARGET_DOMAINS[$i]}"
    while port_in_use "$next_dns_port"; do
        warn "DNS port ${next_dns_port} is already in use. Skipping."
        next_dns_port=$((next_dns_port + 1))
    done
    dns_port_i="$next_dns_port"
    next_dns_port=$((next_dns_port + 1))
    unit="$(printf "%s-%03d.service" "$SERVICE_PREFIX" "$i")"
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
    CREATED_PORTS+=("$dns_port_i")
done

log "Writing dnsdist routing config on port ${DNS_PORT}..."
cat > "$DNSDIST_CONF" <<EOF
setLocal("0.0.0.0:${DNS_PORT}")
setACL({"0.0.0.0/0", "::/0"})
setConsoleACL({"127.0.0.1/8", "::1/128"})
EOF

for ((i=0; i<${#CREATED_DOMAINS[@]}; i++)); do
    domain_i="${CREATED_DOMAINS[$i]}"
    port_i="${CREATED_PORTS[$i]}"
    pool_i="${SERVICE_PREFIX}${i}"
    cat >> "$DNSDIST_CONF" <<EOF
newServer({address="127.0.0.1:${port_i}", pool="${pool_i}"})
smn${i}=newSuffixMatchNode()
smn${i}:add(newDNSName("${domain_i}."))
addAction(SuffixMatchNodeRule(smn${i}), PoolAction("${pool_i}"))
EOF
done

cat >> "$DNSDIST_CONF" <<'EOF'
# Return NXDOMAIN for anything not mapped to a Slipstream suffix.
# REFUSED here causes recursive resolvers to surface SERVFAIL/EDE
# ("No Reachable Authority") for delegated labels.
addAction(AllRule(), RCodeAction(DNSRCode.NXDOMAIN))
EOF

systemctl daemon-reload
for unit in "${CREATED_UNITS[@]}"; do
    systemctl enable "$unit" >/dev/null 2>&1
    systemctl restart "$unit"
done
systemctl enable dnsdist >/dev/null 2>&1
systemctl restart dnsdist
sleep 2

for unit in "${CREATED_UNITS[@]}"; do
    if ! systemctl is-active --quiet "$unit"; then
        err "$unit failed to start. Check: journalctl -u $unit --no-pager -n 40"
    fi
done
if ! systemctl is-active --quiet dnsdist; then
    err "dnsdist failed to start. Check: journalctl -u dnsdist --no-pager -n 80"
fi

# ─── Print summary ───
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Slipstream Multi-Service Setup Complete${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Server IP:     ${YELLOW}${SERVER_IP}${NC}"
echo -e "  Domain range:  ${YELLOW}${CREATED_DOMAINS[0]}${NC} .. ${YELLOW}${CREATED_DOMAINS[-1]}${NC}"
if [[ -n "$ROOT_DOMAINS" ]]; then
    ROOTS_PRINT=$(IFS=,; echo "${ROOT_DOMAIN_LIST[*]}")
    echo -e "  Root domains:  ${YELLOW}${ROOTS_PRINT}${NC}"
    echo -e "  Labels used:   ${YELLOW}$(IFS=,; echo "${SUBDOMAIN_LABEL_LIST[*]}")${NC}"
else
    echo -e "  Parent zone:   ${YELLOW}${PARENT}${NC}"
fi
echo -e "  Public DNS:    0.0.0.0:${DNS_PORT} (dnsdist)"
echo -e "  Internal DNS:  ${CREATED_PORTS[0]}..${CREATED_PORTS[-1]} (used: ${#CREATED_PORTS[@]})"
echo -e "  SOCKS target:  127.0.0.1:${SOCKS_PORT}"
echo -e "  Slipstream:    ${YELLOW}${COMMIT_HASH}${NC} - ${COMMIT_MSG} (${COMMIT_DATE})"
echo ""
echo -e "${YELLOW}  Client usage:${NC}"
echo -e "  slipstream-client --tcp-listen-port 7000 --domain ${CREATED_DOMAINS[0]}"
echo -e "  Then: curl -x socks5h://127.0.0.1:7000 http://ifconfig.me"
echo ""
echo -e "${YELLOW}  Management:${NC}"
echo -e "  systemctl status ${SERVICE_PREFIX}-*"
echo -e "  systemctl status dnsdist"
echo -e "  journalctl -fu ${CREATED_UNITS[0]}  # example"
echo -e "  journalctl -fu dnsdist"
echo -e "  bash /var/www/slip-server.sh --uninstall    # remove everything"
echo ""
