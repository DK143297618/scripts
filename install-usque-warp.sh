#!/usr/bin/env bash
# install-usque-warp.sh — One-click Cloudflare WARP via usque (MASQUE nativetun + IPv6 egress)
# https://github.com/Diniboy1123/usque
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DK143297618/scripts/main/install-usque-warp.sh | bash
#   curl ... | bash -s -- -6 2001:db8::/48          # specific IPv6 prefix
#   curl ... | bash -s -- -6 default -t 100          # policy routing (table 100)
#   curl ... | bash -s -- -u                          # uninstall
set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
USQUE_VERSION="v4.2.1"
INSTALL_DIR="/opt/usque"
SERVICE_NAME="usque"
TUN_IF="warp0"
IPV6_ROUTE="default"
IPV6_ROUTE_TABLE=""
BIN="${INSTALL_DIR}/usque"
CONFIG="${INSTALL_DIR}/config.json"
ON_CONNECT="${INSTALL_DIR}/on-connect.sh"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

# ─── Functions ────────────────────────────────────────────────────────────────
do_uninstall() {
    info "Stopping and removing usque..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    ip link del "${TUN_IF}" 2>/dev/null || true
    rm -rf "${INSTALL_DIR}"
    systemctl daemon-reload
    info "usque removed ✓"
}

download_usque() {
    mkdir -p "${INSTALL_DIR}"
    if [[ -x "${BIN}" ]]; then
        local cur
        cur=$("${BIN}" version 2>&1 | grep -oP 'usque version: \K\S+' || echo "unknown")
        if [[ "$cur" == *"${USQUE_VERSION#v}"* ]]; then
            info "usque ${cur} already installed"
            return 0
        fi
        info "Upgrading ${cur} → ${USQUE_VERSION}..."
    else
        info "Downloading usque ${USQUE_VERSION}..."
    fi

    local tmpzip="/tmp/usque-${USQUE_VERSION}.zip"
    local url="https://github.com/Diniboy1123/usque/releases/download/${USQUE_VERSION}/usque_${USQUE_VERSION#v}_linux_amd64.zip"
    curl -fSL -o "${tmpzip}" "${url}"
    unzip -qo "${tmpzip}" -d /tmp/usque-extract/
    mv /tmp/usque-extract/usque "${BIN}"
    chmod +x "${BIN}"
    rm -rf /tmp/usque-extract/ "${tmpzip}"
    info "Installed: $("${BIN}" version 2>&1 | head -1)"
}

register_account() {
    if [[ -f "${CONFIG}" ]]; then
        info "Config exists — checking account..."
        "${BIN}" account 2>&1 | head -5 || true
        return 0
    fi
    info "Registering new WARP account..."
    cd "${INSTALL_DIR}"
    "${BIN}" register
    [[ -f "${INSTALL_DIR}/config.json" ]] || fail "Registration failed — no config.json"
    mv "${INSTALL_DIR}/config.json" "${CONFIG}" 2>/dev/null || true
    info "Account registered ✓"
}

write_on_connect() {
    cat > "${ON_CONNECT}" << OCEOF
#!/bin/sh
# Auto-added by install-usque-warp.sh — IPv6 route via WARP tun
IFACE="${TUN_IF}"
ROUTE="${IPV6_ROUTE}"
TABLE="${IPV6_ROUTE_TABLE}"

i=0
while [ "\$i" -lt 10 ]; do
    if ip link show "\$IFACE" >/dev/null 2>&1; then
        if [ -n "\$TABLE" ]; then
            ip -6 route replace "\$ROUTE" dev "\$IFACE" table "\$TABLE" 2>/dev/null
            ip -6 rule add from all fwmark 0x1000 table "\$TABLE" 2>/dev/null || true
            ip -6 rule show | grep -q "lookup \$TABLE" || \
                ip -6 rule add lookup "\$TABLE" priority 100 2>/dev/null || true
        else
            ip -6 route replace "\$ROUTE" dev "\$IFACE" 2>/dev/null
        fi
        exit 0
    fi
    i=\$((i+1))
    sleep 1
done
exit 0
OCEOF
    chmod +x "${ON_CONNECT}"
}

write_service() {
    cat > /etc/systemd/system/${SERVICE_NAME}.service << SVCEOF
[Unit]
Description=usque Cloudflare WARP MASQUE native tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN} nativetun -c ${CONFIG} -n ${TUN_IF} --on-connect ${ON_CONNECT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
}

start_and_verify() {
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        info "Restarting usque..."
        systemctl restart "${SERVICE_NAME}"
    else
        info "Starting usque..."
        systemctl start "${SERVICE_NAME}"
    fi
    sleep 3

    if ip link show "${TUN_IF}" &>/dev/null; then
        info "TUN ${TUN_IF} is UP ✓"
    else
        warn "TUN not up yet — check: journalctl -u ${SERVICE_NAME} -f"
    fi

    if [[ -n "${IPV6_ROUTE_TABLE}" ]]; then
        info "IPv6 policy routing: ${IPV6_ROUTE} via table ${IPV6_ROUTE_TABLE}"
    else
        info "IPv6 route: ${IPV6_ROUTE} via ${TUN_IF} (main table)"
    fi

    info "Testing IPv6 egress..."
    local ip6
    ip6=$(curl -6 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
    if [[ -n "${ip6}" ]]; then
        info "IPv6 egress: ${ip6} ✓"
    else
        warn "IPv6 test failed — may need time or manual route check"
    fi

    echo ""
    info "Done!"
    echo -e "  Config:    ${CYAN}${CONFIG}${NC}"
    echo -e "  Service:   ${CYAN}systemctl status ${SERVICE_NAME}${NC}"
    echo -e "  Logs:      ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}"
    echo -e "  Uninstall: ${CYAN}$0 -u${NC}"
}

# ─── Parse flags ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -6|--ipv6-route)   IPV6_ROUTE="$2";       shift 2 ;;
        -t|--table)        IPV6_ROUTE_TABLE="$2";  shift 2 ;;
        -v|--version)      USQUE_VERSION="$2";      shift 2 ;;
        -u|--uninstall)    do_uninstall; exit 0 ;;
        -h|--help)
            cat << HELP
Usage: $0 [OPTIONS]

Options:
  -6, --ipv6-route PREFIX   IPv6 route via WARP (default: default)
  -t, --table NUM           Separate routing table for policy routing
  -v, --version VER         usque version (default: ${USQUE_VERSION})
  -u, --uninstall           Remove usque and clean up
  -h, --help                Show this help

Examples:
  # Basic — WARP as IPv6 egress (default route)
  $0

  # Specific prefix
  $0 -6 2001:db8::/48

  # Policy routing — IPv6 in table 100, original default untouched
  $0 -6 default -t 100

  # Uninstall
  $0 -u
HELP
            exit 0 ;;
        *) fail "Unknown option: $1 (use -h for help)" ;;
    esac
done

# ─── Preflight ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run as root"
command -v curl >/dev/null || { info "Installing curl..."; apt-get update -qq && apt-get install -y -qq curl; }
command -v unzip >/dev/null || { info "Installing unzip..."; apt-get install -y -qq unzip; }

# ─── Run ──────────────────────────────────────────────────────────────────────
download_usque
register_account
write_on_connect
write_service
start_and_verify
