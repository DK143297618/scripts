#!/usr/bin/env bash
# update-smartdns.sh — Install or update pymumu/smartdns on Debian/Ubuntu from GitHub releases
# https://github.com/pymumu/smartdns
#
# Fetches the LATEST release .deb (with Web UI plugin smartdns_ui.so included)
# and installs via dpkg — preserves /etc/smartdns/smartdns.conf across upgrades.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DK143297618/scripts/main/update-smartdns.sh | bash
#   curl -fsSL .../update-smartdns.sh | bash -s -- install    # force fresh install
#   curl -fsSL .../update-smartdns.sh | bash -s -- update    # force upgrade check
#   curl -fsSL .../update-smartdns.sh | bash -s -- -v        # verbose (print versions)
#
# Tested on: Debian 12 (bookworm) / 13 (trixie), amd64 & arm64
set -euo pipefail

REPO="pymumu/smartdns"
API="https://api.github.com/repos/${REPO}/releases/latest"
DL="https://github.com/${REPO}/releases/download"

# ─── Colors & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; exit 1; }

# ─── Args ────────────────────────────────────────────────────────────────────
MODE="auto"; VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        install) MODE="install" ;;
        update)  MODE="update" ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) fail "Unknown arg: $1 (use install|update|-v)" ;;
    esac
    shift
done

is_root() { [[ $EUID -eq 0 ]]; }

# Detect dpkg-installed version: "1.2026.06.28-1614 Release48" → 2026.06.28-1614
installed_ver() {
    dpkg-query -W -f='${Version}' smartdns 2>/dev/null | grep -oP '^\d{4}\.\d{2}\.\d{2}-\d{4}' || true
}

# Detect release version from GitHub API: tag "Release48.4", asset version "1.2026.08.05-0921"
latest_info() {
    local json ver asset_ver
    json=$(curl -fsSL --connect-timeout 15 "${API}") || fail "GitHub API unreachable (network? firewall?)"
    echo "$json"
}

arch_suffix() {
    case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
        amd64|x86_64)  echo "x86_64-debian-all.deb" ;;
        arm64|aarch64) echo "aarch64-debian-all.deb" ;;
        armhf|armv7l)  echo "arm-debian-all.deb" ;;
        i386|i686)     echo "x86-debian-all.deb" ;;
        *) fail "Unsupported arch: $(uname -m) — Debian builds only ship amd64/arm64/arm/x86" ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────
[[ $VERBOSE -eq 1 ]] && set -x

command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
is_root || fail "Run as root (sudo $0 $*)"

json=$(latest_info)
tag=$(echo "$json"    | grep -oP '"tag_name":\s*"\K[^"]+')
# asset version from the x86_64 deb name, e.g. smartdns.1.2026.08.05-0921.x86_64-debian-all.deb
asset_ver=$(echo "$json" | grep -oP 'smartdns\.1\.\K\d{4}\.\d{2}\.\d{2}-\d{4}(?=\.x86_64-debian-all\.deb)' | head -1)
ARCH=$(arch_suffix)
DEB="smartdns.1.${asset_ver}.${ARCH}"
URL="${DL}/${tag}/${DEB}"
VER=$(echo "$asset_ver" | cut -d. -f1-3)   # 2026.08.05 (display only)

cur=$(installed_ver)
has_pkg=0
dpkg-query -W -f='${Status}' smartdns 2>/dev/null | grep -q '^ii ' && has_pkg=1

if [[ $has_pkg -eq 1 ]]; then
    if [[ -n "$cur" && "$MODE" == "install" ]]; then
        fail "smartdns already installed ($cur). Run without args or 'update' to upgrade."
    fi
    if [[ -n "$cur" && "$cur" == "$asset_ver" ]]; then
        info "Already up to date: ${cur} == latest ${asset_ver}"
        exit 0
    fi
    if [[ -n "$cur" ]]; then
        info "Upgrade: ${cur} → ${asset_ver} (${tag})"
    else
        # apt/debian package version (e.g. 40+dfsg-1) — no date format, can't compare.
        # dpkg -i of the newer custom build cleanly replaces it.
        info "Existing distro package detected — replacing with ${asset_ver} (${tag})"
    fi
else
    if [[ "$MODE" == "update" ]]; then
        fail "smartdns not installed — run without args or 'install' first."
    fi
    info "Installing smartdns ${asset_ver} (${tag}) fresh..."
fi

info "Downloading: ${DEB}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fSL --connect-timeout 20 -o "${TMP}/smartdns.deb" "${URL}" \
    || fail "Download failed: ${URL}"
info "Verifying package..."
dpkg-deb --info "${TMP}/smartdns.deb" >/dev/null 2>&1 \
    || fail "Downloaded file is not a valid .deb (corrupted transfer?)"

# Backup config once before first upgrade (dpkg keeps it anyway, belt & braces)
if [[ -f /etc/smartdns/smartdns.conf && ! -f /etc/smartdns/smartdns.conf.pre-update ]]; then
    cp -a /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.pre-update
    info "Config backed up → /etc/smartdns/smartdns.conf.pre-update"
fi

# dpkg versioning: the custom build (2026.08.05-0921) sorts BELOW Debian's apt
# package (40+dfsg-1) even though it's newer — plain `dpkg -i` refuses it as a
# downgrade. --force-downgrade lets dpkg replace it while preserving conffiles
# (/etc/smartdns/smartdns.conf) natively — no purge needed.
FORCE_ARGS=""
if dpkg-query -W -f='${Version}' smartdns 2>/dev/null | grep -q 'dfsg'; then
    info "Distro package detected (versioning incompatible) — using --force-downgrade"
    FORCE_ARGS="--force-downgrade"
fi

dpkg -i ${FORCE_ARGS} "${TMP}/smartdns.deb" || {
    warn "dpkg -i failed — attempting dependency fix..."
    apt-get -f install -y -qq
    dpkg -i ${FORCE_ARGS} "${TMP}/smartdns.deb"
} || fail "Install failed even after apt -f"

systemctl daemon-reload 2>/dev/null || true
if systemctl list-unit-files smartdns.service >/dev/null 2>&1; then
    systemctl enable smartdns >/dev/null 2>&1 || true
    systemctl restart smartdns
    sleep 1
    if systemctl is-active --quiet smartdns; then
        info "smartdns service: active ✓"
    else
        warn "smartdns service NOT active — check: journalctl -u smartdns"
    fi
fi

new=$(installed_ver)
info "Done: ${cur:-<none>} → ${new:-unknown}"
[[ -x /usr/sbin/smartdns ]] && /usr/sbin/smartdns -v 2>/dev/null | head -1 | sed 's/^/    /' || true
info "Config untouched: /etc/smartdns/smartdns.conf"
info "Web UI (if plugin present): http://<host>:6080  (default admin/password)"
