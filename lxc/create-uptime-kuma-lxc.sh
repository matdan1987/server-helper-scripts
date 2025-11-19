#!/usr/bin/env bash
# ==============================================================================
# Script: Uptime Kuma LXC Creator
# Beschreibung: Erstellt LXC mit Uptime Kuma (Self-Hosted Monitoring Tool)
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
HOSTNAME=${HOSTNAME:-uptime-kuma}
MEMORY=${MEMORY:-1024}
DISK=${DISK:-8}
CORES=${CORES:-2}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

KUMA_PORT=${KUMA_PORT:-3001}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Uptime Kuma LXC Container"
    log_info "Fancy Self-Hosted Monitoring Tool"
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
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1 \
        --start 1

    log_success "Container erstellt: $VMID ($ip)"
}

install_uptime_kuma() {
    log_step "Installiere Uptime Kuma..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # Node.js installieren
    lxc_install_package "$VMID" curl git

    lxc_exec "$VMID" bash -c "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    lxc_install_package "$VMID" nodejs

    # Uptime Kuma installieren
    lxc_exec "$VMID" bash -c "
        cd /opt
        git clone https://github.com/louislam/uptime-kuma.git
        cd uptime-kuma
        npm run setup
    "

    # Systemd Service erstellen
    lxc_exec "$VMID" bash -c "cat > /etc/systemd/system/uptime-kuma.service << 'EOF'
[Unit]
Description=Uptime Kuma
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/uptime-kuma
ExecStart=/usr/bin/node server/server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
"

    # Service aktivieren und starten
    lxc_exec "$VMID" bash -c "systemctl daemon-reload && systemctl enable --now uptime-kuma"

    log_success "Uptime Kuma installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "Uptime Kuma LXC erfolgreich erstellt!"
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
    echo "  Uptime Kuma:   http://$ip:$KUMA_PORT"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Nächste Schritte:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  1. UI öffnen: http://$ip:$KUMA_PORT"
    echo "  2. Admin-Account erstellen (beim ersten Besuch)"
    echo "  3. Monitore hinzufügen (HTTP, TCP, Ping, etc.)"
    echo "  4. Benachrichtigungen einrichten (Discord, Telegram, Email, etc.)"
    echo
    echo "  Status prüfen:"
    echo "    pct exec $VMID -- systemctl status uptime-kuma"
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
    install_uptime_kuma
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
