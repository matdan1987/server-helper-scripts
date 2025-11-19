#!/usr/bin/env bash
# proxmox-common.sh - Proxmox-spezifische Funktionen
# Version: 1.0.0

# =============================================================================
# PROXMOX-PRÜFUNGEN
# =============================================================================

is_proxmox_host() {
    [[ -f /etc/pve/local/pve-ssl.pem ]]
}

require_proxmox() {
    if ! is_proxmox_host; then
        die "Dieses Script muss auf einem Proxmox VE Host ausgeführt werden!" 1
    fi
}

get_pve_version() {
    pveversion | grep -oP 'pve-manager/\K[0-9.]+' | head -1
}

# =============================================================================
# STORAGE-FUNKTIONEN
# =============================================================================

get_storage_list() {
    pvesm status | tail -n +2 | awk '{print $1}'
}

get_best_storage() {
    local type="${1:-dir}"  # dir, lvm, zfs, etc.
    
    # Bevorzugte Reihenfolge
    local storages=("local-lvm" "local-zfs" "local")
    
    for storage in "${storages[@]}"; do
        if pvesm status | grep -q "^$storage"; then
            echo "$storage"
            return 0
        fi
    done
    
    # Fallback: ersten verfügbaren Storage
    get_storage_list | head -1
}

get_storage_free_space() {
    local storage="$1"
    pvesm status | grep "^$storage" | awk '{print $4}'
}

# =============================================================================
# NETZWERK-FUNKTIONEN
# =============================================================================

get_bridge_list() {
    ip -br link | grep -E '^vmbr' | awk '{print $1}'
}

get_default_bridge() {
    echo "vmbr0"  # Standard Proxmox Bridge
}

get_next_free_ip() {
    local subnet="${1:-192.168.1}"
    local start="${2:-100}"
    local end="${3:-200}"
    
    for i in $(seq $start $end); do
        local ip="${subnet}.${i}"
        if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# =============================================================================
# CONTAINER-ID-MANAGEMENT
# =============================================================================

get_next_vmid() {
    local start="${1:-100}"
    local max="${2:-999}"
    
    for vmid in $(seq $start $max); do
        if ! pct status "$vmid" &>/dev/null && ! qm status "$vmid" &>/dev/null; then
            echo "$vmid"
            return 0
        fi
    done
    
    die "Keine freie VMID gefunden!" 1
}

vmid_exists() {
    local vmid="$1"
    pct status "$vmid" &>/dev/null || qm status "$vmid" &>/dev/null
}

# =============================================================================
# TEMPLATE-MANAGEMENT
# =============================================================================

get_available_templates() {
    pveam available | tail -n +2
}

download_template() {
    local template="$1"
    local storage="${2:-local}"
    
    log_info "Lade Template herunter: $template"
    pveam download "$storage" "$template"
}

template_exists() {
    local template="$1"
    local storage="${2:-local}"
    
    pveam list "$storage" | grep -q "$template"
}

get_latest_debian_template() {
    pveam available | grep 'debian-12' | grep 'standard' | tail -1 | awk '{print $2}'
}

get_latest_ubuntu_template() {
    pveam available | grep 'ubuntu-22.04' | grep 'standard' | tail -1 | awk '{print $2}'
}

# =============================================================================
# LXC-FUNKTIONEN
# =============================================================================

wait_for_lxc() {
    local vmid="$1"
    local max_wait="${2:-60}"
    local count=0
    
    log_info "Warte bis LXC $vmid bereit ist..."
    
    while [[ $count -lt $max_wait ]]; do
        if pct status "$vmid" | grep -q "running"; then
            if pct exec "$vmid" -- test -f /usr/bin/systemctl 2>/dev/null; then
                log_success "LXC $vmid ist bereit"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    
    log_error "Timeout beim Warten auf LXC $vmid"
    return 1
}

lxc_exec() {
    local vmid="$1"
    shift
    pct exec "$vmid" -- "$@"
}

lxc_push() {
    local vmid="$1"
    local source="$2"
    local dest="$3"
    
    pct push "$vmid" "$source" "$dest"
}

lxc_install_package() {
    local vmid="$1"
    shift
    local packages=("$@")
    
    log_info "Installiere in LXC $vmid: ${packages[*]}"
    
    lxc_exec "$vmid" bash -c "
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y ${packages[*]}
    "
}

# =============================================================================
# VM-FUNKTIONEN
# =============================================================================

wait_for_vm() {
    local vmid="$1"
    local max_wait="${2:-120}"
    local count=0
    
    log_info "Warte bis VM $vmid bereit ist..."
    
    while [[ $count -lt $max_wait ]]; do
        if qm status "$vmid" | grep -q "running"; then
            log_success "VM $vmid läuft"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    log_error "Timeout beim Warten auf VM $vmid"
    return 1
}

# =============================================================================
# RESSOURCEN-BERECHNUNG
# =============================================================================

get_host_memory_mb() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

get_host_cpu_cores() {
    nproc
}

calculate_lxc_memory() {
    local service_type="$1"
    local host_memory=$(get_host_memory_mb)
    
    case "$service_type" in
        minimal)      echo "512" ;;
        small)        echo "1024" ;;
        medium)       echo "2048" ;;
        large)        echo "4096" ;;
        docker)       echo "4096" ;;
        code-server)  echo "2048" ;;
        nginx)        echo "512" ;;
        n8n)          echo "2048" ;;
        *)            echo "1024" ;;
    esac
}

calculate_lxc_disk() {
    local service_type="$1"
    
    case "$service_type" in
        minimal)      echo "4" ;;
        small)        echo "8" ;;
        medium)       echo "16" ;;
        large)        echo "32" ;;
        docker)       echo "100" ;;
        code-server)  echo "20" ;;
        nginx)        echo "8" ;;
        n8n)          echo "10" ;;
        *)            echo "8" ;;
    esac
}

calculate_lxc_cores() {
    local service_type="$1"
    local host_cores=$(get_host_cpu_cores)
    
    case "$service_type" in
        minimal)      echo "1" ;;
        small)        echo "1" ;;
        medium)       echo "2" ;;
        large)        echo "4" ;;
        docker)       echo "4" ;;
        code-server)  echo "2" ;;
        nginx)        echo "1" ;;
        n8n)          echo "2" ;;
        *)            echo "1" ;;
    esac
}
