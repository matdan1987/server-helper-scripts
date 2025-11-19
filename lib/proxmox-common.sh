#!/usr/bin/env bash
# proxmox-common.sh - Proxmox-spezifische Funktionen
# Version: 1.1.0

# =============================================================================
# IP-ADRESS-SCHEMA
# =============================================================================

# Basis-Netzwerk
IP_BASE="192.168.178"

# ID-Ranges
LXC_ID_START=100
LXC_ID_END=199
VM_ID_START=200
VM_ID_END=299

# Gateway (Router)
GATEWAY="${IP_BASE}.1"
NETMASK="24"

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
# INTELLIGENTE IP-ZUWEISUNG
# =============================================================================

vmid_to_ip() {
    local vmid="$1"
    echo "${IP_BASE}.${vmid}"
}

ip_to_vmid() {
    local ip="$1"
    echo "${ip##*.}"
}

get_ip_for_vmid() {
    local vmid="$1"
    local ip="${IP_BASE}.${vmid}"
    
    # Validierung
    if [[ $vmid -lt 100 ]] || [[ $vmid -gt 299 ]]; then
        log_warn "VMID $vmid außerhalb des empfohlenen Bereichs (100-299)"
    fi
    
    echo "$ip"
}

is_ip_available() {
    local ip="$1"
    ! ping -c 1 -W 1 "$ip" &>/dev/null
}

validate_vmid_range() {
    local vmid="$1"
    local type="$2"  # lxc oder vm
    
    case "$type" in
        lxc)
            if [[ $vmid -lt $LXC_ID_START ]] || [[ $vmid -gt $LXC_ID_END ]]; then
                log_warn "LXC-VMID sollte zwischen $LXC_ID_START und $LXC_ID_END liegen"
                return 1
            fi
            ;;
        vm)
            if [[ $vmid -lt $VM_ID_START ]] || [[ $vmid -gt $VM_ID_END ]]; then
                log_warn "VM-VMID sollte zwischen $VM_ID_START und $VM_ID_END liegen"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# =============================================================================
# CONTAINER-ID-MANAGEMENT
# =============================================================================

get_next_vmid() {
    local type="${1:-lxc}"  # lxc oder vm
    local start end
    
    case "$type" in
        lxc)
            start=$LXC_ID_START
            end=$LXC_ID_END
            ;;
        vm)
            start=$VM_ID_START
            end=$VM_ID_END
            ;;
        *)
            start=100
            end=999
            ;;
    esac
    
    for vmid in $(seq $start $end); do
        if ! pct status "$vmid" &>/dev/null && ! qm status "$vmid" &>/dev/null; then
            echo "$vmid"
            return 0
        fi
    done
    
    die "Keine freie VMID im Bereich $start-$end gefunden!" 1
}

vmid_exists() {
    local vmid="$1"
    pct status "$vmid" &>/dev/null || qm status "$vmid" &>/dev/null
}

get_vmid_type() {
    local vmid="$1"
    
    if pct status "$vmid" &>/dev/null; then
        echo "lxc"
    elif qm status "$vmid" &>/dev/null; then
        echo "vm"
    else
        echo "none"
    fi
}

# =============================================================================
# NETZWERK-KONFIGURATION
# =============================================================================

get_network_config_for_vmid() {
    local vmid="$1"
    local bridge="${2:-vmbr0}"
    
    local ip=$(get_ip_for_vmid "$vmid")
    local cidr="${ip}/${NETMASK}"
    
    echo "ip=${cidr},gw=${GATEWAY}"
}

create_network_string() {
    local vmid="$1"
    local bridge="${2:-vmbr0}"
    local interface="${3:-eth0}"
    
    local ip=$(get_ip_for_vmid "$vmid")
    local cidr="${ip}/${NETMASK}"
    
    echo "name=${interface},bridge=${bridge},ip=${cidr},gw=${GATEWAY},firewall=1"
}

# =============================================================================
# IP-ÜBERSICHT & MANAGEMENT
# =============================================================================

show_ip_allocation() {
    log_info "IP-Adress-Schema:"
    echo
    echo "  Netzwerk:     ${IP_BASE}.0/${NETMASK}"
    echo "  Gateway:      ${GATEWAY}"
    echo
    echo "  LXC-Bereich:  ${IP_BASE}.${LXC_ID_START} - ${IP_BASE}.${LXC_ID_END}"
    echo "  VM-Bereich:   ${IP_BASE}.${VM_ID_START} - ${IP_BASE}.${VM_ID_END}"
    echo
    echo "  Beispiele:"
    echo "    LXC 100  →  ${IP_BASE}.100"
    echo "    LXC 150  →  ${IP_BASE}.150"
    echo "    VM  200  →  ${IP_BASE}.200"
    echo "    VM  250  →  ${IP_BASE}.250"
    echo
}

list_allocated_ips() {
    log_step "Belegte IPs..."
    echo
    
    # LXCs
    log_info "LXC Container:"
    for vmid in $(seq $LXC_ID_START $LXC_ID_END); do
        if pct status "$vmid" &>/dev/null; then
            local hostname=$(pct config "$vmid" | grep -oP 'hostname: \K.*' || echo "unknown")
            local ip=$(get_ip_for_vmid "$vmid")
            local status=$(pct status "$vmid" | awk '{print $2}')
            printf "  %-4s  %-15s  %-20s  %s\n" "$vmid" "$ip" "$hostname" "[$status]"
        fi
    done
    
    echo
    
    # VMs
    log_info "Virtual Machines:"
    for vmid in $(seq $VM_ID_START $VM_ID_END); do
        if qm status "$vmid" &>/dev/null; then
            local name=$(qm config "$vmid" | grep -oP 'name: \K.*' || echo "unknown")
            local ip=$(get_ip_for_vmid "$vmid")
            local status=$(qm status "$vmid" | awk '{print $2}')
            printf "  %-4s  %-15s  %-20s  %s\n" "$vmid" "$ip" "$name" "[$status]"
        fi
    done
    
    echo
}

check_ip_conflicts() {
    log_step "Prüfe IP-Konflikte..."
    
    local conflicts=0
    
    # Prüfe alle VMIDs
    for vmid in $(seq 100 299); do
        if vmid_exists "$vmid"; then
            local expected_ip=$(get_ip_for_vmid "$vmid")
            
            # Hole tatsächliche IP aus Config
            local type=$(get_vmid_type "$vmid")
            local actual_ip=""
            
            if [[ "$type" == "lxc" ]]; then
                actual_ip=$(pct config "$vmid" | grep -oP 'ip=\K[0-9.]+(?=/|,)' | head -1)
            elif [[ "$type" == "vm" ]]; then
                actual_ip=$(qm config "$vmid" | grep -oP 'ip=\K[0-9.]+(?=/|,)' | head -1)
            fi
            
            if [[ -n "$actual_ip" ]] && [[ "$actual_ip" != "$expected_ip" ]]; then
                log_warn "Konflikt bei VMID $vmid: Erwartet $expected_ip, gefunden $actual_ip"
                conflicts=$((conflicts + 1))
            fi
        fi
    done
    
    if [[ $conflicts -eq 0 ]]; then
        log_success "Keine IP-Konflikte gefunden"
    else
        log_warn "$conflicts Konflikte gefunden"
    fi
    
    return $conflicts
}

# =============================================================================
# STORAGE-FUNKTIONEN
# =============================================================================

get_storage_list() {
    pvesm status | tail -n +2 | awk '{print $1}'
}

get_best_storage() {
    local type="${1:-dir}"
    
    local storages=("local-lvm" "local-zfs" "local")
    
    for storage in "${storages[@]}"; do
        if pvesm status | grep -q "^$storage"; then
            echo "$storage"
            return 0
        fi
    done
    
    get_storage_list | head -1
}

# =============================================================================
# TEMPLATE-MANAGEMENT
# =============================================================================

get_latest_debian_template() {
    pveam available | grep 'debian-12' | grep 'standard' | tail -1 | awk '{print $2}'
}

get_latest_ubuntu_template() {
    pveam available | grep 'ubuntu-22.04' | grep 'standard' | tail -1 | awk '{print $2}'
}

template_exists() {
    local template="$1"
    local storage="${2:-local}"
    pveam list "$storage" | grep -q "$template"
}

download_template() {
    local template="$1"
    local storage="${2:-local}"
    
    log_info "Lade Template herunter: $template"
    pveam download "$storage" "$template"
}

# =============================================================================
# LXC-HELPERS
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

lxc_install_package() {
    local vmid="$1"
    shift
    local packages=("$@")
    
    log_info "Installiere in LXC $vmid: ${packages[*]}"
    
    lxc_exec "$vmid" bash -c "
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${packages[*]}
    "
}

# =============================================================================
# DOCKER-LXC VORBEREITUNG
# =============================================================================

prepare_docker_lxc() {
    local vmid="$1"
    
    log_step "Bereite LXC für Docker vor..."
    
    pct set "$vmid" --features nesting=1
    
    local config_file="/etc/pve/lxc/${vmid}.conf"
    cp "$config_file" "${config_file}.bak"
    
    cat >> "$config_file" << 'EOF'

# Docker-spezifische Konfiguration
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF
    
    pct stop "$vmid"
    sleep 2
    pct start "$vmid"
    
    wait_for_lxc "$vmid"
    
    log_success "LXC für Docker vorbereitet"
}

# =============================================================================
# RESSOURCEN-BERECHNUNG
# =============================================================================

calculate_lxc_memory() {
    local service_type="$1"
    
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
