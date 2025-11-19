#!/usr/bin/env bash
# ==============================================================================
# Script: Docker LXC Creator
# Beschreibung: Erstellt LXC mit Docker + Docker Compose + Portainer
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
    curl -fsSL "$GITHUB_RAW/lib/lxc-helpers.sh" -o "$LIB_TMP/lxc-helpers.sh"
    
    LIB_DIR="$LIB_TMP"
    trap "rm -rf '$LIB_TMP'" EXIT
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
fi

source "$LIB_DIR/common.sh"
source "$LIB_DIR/proxmox-common.sh"
source "$LIB_DIR/lxc-helpers.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

VMID=${VMID:-$(get_next_vmid 200 299)}
HOSTNAME=${HOSTNAME:-docker}
MEMORY=${MEMORY:-4096}
DISK=${DISK:-100}
CORES=${CORES:-4}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}
TEMPLATE=${TEMPLATE:-$(get_latest_debian_template)}

INSTALL_PORTAINER=${INSTALL_PORTAINER:-true}
PORTAINER_PORT=${PORTAINER_PORT:-9443}
PORTAINER_VERSION=${PORTAINER_VERSION:-latest}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Docker LXC Container Erstellen"
    log_info "Erstellt LXC mit Docker, Docker Compose und Portainer"
    echo
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    
    require_root
    require_proxmox
    
    # Prüfe ob VMID frei ist
    if vmid_exists "$VMID"; then
        die "VMID $VMID ist bereits vergeben!" 1
    fi
    
    log_success "Alle Voraussetzungen erfüllt"
}

create_docker_container() {
    log_step "Erstelle LXC Container..."
    
    # Template herunterladen falls nötig
    if ! template_exists "$TEMPLATE" "$STORAGE"; then
        download_template "$TEMPLATE" "$STORAGE"
    fi
    
    # Root-Passwort generieren
    local ROOTPW=$(openssl rand -base64 16)
    
    # Container erstellen
    pct create "$VMID" "${STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --password "$ROOTPW" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1" \
        --features "nesting=1,keyctl=1" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1
    
    log_success "LXC Container $VMID erstellt"
    
    # Container-Info speichern
    save_lxc_info "$VMID" "$HOSTNAME" "$ROOTPW"
    
    # Warte bis Container bereit
    wait_for_lxc "$VMID" 60
    
    # Docker-Konfiguration hinzufügen
    prepare_docker_lxc "$VMID"
}

install_docker_in_lxc() {
    log_step "Installiere Docker im LXC..."
    
    # Basis-System aktualisieren
    lxc_exec "$VMID" bash -c "
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    "
    
    # Dependencies installieren
    lxc_install_package "$VMID" \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https
    
    # Docker Repository hinzufügen
    lxc_exec "$VMID" bash -c "
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update -qq
    "
    
    # Docker installieren
    lxc_install_package "$VMID" \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    # Docker Service starten
    lxc_exec "$VMID" systemctl enable --now docker
    
    log_success "Docker installiert"
}

install_portainer() {
    if [[ "$INSTALL_PORTAINER" != "true" ]]; then
        return 0
    fi
    
    log_step "Installiere Portainer..."
    
    # Portainer Volume erstellen
    lxc_exec "$VMID" docker volume create portainer_data
    
    # Portainer Container starten
    lxc_exec "$VMID" docker run -d \
        --name portainer \
        --restart=always \
        -p 8000:8000 \
        -p "${PORTAINER_PORT}:9443" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:${PORTAINER_VERSION}
    
    log_success "Portainer installiert"
}

configure_docker() {
    log_step "Konfiguriere Docker..."
    
    # Docker Daemon-Konfiguration
    lxc_exec "$VMID" bash -c "cat > /etc/docker/daemon.json" << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "userland-proxy": false,
  "ip-forward": true
}
EOF
    
    # Docker neu laden
    lxc_exec "$VMID" systemctl daemon-reload
    lxc_exec "$VMID" systemctl restart docker
    
    log_success "Docker konfiguriert"
}

create_docker_compose_template() {
    log_step "Erstelle Docker Compose Template..."
    
    # Projektverzeichnis erstellen
    lxc_exec "$VMID" mkdir -p /opt/docker-projects
    
    # Beispiel docker-compose.yml
    lxc_exec "$VMID" bash -c "cat > /opt/docker-projects/example-docker-compose.yml" << 'EOF'
version: '3.8'

services:
  # Beispiel-Service
  # nginx:
  #   image: nginx:latest
  #   container_name: nginx
  #   restart: unless-stopped
  #   ports:
  #     - "80:80"
  #   volumes:
  #     - ./nginx/html:/usr/share/nginx/html:ro
  #   networks:
  #     - webnet

networks:
  webnet:
    driver: bridge
EOF
    
    log_success "Docker Compose Template erstellt"
}

show_post_install_info() {
    local lxc_ip=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')
    
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Docker LXC erfolgreich erstellt!"
    log_success "═══════════════════════════════════════"
    echo
    
    log_info "Container-Details:"
    echo "  VMID: $VMID"
    echo "  Hostname: $HOSTNAME"
    echo "  IP-Adresse: $lxc_ip"
    echo "  Memory: ${MEMORY}MB"
    echo "  Disk: ${DISK}GB"
    echo "  Cores: $CORES"
    echo
    
    log_info "Docker:"
    echo "  Version: $(pct exec "$VMID" -- docker --version)"
    echo "  Compose: $(pct exec "$VMID" -- docker compose version)"
    echo
    
    if [[ "$INSTALL_PORTAINER" == "true" ]]; then
        log_info "Portainer:"
        echo "  URL: https://${lxc_ip}:${PORTAINER_PORT}"
        echo "  Beim ersten Start Admin-Account erstellen"
        echo
    fi
    
    log_info "Zugriff auf Container:"
    echo "  pct enter $VMID"
    echo "  pct exec $VMID -- docker ps"
    echo
    
    log_info "Nützliche Befehle im Container:"
    echo "  docker ps                    # Laufende Container"
    echo "  docker compose up -d          # Compose-Projekt starten"
    echo "  docker logs <container>       # Container-Logs"
    echo "  docker exec -it <container> bash   # Shell im Container"
    echo
    
    log_info "Container-Info gespeichert:"
    echo "  /root/.lxc-info/${VMID}-${HOSTNAME}.txt"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    create_docker_container
    install_docker_in_lxc
    configure_docker
    install_portainer
    create_docker_compose_template
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Fehler bei LXC-Erstellung!"; exit 1' ERR
trap 'log_info "Abgebrochen"; exit 130' INT TERM

main "$@"
