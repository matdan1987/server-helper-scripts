#!/usr/bin/env bash
# ==============================================================================
# Script: Vaultwarden LXC Creator
# Beschreibung: Erstellt LXC mit Vaultwarden (Bitwarden-kompatibler Password Manager)
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
HOSTNAME=${HOSTNAME:-vaultwarden}
MEMORY=${MEMORY:-2048}
DISK=${DISK:-10}
CORES=${CORES:-2}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

VAULTWARDEN_PORT=${VAULTWARDEN_PORT:-8080}
ADMIN_TOKEN=${ADMIN_TOKEN:-$(openssl rand -base64 32)}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Vaultwarden LXC Container"
    log_info "Bitwarden-kompatibler Password Manager"
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

install_vaultwarden() {
    log_step "Installiere Vaultwarden..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # Dependencies installieren
    lxc_install_package "$VMID" curl wget ca-certificates

    # Docker installieren
    lxc_exec "$VMID" bash -c "curl -fsSL https://get.docker.com | sh"

    # Vaultwarden Container starten
    lxc_exec "$VMID" bash -c "cat > /root/docker-compose.yml << 'EOF'
version: '3'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: always
    ports:
      - '${VAULTWARDEN_PORT}:80'
    volumes:
      - /opt/vaultwarden/data:/data
    environment:
      - ADMIN_TOKEN=${ADMIN_TOKEN}
      - SIGNUPS_ALLOWED=true
      - INVITATIONS_ALLOWED=true
      - SHOW_PASSWORD_HINT=false
      - DOMAIN=https://vault.example.com
EOF
"

    # Docker Compose installieren
    lxc_exec "$VMID" bash -c "apt-get install -y docker-compose"

    # Verzeichnis erstellen
    lxc_exec "$VMID" bash -c "mkdir -p /opt/vaultwarden/data"

    # Container starten
    lxc_exec "$VMID" bash -c "cd /root && docker-compose up -d"

    log_success "Vaultwarden installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "Vaultwarden LXC erfolgreich erstellt!"
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
    echo "  Vaultwarden:   http://$ip:$VAULTWARDEN_PORT"
    echo "  Admin Panel:   http://$ip:$VAULTWARDEN_PORT/admin"
    echo "  Admin Token:   $ADMIN_TOKEN"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Nächste Schritte:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  1. Admin Panel öffnen: http://$ip:$VAULTWARDEN_PORT/admin"
    echo "  2. Mit Admin Token einloggen"
    echo "  3. Reverse Proxy (nginx/caddy) mit HTTPS einrichten"
    echo "  4. DOMAIN in docker-compose.yml anpassen"
    echo "  5. Browser Extension installieren"
    echo
    echo "  Wichtig: Admin Token sicher aufbewahren!"
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
    install_vaultwarden
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
