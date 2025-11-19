#!/usr/bin/env bash
# lxc-helpers.sh - LXC-Management Funktionen
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/proxmox-common.sh"

# =============================================================================
# LXC-ERSTELLUNG
# =============================================================================

create_lxc_container() {
    local config_file="$1"
    
    # Lade Konfiguration
    source "$config_file"
    
    # Validierung
    [[ -z "$VMID" ]] && VMID=$(get_next_vmid)
    [[ -z "$HOSTNAME" ]] && die "HOSTNAME nicht definiert!" 1
    [[ -z "$TEMPLATE" ]] && TEMPLATE=$(get_latest_debian_template)
    [[ -z "$STORAGE" ]] && STORAGE=$(get_best_storage)
    [[ -z "$BRIDGE" ]] && BRIDGE=$(get_default_bridge)
    
    # Standardwerte
    [[ -z "$MEMORY" ]] && MEMORY=$(calculate_lxc_memory "${SERVICE_TYPE:-small}")
    [[ -z "$DISK" ]] && DISK=$(calculate_lxc_disk "${SERVICE_TYPE:-small}")
    [[ -z "$CORES" ]] && CORES=$(calculate_lxc_cores "${SERVICE_TYPE:-small}")
    [[ -z "$ROOTPW" ]] && ROOTPW=$(openssl rand -base64 16)
    [[ -z "$START" ]] && START=1
    [[ -z "$UNPRIVILEGED" ]] && UNPRIVILEGED=1
    
    log_step "Erstelle LXC Container..."
    log_info "VMID: $VMID"
    log_info "Hostname: $HOSTNAME"
    log_info "Template: $TEMPLATE"
    log_info "Memory: ${MEMORY}MB"
    log_info "Disk: ${DISK}GB"
    log_info "Cores: $CORES"
    
    # Template herunterladen falls nicht vorhanden
    if ! template_exists "$TEMPLATE" "$STORAGE"; then
        download_template "$TEMPLATE" "$STORAGE"
    fi
    
    # Container erstellen
    pct create "$VMID" "$STORAGE:vztmpl/$TEMPLATE" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --password "$ROOTPW" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --features "nesting=${NESTING:-0}" \
        --unprivileged "$UNPRIVILEGED" \
        --start "$START" \
        --onboot 1
    
    log_success "LXC Container $VMID erstellt"
    
    # Warte bis Container bereit
    if [[ "$START" == "1" ]]; then
        wait_for_lxc "$VMID"
    fi
    
    # Speichere Konfiguration
    save_lxc_info "$VMID" "$HOSTNAME" "$ROOTPW"
}

save_lxc_info() {
    local vmid="$1"
    local hostname="$2"
    local password="$3"
    
    local info_dir="/root/.lxc-info"
    mkdir -p "$info_dir"
    
    cat > "$info_dir/${vmid}-${hostname}.txt" << EOF
# LXC Container Information
Created: $(date '+%Y-%m-%d %H:%M:%S')
VMID: $vmid
Hostname: $hostname
Root Password: $password
IP: $(pct exec "$vmid" -- hostname -I 2>/dev/null | awk '{print $1}')
EOF

    chmod 600 "$info_dir/${vmid}-${hostname}.txt"
    log_info "Container-Info gespeichert: $info_dir/${vmid}-${hostname}.txt"
}

# =============================================================================
# DOCKER-LXC SPEZIAL
# =============================================================================

prepare_docker_lxc() {
    local vmid="$1"
    
    log_step "Bereite LXC für Docker vor..."
    
    # Nesting aktivieren (falls noch nicht)
    pct set "$vmid" --features nesting=1
    
    # Zusätzliche Konfiguration für Docker
    local config_file="/etc/pve/lxc/${vmid}.conf"
    
    # Backup der Config
    cp "$config_file" "${config_file}.bak"
    
    # Füge Docker-spezifische Settings hinzu
    cat >> "$config_file" << 'EOF'

# Docker-spezifische Konfiguration
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF
    
    # Container neustarten
    pct stop "$vmid"
    sleep 2
    pct start "$vmid"
    
    wait_for_lxc "$vmid"
    
    log_success "LXC für Docker vorbereitet"
}
