#!/usr/bin/env bash
# ==============================================================================
# Script: n8n Workflow Automation LXC
# Beschreibung: Erstellt LXC mit n8n (Workflow-Automatisierung)
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

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
HOSTNAME=${HOSTNAME:-n8n}
MEMORY=${MEMORY:-$(calculate_lxc_memory n8n)}
DISK=${DISK:-$(calculate_lxc_disk n8n)}
CORES=${CORES:-$(calculate_lxc_cores n8n)}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}
TEMPLATE=${TEMPLATE:-$(get_latest_debian_template)}

N8N_ADMIN_USER=${N8N_ADMIN_USER:-admin}
N8N_ADMIN_PASSWORD=${N8N_ADMIN_PASSWORD:-$(openssl rand -base64 16)}
N8N_PORT=${N8N_PORT:-5678}
N8N_DOMAIN=${N8N_DOMAIN:-}

DB_POSTGRES_PASSWORD=${DB_POSTGRES_PASSWORD:-$(openssl rand -base64 16)}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "n8n Workflow Automation LXC"
    log_info "Erstellt LXC mit n8n für Workflow-Automatisierung"
    echo
    show_ip_allocation
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    require_root
    require_proxmox
    
    if ! validate_vmid_range "$VMID" "lxc"; then
        if ! ask_yes_no "VMID außerhalb Bereich. Fortfahren?"; then
            exit 0
        fi
    fi
    
    if vmid_exists "$VMID"; then
        die "VMID $VMID ist bereits vergeben!" 1
    fi
    
    log_success "Voraussetzungen erfüllt"
}

create_n8n_container() {
    log_step "Erstelle LXC Container..."
    
    if ! template_exists "$TEMPLATE" "$STORAGE"; then
        download_template "$TEMPLATE" "$STORAGE"
    fi
    
    local ROOTPW=$(openssl rand -base64 16)
    local ip=$(get_ip_for_vmid "$VMID")
    local net_config=$(create_network_string "$VMID" "$BRIDGE" "eth0")
    
    log_info "Container-Details:"
    log_info "  VMID: $VMID"
    log_info "  IP: ${ip}/${NETMASK}"
    
    pct create "$VMID" "${STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --password "$ROOTPW" \
        --net0 "$net_config" \
        --nameserver "1.1.1.1 8.8.8.8" \
        --features "nesting=1" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1
    
    log_success "LXC erstellt"
    
    # Info speichern
    local info_dir="/root/.lxc-info"
    mkdir -p "$info_dir"
    
    cat > "$info_dir/${VMID}-${HOSTNAME}.txt" << EOF
# n8n Workflow Automation LXC
Created: $(date '+%Y-%m-%d %H:%M:%S')
VMID: $VMID
IP: ${ip}/${NETMASK}
Gateway: $GATEWAY

n8n Access:
  URL: http://${ip}:${N8N_PORT}
  User: $N8N_ADMIN_USER
  Password: $N8N_ADMIN_PASSWORD

Database:
  PostgreSQL Password: $DB_POSTGRES_PASSWORD
EOF
    
    chmod 600 "$info_dir/${VMID}-${HOSTNAME}.txt"
    
    wait_for_lxc "$VMID" 60
}

install_docker() {
    log_step "Installiere Docker..."
    
    lxc_exec "$VMID" bash -c "
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl
    "
    
    lxc_exec "$VMID" bash -c "
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable' > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
    "
    
    lxc_install_package "$VMID" \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin
    
    lxc_exec "$VMID" systemctl enable --now docker
    
    log_success "Docker installiert"
}

install_n8n() {
    log_step "Installiere n8n..."
    
    # Erstelle docker-compose.yml
    lxc_exec "$VMID" mkdir -p /opt/n8n
    
    lxc_exec "$VMID" bash -c "cat > /opt/n8n/docker-compose.yml" << 'COMPOSE_EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: "${DB_POSTGRES_PASSWORD}"
      POSTGRES_USER: n8n
      POSTGRES_DB: n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost']
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: "${DB_POSTGRES_PASSWORD}"
      N8N_BASIC_AUTH_ACTIVE: 'true'
      N8N_BASIC_AUTH_USER: "${N8N_ADMIN_USER}"
      N8N_BASIC_AUTH_PASSWORD: "${N8N_ADMIN_PASSWORD}"
      N8N_HOST: "0.0.0.0"
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      N8N_EDITOR_BASE_URL: "/"
      WEBHOOK_URL: "http://localhost/"
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
  n8n_data:
COMPOSE_EOF
    
    # Environment-Datei
    lxc_exec "$VMID" bash -c "cat > /opt/n8n/.env" << ENV_EOF
DB_POSTGRES_PASSWORD=${DB_POSTGRES_PASSWORD}
N8N_ADMIN_USER=${N8N_ADMIN_USER}
N8N_ADMIN_PASSWORD=${N8N_ADMIN_PASSWORD}
ENV_EOF
    
    # Starte Container
    log_info "Starte n8n..."
    lxc_exec "$VMID" bash -c "cd /opt/n8n && docker compose up -d"
    
    sleep 15
    
    log_success "n8n läuft"
}

show_post_install_info() {
    local ip=$(get_ip_for_vmid "$VMID")
    
    echo
    log_success "═══════════════════════════════════════"
    log_success "  n8n LXC erstellt!"
    log_success "═══════════════════════════════════════"
    echo
    
    log_info "Container-Details:"
    echo "  VMID:   $VMID"
    echo "  IP:     ${ip}/${NETMASK}"
    echo
    
    log_info "n8n Access:"
    echo "  URL:      http://${ip}:${N8N_PORT}"
    echo "  User:     $N8N_ADMIN_USER"
    echo "  Password: $N8N_ADMIN_PASSWORD"
    echo
    
    log_info "Nützliche Befehle:"
    echo "  Logs:     pct exec $VMID -- docker compose -f /opt/n8n/docker-compose.yml logs -f"
    echo "  Status:   pct exec $VMID -- docker compose -f /opt/n8n/docker-compose.yml ps"
    echo "  Stop:     pct exec $VMID -- docker compose -f /opt/n8n/docker-compose.yml down"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    create_n8n_container
    install_docker
    install_n8n
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Fehler!"; exit 1' ERR
trap 'log_info "Abgebrochen"; exit 130' INT TERM

main "$@"
