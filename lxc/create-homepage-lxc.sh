#!/usr/bin/env bash
# ==============================================================================
# Script: Homepage LXC Creator
# Beschreibung: Erstellt LXC mit Homepage (Modern Self-Hosted Dashboard)
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
HOSTNAME=${HOSTNAME:-homepage}
MEMORY=${MEMORY:-512}
DISK=${DISK:-4}
CORES=${CORES:-1}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

HOMEPAGE_PORT=${HOMEPAGE_PORT:-3000}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Homepage Dashboard LXC"
    log_info "Modern, Customizable Application Dashboard"
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

install_homepage() {
    log_step "Installiere Homepage..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # Docker installieren
    lxc_install_package "$VMID" curl ca-certificates
    lxc_exec "$VMID" bash -c "curl -fsSL https://get.docker.com | sh"

    # Konfigurationsverzeichnisse erstellen
    lxc_exec "$VMID" bash -c "mkdir -p /opt/homepage/config"

    # Docker Compose Datei erstellen
    lxc_exec "$VMID" bash -c "cat > /opt/homepage/docker-compose.yml << 'EOF'
version: '3.3'
services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: always
    ports:
      - ${HOMEPAGE_PORT}:3000
    volumes:
      - /opt/homepage/config:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - PUID=1000
      - PGID=1000
EOF
"

    # Beispiel-Konfiguration erstellen
    lxc_exec "$VMID" bash -c "cat > /opt/homepage/config/services.yaml << 'EOF'
---
# Beispiel Services - Anpassen nach Bedarf

- Proxmox:
    - Proxmox VE:
        icon: proxmox.png
        href: https://proxmox.example.com:8006
        description: Virtualisierung

- Monitoring:
    - Uptime Kuma:
        icon: uptime-kuma.png
        href: http://uptime-kuma.local:3001
        description: Uptime Monitoring

- Media:
    - Jellyfin:
        icon: jellyfin.png
        href: http://jellyfin.local:8096
        description: Media Server
EOF
"

    lxc_exec "$VMID" bash -c "cat > /opt/homepage/config/widgets.yaml << 'EOF'
---
# System-Widgets
- resources:
    cpu: true
    memory: true
    disk: /

- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: short
EOF
"

    lxc_exec "$VMID" bash -c "cat > /opt/homepage/config/settings.yaml << 'EOF'
---
title: Dashboard
theme: dark
color: slate
layout:
  Proxmox:
    style: row
    columns: 3
  Monitoring:
    style: row
    columns: 3
EOF
"

    # Docker Compose installieren und starten
    lxc_install_package "$VMID" docker-compose
    lxc_exec "$VMID" bash -c "cd /opt/homepage && docker-compose up -d"

    log_success "Homepage installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "Homepage Dashboard LXC erfolgreich erstellt!"
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
    echo "  Homepage:      http://$ip:$HOMEPAGE_PORT"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Konfiguration:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Konfig-Ordner: /opt/homepage/config/"
    echo
    echo "  Wichtige Dateien:"
    echo "    - services.yaml  # Deine Services/Links"
    echo "    - widgets.yaml   # Widgets (Wetter, CPU, etc.)"
    echo "    - settings.yaml  # Globale Einstellungen"
    echo
    echo "  Konfig bearbeiten:"
    echo "    pct exec $VMID -- nano /opt/homepage/config/services.yaml"
    echo
    echo "  Nach Änderungen neu starten:"
    echo "    pct exec $VMID -- docker-compose -f /opt/homepage/docker-compose.yml restart"
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
    install_homepage
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
