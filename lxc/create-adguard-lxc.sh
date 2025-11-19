#!/usr/bin/env bash
# ==============================================================================
# Script: AdGuard Home LXC Creator
# Beschreibung: Erstellt LXC mit AdGuard Home (Network-wide Ad Blocker)
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

# =============================================================================
# PFAD-ERKENNUNG
# =============================================================================

if [[ "$0" == "/dev/fd/"* ]] || [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]]; then
    GITHUB_RAW="https://raw.githubusercontent.com/matdan1987/server-helper-scripts/main"
    LIB_TMP="/tmp/helper-scripts-lib-$$"
    mkdir -p "$LIB_TMP"

    echo "Lade Bibliotheken..."
    curl -fsSL "$GITHUB_RAW/lib/common.sh" -o "$LIB_TMP/common.sh"
    curl -fsSL "$GITHUB_RAW/lib/proxmox-common.sh" -o "$LIB_TMP/proxmox-common.sh"

    LIB_DIR="$LIB_TMP"
    trap "rm -rf '$LIB_TMP'" EXIT
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
fi

source "$LIB_DIR/common.sh"
source "$LIB_DIR/proxmox-common.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

VMID=${VMID:-$(get_next_vmid lxc)}
HOSTNAME=${HOSTNAME:-adguard}
MEMORY=${MEMORY:-512}
DISK=${DISK:-4}
CORES=${CORES:-1}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

WEB_PORT=${WEB_PORT:-3000}
DNS_PORT=${DNS_PORT:-53}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "AdGuard Home LXC"
    log_info "Network-wide Ads & Trackers Blocking DNS Server"
    echo
    show_ip_allocation
}

create_container() {
    log_step "Erstelle LXC Container..."

    local ip=$(get_ip_for_vmid "$VMID")
    local network_config=$(create_network_string "$VMID" "$BRIDGE" "eth0")

    pct create "$VMID" local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --net0 "$network_config" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1

    log_success "Container erstellt: $VMID ($ip)"
}

install_adguard() {
    log_step "Installiere AdGuard Home..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # Dependencies installieren
    lxc_install_package "$VMID" curl wget ca-certificates

    # AdGuard Home herunterladen und installieren
    lxc_exec "$VMID" bash -c "
        cd /tmp
        curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
    "

    # Port-Bindung anpassen (initial auf 3000 statt 80)
    lxc_exec "$VMID" bash -c "
        mkdir -p /opt/AdGuardHome/conf
        cat > /opt/AdGuardHome/conf/AdGuardHome.yaml << EOF
bind_host: 0.0.0.0
bind_port: ${WEB_PORT}
dns:
  bind_hosts:
    - 0.0.0.0
  port: ${DNS_PORT}
EOF
    "

    # Service neu starten
    lxc_exec "$VMID" bash -c "systemctl restart AdGuardHome"

    log_success "AdGuard Home installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "AdGuard Home LXC erfolgreich erstellt!"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Container-Info"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  VMID:          $VMID"
    echo "  Hostname:      $HOSTNAME"
    echo "  IP:            $ip"
    echo "  Memory:        ${MEMORY}MB"
    echo "  Disk:          ${DISK}GB"
    echo "  Cores:         $CORES"
    echo
    echo "  Web UI:        http://$ip:$WEB_PORT"
    echo "  DNS Server:    $ip:$DNS_PORT"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Nächste Schritte:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  1. UI öffnen: http://$ip:$WEB_PORT"
    echo "  2. Setup-Wizard durchlaufen"
    echo "  3. Admin-Passwort festlegen"
    echo "  4. Filter und Blocklisten konfigurieren"
    echo
    echo "  DNS auf AdGuard umstellen:"
    echo "    - Router: DNS auf $ip setzen"
    echo "    - Einzelgeräte: DNS auf $ip setzen"
    echo
    echo "  Testen:"
    echo "    dig @$ip google.com"
    echo "    nslookup google.com $ip"
    echo
    echo "  Empfohlene Blocklisten (in UI hinzufügen):"
    echo "    - AdGuard DNS filter"
    echo "    - EasyList"
    echo "    - Peter Lowe's List"
    echo
    echo "  Status:"
    echo "    pct exec $VMID -- systemctl status AdGuardHome"
    echo "═══════════════════════════════════════════════════════════════"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    require_root
    require_proxmox

    show_banner
    create_container
    install_adguard
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
