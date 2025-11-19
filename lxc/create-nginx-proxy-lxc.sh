#!/usr/bin/env bash
# ==============================================================================
# Script: Nginx Proxy Manager LXC
# Beschreibung: Erstellt LXC mit Nginx Proxy Manager + SSL
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
HOSTNAME=${HOSTNAME:-nginx-proxy}
MEMORY=${MEMORY:-512}
DISK=${DISK:-8}
CORES=${CORES:-1}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}
TEMPLATE=${TEMPLATE:-$(get_latest_debian_template)}

NPM_ADMIN_EMAIL=${NPM_ADMIN_EMAIL:-admin@example.com}
NPM_ADMIN_PASSWORD=${NPM_ADMIN_PASSWORD:-$(openssl rand -base64 16)}
DB_MYSQL_PASSWORD=${DB_MYSQL_PASSWORD:-$(openssl rand -base64 16)}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Nginx Proxy Manager LXC"
    log_info "Reverse Proxy mit Web-GUI und SSL-Management"
    echo
    show_ip_allocation
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    require_root
    require_proxmox
    
    if ! validate_vmid_range "$VMID" "lxc"; then
        if ! ask_yes_no "VMID $VMID außerhalb LXC-Bereich. Fortfahren?"; then
            exit 0
        fi
    fi
    
    if vmid_exists "$VMID"; then
        die "VMID $VMID ist bereits vergeben!" 1
    fi
    
    local target_ip=$(get_ip_for_vmid "$VMID")
    log_info "Geplante IP: $target_ip"
    
    log_success "Alle Voraussetzungen erfüllt"
}

create_nginx_proxy_container() {
    log_step "Erstelle LXC Container..."
    
    if ! template_exists "$TEMPLATE" "$STORAGE"; then
        download_template "$TEMPLATE" "$STORAGE"
    fi
    
    local ROOTPW=$(openssl rand -base64 16)
    local ip=$(get_ip_for_vmid "$VMID")
    local net_config=$(create_network_string "$VMID" "$BRIDGE" "eth0")
    
    log_info "Erstelle Container:"
    log_info "  VMID: $VMID"
    log_info "  IP: ${ip}/${NETMASK}"
    log_info "  Hostname: $HOSTNAME"
    
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
# Nginx Proxy Manager LXC
Created: $(date '+%Y-%m-%d %H:%M:%S')
VMID: $VMID
IP: ${ip}/${NETMASK}
Gateway: $GATEWAY
Root Password: $ROOTPW

Admin Panel:
  URL: http://${ip}:81
  Email: $NPM_ADMIN_EMAIL
  Password: $NPM_ADMIN_PASSWORD

Database:
  MySQL Password: $DB_MYSQL_PASSWORD
EOF
    
    chmod 600 "$info_dir/${VMID}-${HOSTNAME}.txt"
    
    wait_for_lxc "$VMID" 60
}

install_dependencies() {
    log_step "Installiere Abhängigkeiten..."
    
    lxc_exec "$VMID" bash -c "
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    "
    
    lxc_install_package "$VMID" \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        ubuntu-keyring \
        apt-transport-https
}

install_docker() {
    log_step "Installiere Docker..."
    
    lxc_exec "$VMID" bash -c "
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
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

install_nginx_proxy_manager() {
    log_step "Installiere Nginx Proxy Manager..."
    
    # Erstelle docker-compose.yml
    lxc_exec "$VMID" mkdir -p /opt/npm
    
    lxc_exec "$VMID" bash -c "cat > /opt/npm/docker-compose.yml" << 'COMPOSE_EOF'
version: '3.8'

services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    environment:
      DB_MYSQL_HOST: "db"
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: "npm"
      DB_MYSQL_PASSWORD: "${DB_MYSQL_PASSWORD}"
      DB_MYSQL_NAME: "npm"
      DISABLE_IPV6: 'true'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    depends_on:
      - db

  db:
    image: 'jc21/mariadb-aria:latest'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_MYSQL_PASSWORD}"
      MYSQL_DATABASE: "npm"
      MYSQL_USER: "npm"
      MYSQL_PASSWORD: "${DB_MYSQL_PASSWORD}"
    volumes:
      - ./mysql:/var/lib/mysql
COMPOSE_EOF
    
    # Environment-Datei
    lxc_exec "$VMID" bash -c "cat > /opt/npm/.env" << ENV_EOF
DB_MYSQL_PASSWORD=${DB_MYSQL_PASSWORD}
ENV_EOF
    
    # Starte Container
    log_info "Starte Docker Compose..."
    lxc_exec "$VMID" bash -c "cd /opt/npm && docker compose up -d"
    
    # Warte bis NPM läuft
    sleep 10
    
    log_success "Nginx Proxy Manager läuft"
}

show_post_install_info() {
    local ip=$(get_ip_for_vmid "$VMID")
    
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Nginx Proxy Manager LXC erstellt!"
    log_success "═══════════════════════════════════════"
    echo
    
    log_info "Container-Details:"
    echo "  VMID:     $VMID"
    echo "  IP:       ${ip}/${NETMASK}"
    echo "  Gateway:  $GATEWAY"
    echo
    
    log_info "Nginx Proxy Manager:"
    echo "  Admin URL: http://${ip}:81"
    echo "  Email:     $NPM_ADMIN_EMAIL"
    echo "  Password:  $NPM_ADMIN_PASSWORD"
    echo
    echo "  Proxy Ports:"
    echo "    HTTP:  ${ip}:80"
    echo "    HTTPS: ${ip}:443"
    echo
    
    log_info "Zugriff:"
    echo "  pct exec $VMID -- docker ps"
    echo "  pct exec $VMID -- docker compose -f /opt/npm/docker-compose.yml logs -f"
    echo
    
    log_info "Container-Info:"
    echo "  /root/.lxc-info/${VMID}-${HOSTNAME}.txt"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    create_nginx_proxy_container
    install_dependencies
    install_docker
    install_nginx_proxy_manager
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Fehler!"; exit 1' ERR
trap 'log_info "Abgebrochen"; exit 130' INT TERM

main "$@"
