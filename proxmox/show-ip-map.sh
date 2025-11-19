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
    log_info "═══════════════════════════════════════════════════════"
    log_info "  IP-Adress-Schema"
    log_info "═══════════════════════════════════════════════════════"
    echo
    echo "  Netzwerk:     ${IP_BASE}.0/${NETMASK}"
    echo "  Gateway:      ${GATEWAY}"
    echo
    echo "  LXC-Bereich:  ${IP_BASE}.${LXC_ID_START}-${LXC_ID_END}  (Container 100-199)"
    echo "  VM-Bereich:   ${IP_BASE}.${VM_ID_START}-${VM_ID_END}  (VMs 200-299)"
    echo
    echo "  Schema:       VMID = letzte IP-Stelle"
    echo "                z.B. VMID 150 → ${IP_BASE}.150"
    echo
}

count_resources() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "  Ressourcen-Übersicht"
    log_info "═══════════════════════════════════════════════════════"
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
        local config_ip=$(pct config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+(?=/|,)' | head -1)
        if [[ -n "$config_ip" ]]; then
            echo "$config_ip"
            return 0
        fi
        
        if pct status "$vmid" 2>/dev/null | grep -q "running"; then
            local running_ip=$(pct exec "$vmid" -- hostname -I 2>/dev/null | awk '{print $1}')
            if [[ -n "$running_ip" ]]; then
                echo "$running_ip"
                return 0
            fi
        fi
    elif [[ "$type" == "vm" ]]; then
        local config_ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+(?=/|,)' | head -1)
        if [[ -n "$config_ip" ]]; then
            echo "$config_ip"
            return 0
        fi
    fi
    
    echo "$(get_ip_for_vmid "$vmid")"
}

show_lxc_containers() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "  LXC Container"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    local lxc_list=$(pct list 2>/dev/null | tail -n +2)
    
    if [[ -z "$lxc_list" ]]; then
        echo "  ${YELLOW}Keine LXC Container gefunden${NC}"
        echo
        return
    fi
    
    printf "  %-6s %-18s %-25s %-12s %-8s %s\n" "VMID" "IP" "HOSTNAME" "STATUS" "MEMORY" "DISK"
    printf "  %-6s %-18s %-25s %-12s %-8s %s\n" "------" "------------------" "-------------------------" "------------" "--------" "--------"
    
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $2}')
        local hostname=$(echo "$line" | awk '{print $3}')
        
        local ip=$(get_container_ip "$vmid" "lxc")
        local memory=$(pct config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "?")
        local disk=$(pct config "$vmid" 2>/dev/null | grep -oP 'rootfs.*size=\K[0-9]+G' || echo "?")
        
        local status_display
        case "$status" in
            running) status_display="${GREEN}running${NC}" ;;
            stopped) status_display="${RED}stopped${NC}" ;;
            *) status_display="${YELLOW}${status}${NC}" ;;
        esac
        
        local expected_ip=$(get_ip_for_vmid "$vmid")
        local ip_display="$ip"
        if [[ "$ip" != "$expected_ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip_display="${YELLOW}${ip} (!${expected_ip})${NC}"
        fi
        
        printf "  %-6s %-18s %-25s %-20s %-8s %s\n" \
            "$vmid" \
            "$ip_display" \
            "${hostname:0:25}" \
            "$status_display" \
            "${memory}MB" \
            "$disk"
    done <<< "$lxc_list"
    
    echo
}

show_vms() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "  Virtual Machines"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    local vm_list=$(qm list 2>/dev/null | tail -n +2)
    
    if [[ -z "$vm_list" ]]; then
        echo "  ${YELLOW}Keine VMs gefunden${NC}"
        echo
        return
    fi
    
    printf "  %-6s %-18s %-25s %-12s %-8s %s\n" "VMID" "IP" "NAME" "STATUS" "MEMORY" "DISK"
    printf "  %-6s %-18s %-25s %-12s %-8s %s\n" "------" "------------------" "-------------------------" "------------" "--------" "--------"
    
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        
        local ip=$(get_container_ip "$vmid" "vm")
        local memory=$(qm config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "?")
        local disk=$(qm config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+G' | head -1 || echo "?")
        
        local status_display
        case "$status" in
            running) status_display="${GREEN}running${NC}" ;;
            stopped) status_display="${RED}stopped${NC}" ;;
            *) status_display="${YELLOW}${status}${NC}" ;;
        esac
        
        local expected_ip=$(get_ip_for_vmid "$vmid")
        local ip_display="$ip"
        if [[ "$ip" != "$expected_ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip_display="${YELLOW}${ip} (!${expected_ip})${NC}"
        fi
        
        printf "  %-6s %-18s %-25s %-20s %-8s %s\n" \
            "$vmid" \
            "$ip_display" \
            "${name:0:25}" \
            "$status_display" \
            "${memory}MB" \
            "$disk"
    done <<< "$vm_list"
    
    echo
}

check_ip_conflicts() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "  IP-Konflikt-Prüfung"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    local conflicts=0
    local warnings=()
    
    # Prüfe LXCs (mit Error-Handling)
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        [[ -z "$vmid" ]] && continue
        
        local expected_ip=$(get_ip_for_vmid "$vmid")
        local actual_ip=$(pct config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+(?=/|,)' | head -1 || echo "")
        
        # Nur prüfen wenn IP im lokalen Netz
        if [[ -n "$actual_ip" ]] && [[ "$actual_ip" =~ ^192\.168\.178\. ]]; then
            if [[ "$actual_ip" != "$expected_ip" ]]; then
                warnings+=("  ${YELLOW}⚠${NC}  LXC $vmid: Erwartet $expected_ip, gefunden $actual_ip")
                conflicts=$((conflicts + 1))
            fi
        fi
        
        # VMID-Range-Prüfung
        if [[ $vmid -lt $LXC_ID_START ]] || [[ $vmid -gt $LXC_ID_END ]]; then
            warnings+=("  ${YELLOW}⚠${NC}  LXC $vmid außerhalb empfohlenem Bereich ($LXC_ID_START-$LXC_ID_END)")
        fi
    done < <(pct list 2>/dev/null | tail -n +2 || true)
    
    # Prüfe VMs (mit Error-Handling)
    while read -r line; do
        local vmid=$(echo "$line" | awk '{print $1}')
        [[ -z "$vmid" ]] && continue
        
        local expected_ip=$(get_ip_for_vmid "$vmid")
        local actual_ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+(?=/|,)' | head -1 || echo "")
        
        if [[ -n "$actual_ip" ]] && [[ "$actual_ip" =~ ^192\.168\.178\. ]]; then
            if [[ "$actual_ip" != "$expected_ip" ]]; then
                warnings+=("  ${YELLOW}⚠${NC}  VM $vmid: Erwartet $expected_ip, gefunden $actual_ip")
                conflicts=$((conflicts + 1))
            fi
        fi
        
        if [[ $vmid -lt $VM_ID_START ]] || [[ $vmid -gt $VM_ID_END ]]; then
            warnings+=("  ${YELLOW}⚠${NC}  VM $vmid außerhalb empfohlenem Bereich ($VM_ID_START-$VM_ID_END)")
        fi
    done < <(qm list 2>/dev/null | tail -n +2 || true)
    
    if [[ $conflicts -eq 0 ]] && [[ ${#warnings[@]} -eq 0 ]]; then
        echo "  ${GREEN}✓${NC} Keine Konflikte oder Warnungen gefunden"
    else
        if [[ $conflicts -gt 0 ]]; then
            echo "  ${RED}✗${NC} $conflicts IP-Konflikte gefunden:"
            echo
        fi
        
        for warning in "${warnings[@]}"; do
            echo "$warning"
        done
    fi
    
    echo
}

show_free_ranges() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "  Freie IDs/IPs"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    local existing_lxc=$(pct list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n || echo "")
    local existing_vm=$(qm list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n || echo "")
    
    echo "  Nächste freie LXC-IDs:"
    local count=0
    for vmid in $(seq $LXC_ID_START $LXC_ID_END); do
        if ! echo "$existing_lxc" | grep -q "^${vmid}$"; then
            local ip=$(get_ip_for_vmid "$vmid")
            printf "    VMID %-4s → IP %s\n" "$vmid" "$ip"
            count=$((count + 1))
            [[ $count -ge 5 ]] && break
        fi
    done
    [[ $count -eq 0 ]] && echo "    ${YELLOW}Keine freien IDs im Bereich${NC}"
    echo
    
    echo "  Nächste freie VM-IDs:"
    count=0
    for vmid in $(seq $VM_ID_START $VM_ID_END); do
        if ! echo "$existing_vm" | grep -q "^${vmid}$"; then
            local ip=$(get_ip_for_vmid "$vmid")
            printf "    VMID %-4s → IP %s\n" "$vmid" "$ip"
            count=$((count + 1))
            [[ $count -ge 5 ]] && break
        fi
    done
    [[ $count -eq 0 ]] && echo "    ${YELLOW}Keine freien IDs im Bereich${NC}"
    echo
}

show_quick_access() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "  Schnellzugriff-Befehle"
    log_info "═══════════════════════════════════════════════════════"
    echo
    echo "  LXC:"
    echo "    pct list                    # Alle Container"
    echo "    pct enter <vmid>            # Shell im Container"
    echo "    pct status <vmid>           # Status anzeigen"
    echo "    pct start/stop <vmid>       # Start/Stop"
    echo
    echo "  VM:"
    echo "    qm list                     # Alle VMs"
    echo "    qm status <vmid>            # Status anzeigen"
    echo "    qm start/stop <vmid>        # Start/Stop"
    echo
    echo "  Neue Container erstellen:"
    echo "    bash <(curl -fsSL https://raw.githubusercontent.com/matdan1987/server-helper-scripts/main/lxc/create-docker-lxc.sh)"
    echo "    bash <(curl -fsSL https://raw.githubusercontent.com/matdan1987/server-helper-scripts/main/lxc/create-nginx-proxy-lxc.sh)"
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
    show_quick_access
    
    log_success "IP-Übersicht abgeschlossen"
}

# Entferne striktes Error-Handling für dieses Script
set +e
trap '' ERR

main "$@"
