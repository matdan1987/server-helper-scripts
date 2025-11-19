#!/usr/bin/env bash
# ==============================================================================
# Script: Docker LXC Creator
# Beschreibung: Erstellt LXC mit Docker + Portainer (intelligentes IP-Schema)
# Autor: matdan1987
# Version: 1.1.0
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
HOSTNAME=${HOSTNAME:-docker}
MEMORY=${MEMORY:-$(calculate_lxc_memory docker)}
DISK=${DISK:-$(calculate_lxc_disk docker)}
CORES=${CORES:-$(calculate_lxc_cores docker)}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}
TEMPLATE=${TEMPLATE:-$(get_latest_debian_template)}

INSTALL_PORTAINER=${INSTALL_PORTAINER:-true}
PORTAINER_PORT=${PORTAINER_PORT:-9443}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Docker LXC Container"
    log_info "Erstellt LXC mit Docker + Portainer"
    echo
    show_ip_allocation
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    
    require_root
    require_proxmox
    
    # Validiere VMID-Range
    if ! validate_vmid_range "$VMID" "lxc"; then
        if ! ask_yes_no "VMID $VMID außerhalb LXC-Bereich ($LXC_ID_START-$LXC_ID_END). Trotzdem fortfahren?"; then
            exit 0
        fi
    fi
    
    # Prüfe ob VMID frei
    if vmid_exists "$VMID"; then
        die "VMID $VMID ist bereits vergeben!" 1
    fi
    
    # Prüfe IP
    local target_ip=$(get_ip_for_vmid "$VMID")
    log_info "Geplante IP: $target_ip"
    
    if ! is_ip_available "$target_ip"; then
        log_warn "IP $target_ip scheint bereits in Nutzung zu sein!"
        if ! ask_yes_no "Trotzdem fortfahren?"; then
            exit 0
        fi
    fi
    
    log_success "Alle Voraussetzungen erfüllt"
}

create_docker_container() {
    log_step "Erstelle LXC Container..."
    
    # Template herunterladen
    if ! template_exists "$TEMPLATE" "$STORAGE"; then
        download_template "$TEMPLATE" "$STORAGE"
    fi
    
    # Root-Passwort
    local ROOTPW=$(openssl rand -base64 16)
    
    # IP-Konfiguration
    local ip=$(get_ip_for_vmid "$VMID")
    local net_config=$(create_network_string "$VMID" "$BRIDGE" "eth0")
    
    log_info "Erstelle Container mit:"
    log_info "  VMID: $VMID"
    log_info "  IP: ${ip}/${NETMASK}"
    log_info "  Gateway: $GATEWAY"
    log_info "  Hostname: $HOSTNAME"
    
    # Container erstellen
    pct create "$VMID" "${STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --password "$ROOTPW" \
        --net0 "$net_config" \
        --nameserver "1.1.1.1 8.8.8.8" \
        --searchdomain "local" \
        --features "nesting=1,keyctl=1" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1
    
    log_success "LXC Container $VMID erstellt"
    
    # Info speichern
    local info_dir="/root/.lxc-info"
    mkdir -p "$info_dir"
    
    cat > "$info_dir/${VMID}-${HOSTNAME}.txt" << EOF
# Docker LXC Information
Created: $(date '+%Y-%m-%d %H:%M:%S')
VMID: $VMID
Hostname: $HOSTNAME
IP: ${ip}/${NETMASK}
Gateway: $GATEWAY
Root Password: $ROOTPW
Service: Docker + Portainer
Portainer URL: https://${ip}:${PORTAINER_PORT}
EOF
    
    chmod 600 "$info_dir/${VMID}-${HOSTNAME}.txt"
    
    wait_for_lxc "$VMID" 60
    prepare_docker_lxc "$VMID"
}

install_docker_in_lxc() {
    log_step "Installiere Docker..."
    
    lxc_exec "$VMID" bash -c "
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    "
    
    lxc_install_package "$VMID" \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    lxc_exec "$VMID" bash -c "
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable' > /etc/apt/sources.list.d/docker.list
        
        apt-get update -qq
    "
    
    lxc_install_package "$VMID" \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    lxc_exec "$VMID" systemctl enable --now docker
    
    log_success "Docker installiert"
}

install_portainer() {
    if [[ "$INSTALL_PORTAINER" != "true" ]]; then
        return 0
    fi
    
    log_step "Installiere Portainer..."
    
    lxc_exec "$VMID" docker volume create portainer_data
    
    lxc_exec "$VMID" docker run -d \
        --name portainer \
        --restart=always \
        -p 8000:8000 \
        -p "${PORTAINER_PORT}:9443" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest
    
    log_success "Portainer installiert"
}

show_post_install_info() {
    local ip=$(get_ip_for_vmid "$VMID")
    
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Docker LXC erfolgreich erstellt!"
    log_success "═══════════════════════════════════════"
    echo
    
    log_info "Container-Details:"
    echo "  VMID:     $VMID"
    echo "  Hostname: $HOSTNAME"
    echo "  IP:       ${ip}/${NETMASK}"
    echo "  Gateway:  $GATEWAY"
    echo "  Memory:   ${MEMORY}MB"
    echo "  Disk:     ${DISK}GB"
    echo "  Cores:    $CORES"
    echo
    
    log_info "Docker:"
    echo "  Version: $(pct exec "$VMID" -- docker --version)"
    echo "  Compose: $(pct exec "$VMID" -- docker compose version)"
    echo
    
    if [[ "$INSTALL_PORTAINER" == "true" ]]; then
        log_info "Portainer:"
        echo "  URL: https://${ip}:${PORTAINER_PORT}"
        echo "  Beim ersten Start Admin-Account erstellen"
        echo
    fi
    
    log_info "Zugriff:"
    echo "  SSH:     ssh root@${ip}"
    echo "  Console: pct enter $VMID"
    echo "  Logs:    pct exec $VMID -- journalctl -u docker -f"
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
    create_docker_container
    install_docker_in_lxc
    install_portainer
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Fehler!"; exit 1' ERR
trap 'log_info "Abgebrochen"; exit 130' INT TERM

main "$@"
