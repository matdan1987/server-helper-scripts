#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox IP-Map Anzeigen
# Beschreibung: Zeigt Übersicht aller Container/VMs mit ihren IPs und Status
# Autor: matdan1987
# Version: 1.2.0
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
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Proxmox IP-Übersicht"
    echo
}

show_network_schema() {
    log_info "IP-Adress-Schema"
    echo
    echo "  Netzwerk:     ${IP_BASE}.0/${NETMASK}"
    echo "  Gateway:      ${GATEWAY}"
    echo "  LXC-Bereich:  ${IP_BASE}.${LXC_ID_START}-${LXC_ID_END}"
    echo "  VM-Bereich:   ${IP_BASE}.${VM_ID_START}-${VM_ID_END}"
    echo "  Schema:       VMID = IP (z.B. VMID 150 = ${IP_BASE}.150)"
    echo
}

count_resources() {
    log_info "Ressourcen-Übersicht"
    echo
    
    local lxc_count=$(pct list 2>/dev/null | tail -n +2 | wc -l)
    local vm_count=$(qm list 2>/dev/null | tail -n +2 | wc -l)
    local lxc_running=$(pct list 2>/dev/null | grep -c "running" || echo 0)
    local vm_running=$(qm list 2>/dev/null | grep -c "running" || echo 0)
    
    echo "  LXC Container:  $lxc_count gesamt ($lxc_running laufend)"
    echo "  VMs:            $vm_count gesamt ($vm_running laufend)"
    echo "  Total:          $((lxc_count + vm_count)) Container/VMs"
    echo
}

get_container_ip() {
    local vmid="$1"
    local type="$2"
    
    if [[ "$type" == "lxc" ]]; then
        local config_ip=$(pct config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+' | head -1)
        if [[ -n "$config_ip" ]]; then
            echo "$config_ip"
            return 0
        fi
    elif [[ "$type" == "vm" ]]; then
        local config_ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+' | head -1)
        if [[ -n "$config_ip" ]]; then
            echo "$config_ip"
            return 0
        fi
    fi
    
    echo "$(get_ip_for_vmid "$vmid")"
}

show_lxc_containers() {
    log_info "LXC Container"
    echo
    
    local lxc_list=$(pct list 2>/dev/null | tail -n +2)
    
    if [[ -z "$lxc_list" ]]; then
        echo "  Keine LXC Container gefunden"
        echo
        return
    fi
    
    printf "  %-6s %-18s %-25s %-10s %-8s %-8s\n" "VMID" "IP" "HOSTNAME" "STATUS" "MEMORY" "DISK"
    printf "  %-6s %-18s %-25s %-10s %-8s %-8s\n" "------" "------------------" "-------------------------" "----------" "--------" "--------"
    
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $2}')
        local hostname=$(echo "$line" | awk '{print $3}')
        
        local ip=$(get_container_ip "$vmid" "lxc")
        local memory=$(pct config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "?")
        local disk=$(pct config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+G' | head -1 || echo "?")
        
        local expected_ip=$(get_ip_for_vmid "$vmid")
        local ip_display="$ip"
        if [[ "$ip" != "$expected_ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+ ]]; then
            ip_display="${ip} (*)"
        fi
        
        printf "  %-6s %-18s %-25s %-10s %-8s %-8s\n" "$vmid" "$ip_display" "${hostname:0:25}" "$status" "${memory}MB" "$disk"
    done <<< "$lxc_list"
    
    echo
}

show_vms() {
    log_info "Virtual Machines"
    echo
    
    local vm_list=$(qm list 2>/dev/null | tail -n +2)
    
    if [[ -z "$vm_list" ]]; then
        echo "  Keine VMs gefunden"
        echo
        return
    fi
    
    printf "  %-6s %-18s %-25s %-10s %-8s %-8s\n" "VMID" "IP" "NAME" "STATUS" "MEMORY" "DISK"
    printf "  %-6s %-18s %-25s %-10s %-8s %-8s\n" "------" "------------------" "-------------------------" "----------" "--------" "--------"
    
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        
        local ip=$(get_container_ip "$vmid" "vm")
        local memory=$(qm config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "?")
        local disk=$(qm config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+G' | head -1 || echo "?")
        
        printf "  %-6s %-18s %-25s %-10s %-8s %-8s\n" "$vmid" "$ip" "${name:0:25}" "$status" "${memory}MB" "$disk"
    done <<< "$vm_list"
    
    echo
}

check_ip_conflicts() {
    log_info "IP-Konflikt-Prüfung"
    echo
    
    local conflicts=0
    
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        [[ -z "$vmid" ]] && continue
        
        local expected_ip=$(get_ip_for_vmid "$vmid")
        local actual_ip=$(pct config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+' | head -1 || echo "")
        
        if [[ -n "$actual_ip" ]] && [[ "$actual_ip" =~ ^192\.168\.178\. ]]; then
            if [[ "$actual_ip" != "$expected_ip" ]]; then
                echo "  Warnung: LXC $vmid hat $actual_ip (erwartet: $expected_ip)"
                conflicts=$((conflicts + 1))
            fi
        fi
    done < <(pct list 2>/dev/null | tail -n +2 || true)
    
    if [[ $conflicts -eq 0 ]]; then
        echo "  Keine Konflikte gefunden"
    fi
    
    echo
}

show_free_ranges() {
    log_info "Freie IDs"
    echo
    
    local existing_lxc=$(pct list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n || echo "")
    
    echo "  Naechste freie LXC-IDs:"
    local count=0
    for vmid in $(seq $LXC_ID_START $LXC_ID_END); do
        if ! echo "$existing_lxc" | grep -q "^${vmid}$"; then
            local ip=$(get_ip_for_vmid "$vmid")
            printf "    VMID %-4s -> IP %s\n" "$vmid" "$ip"
            count=$((count + 1))
            [[ $count -ge 5 ]] && break
        fi
    done
    [[ $count -eq 0 ]] && echo "    Keine freien IDs"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    require_proxmox
    
    show_banner
    show_network_schema
    count_resources
    show_lxc_containers
    show_vms
    check_ip_conflicts
    show_free_ranges
    
    log_success "IP-Uebersicht abgeschlossen"
}

set +e
trap '' ERR

main "$@"
