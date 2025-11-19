#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox IP-Map Anzeigen
# Beschreibung: Zeigt Übersicht aller Container/VMs mit ihren IPs und Status
# Autor: matdan1987
# Version: 2.0.0
# Features: Farbcodierung, CSV/JSON Export, Interaktive Verwaltung, Ping-Tests
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

format_status() {
    local status="$1"
    case "$status" in
        running)
            echo -e "${GREEN}${status}${NC}"
            ;;
        stopped)
            echo -e "${RED}${status}${NC}"
            ;;
        paused)
            echo -e "${YELLOW}${status}${NC}"
            ;;
        *)
            echo -e "${NC}${status}${NC}"
            ;;
    esac
}

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

    # Prüfe ob Container/VM existiert
    if [[ "$type" == "lxc" ]]; then
        if ! pct status "$vmid" &>/dev/null; then
            echo "N/A"
            return 1
        fi
        local config_ip=$(pct config "$vmid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+' | head -1)
        if [[ -n "$config_ip" ]]; then
            echo "$config_ip"
            return 0
        fi
    elif [[ "$type" == "vm" ]]; then
        if ! qm status "$vmid" &>/dev/null; then
            echo "N/A"
            return 1
        fi
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

    local lxc_list=$(pct list 2>/dev/null | tail -n +2 | sort -n -k1)

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

        local status_colored=$(format_status "$status")
        printf "  %-6s %-18s %-25s %-22s %-8s %-8s\n" "$vmid" "$ip_display" "${hostname:0:25}" "$status_colored" "${memory}MB" "$disk"
    done <<< "$lxc_list"

    echo
}

show_vms() {
    log_info "Virtual Machines"
    echo

    local vm_list=$(qm list 2>/dev/null | tail -n +2 | sort -n -k1)

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

        local status_colored=$(format_status "$status")
        printf "  %-6s %-18s %-25s %-22s %-8s %-8s\n" "$vmid" "$ip" "${name:0:25}" "$status_colored" "${memory}MB" "$disk"
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

        if [[ -n "$actual_ip" ]] && [[ "$actual_ip" =~ ^${IP_BASE//./\\.}\. ]]; then
            if [[ "$actual_ip" != "$expected_ip" ]]; then
                echo "  Warnung: LXC $vmid hat $actual_ip (erwartet: $expected_ip)"
                conflicts=$((conflicts + 1))
            fi
        fi
    done < <(pct list 2>/dev/null | tail -n +2 || true)

    if [[ $conflicts -eq 0 ]]; then
        echo "  Keine Konflikte gefunden"
    else
        log_warn "$conflicts IP-Konflikte gefunden"
    fi

    echo
}

show_free_ranges() {
    log_info "Freie IDs"
    echo

    # Sammle alle verwendeten VMIDs (LXC + VMs)
    local existing_vmids=$(
        {
            pct list 2>/dev/null | tail -n +2 | awk '{print $1}'
            qm list 2>/dev/null | tail -n +2 | awk '{print $1}'
        } | sort -n -u
    )

    echo "  Naechste freie LXC-IDs:"
    local count=0
    for vmid in $(seq $LXC_ID_START $LXC_ID_END); do
        if ! echo "$existing_vmids" | grep -q "^${vmid}$"; then
            local ip=$(get_ip_for_vmid "$vmid")
            printf "    VMID %-4s -> IP %s\n" "$vmid" "$ip"
            count=$((count + 1))
            [[ $count -ge 5 ]] && break
        fi
    done

    if [[ $count -eq 0 ]]; then
        echo "    Keine freien IDs"
    fi
    echo
}

export_csv() {
    local output_file="${1:-/tmp/proxmox-ip-map-$(date +%Y%m%d-%H%M%S).csv}"

    log_info "Exportiere nach CSV: $output_file"

    {
        echo "TYPE,VMID,NAME,IP,STATUS,MEMORY_MB,DISK_GB"

        # LXC Container
        local lxc_list=$(pct list 2>/dev/null | tail -n +2 | sort -n -k1)
        while read -r line; do
            [[ -z "$line" ]] && continue
            local vmid=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{print $2}')
            local hostname=$(echo "$line" | awk '{print $3}')
            local ip=$(get_container_ip "$vmid" "lxc")
            local memory=$(pct config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "0")
            local disk=$(pct config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+' | head -1 || echo "0")

            echo "LXC,$vmid,$hostname,$ip,$status,$memory,$disk"
        done <<< "$lxc_list"

        # VMs
        local vm_list=$(qm list 2>/dev/null | tail -n +2 | sort -n -k1)
        while read -r line; do
            [[ -z "$line" ]] && continue
            local vmid=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            local status=$(echo "$line" | awk '{print $3}')
            local ip=$(get_container_ip "$vmid" "vm")
            local memory=$(qm config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "0")
            local disk=$(qm config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+' | head -1 || echo "0")

            echo "VM,$vmid,$name,$ip,$status,$memory,$disk"
        done <<< "$vm_list"
    } > "$output_file"

    log_success "CSV Export abgeschlossen: $output_file"
}

export_json() {
    local output_file="${1:-/tmp/proxmox-ip-map-$(date +%Y%m%d-%H%M%S).json}"

    log_info "Exportiere nach JSON: $output_file"

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"network\": {"
        echo "    \"base\": \"${IP_BASE}\","
        echo "    \"gateway\": \"${GATEWAY}\","
        echo "    \"netmask\": \"${NETMASK}\""
        echo "  },"
        echo "  \"containers\": ["

        # LXC Container
        local lxc_list=$(pct list 2>/dev/null | tail -n +2 | sort -n -k1)
        local first=true
        while read -r line; do
            [[ -z "$line" ]] && continue
            local vmid=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{print $2}')
            local hostname=$(echo "$line" | awk '{print $3}')
            local ip=$(get_container_ip "$vmid" "lxc")
            local memory=$(pct config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "0")
            local disk=$(pct config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+' | head -1 || echo "0")

            [[ "$first" == false ]] && echo ","
            first=false

            echo -n "    {\"type\": \"lxc\", \"vmid\": $vmid, \"name\": \"$hostname\", \"ip\": \"$ip\", \"status\": \"$status\", \"memory_mb\": $memory, \"disk_gb\": $disk}"
        done <<< "$lxc_list"

        # VMs
        local vm_list=$(qm list 2>/dev/null | tail -n +2 | sort -n -k1)
        while read -r line; do
            [[ -z "$line" ]] && continue
            local vmid=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            local status=$(echo "$line" | awk '{print $3}')
            local ip=$(get_container_ip "$vmid" "vm")
            local memory=$(qm config "$vmid" 2>/dev/null | grep -oP 'memory: \K[0-9]+' || echo "0")
            local disk=$(qm config "$vmid" 2>/dev/null | grep -oP 'size=\K[0-9]+' | head -1 || echo "0")

            [[ "$first" == false ]] && echo ","
            first=false

            echo -n "    {\"type\": \"vm\", \"vmid\": $vmid, \"name\": \"$name\", \"ip\": \"$ip\", \"status\": \"$status\", \"memory_mb\": $memory, \"disk_gb\": $disk}"
        done <<< "$vm_list"

        echo ""
        echo "  ]"
        echo "}"
    } > "$output_file"

    log_success "JSON Export abgeschlossen: $output_file"
}

ping_test_all() {
    log_info "Ping-Test für alle laufenden Container/VMs"
    echo

    printf "  %-6s %-18s %-25s %-10s %-10s\n" "VMID" "IP" "NAME" "STATUS" "PING"
    printf "  %-6s %-18s %-25s %-10s %-10s\n" "------" "------------------" "-------------------------" "----------" "----------"

    # LXC Container
    local lxc_list=$(pct list 2>/dev/null | tail -n +2 | sort -n -k1)
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $2}')
        local hostname=$(echo "$line" | awk '{print $3}')
        local ip=$(get_container_ip "$vmid" "lxc")

        local ping_result="N/A"
        if [[ "$status" == "running" ]] && [[ "$ip" != "N/A" ]]; then
            if ping -c 1 -W 1 "$ip" &>/dev/null; then
                ping_result="${GREEN}OK${NC}"
            else
                ping_result="${RED}FAIL${NC}"
            fi
        fi

        printf "  %-6s %-18s %-25s %-10s %-22s\n" "$vmid" "$ip" "${hostname:0:25}" "$status" "$ping_result"
    done <<< "$lxc_list"

    # VMs
    local vm_list=$(qm list 2>/dev/null | tail -n +2 | sort -n -k1)
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local ip=$(get_container_ip "$vmid" "vm")

        local ping_result="N/A"
        if [[ "$status" == "running" ]] && [[ "$ip" != "N/A" ]]; then
            if ping -c 1 -W 1 "$ip" &>/dev/null; then
                ping_result="${GREEN}OK${NC}"
            else
                ping_result="${RED}FAIL${NC}"
            fi
        fi

        printf "  %-6s %-18s %-25s %-10s %-22s\n" "$vmid" "$ip" "${name:0:25}" "$status" "$ping_result"
    done <<< "$vm_list"

    echo
}

interactive_menu() {
    while true; do
        echo
        log_info "Interaktive Container-Verwaltung"
        echo
        echo "  1) Container/VM starten"
        echo "  2) Container/VM stoppen"
        echo "  3) Container/VM neu starten"
        echo "  4) Container/VM Status anzeigen"
        echo "  5) Übersicht anzeigen"
        echo "  6) Ping-Test durchführen"
        echo "  q) Beenden"
        echo
        read -rp "Auswahl: " choice

        case "$choice" in
            1)
                read -rp "VMID eingeben: " vmid
                if [[ -z "$vmid" ]]; then
                    log_error "Keine VMID angegeben"
                    continue
                fi

                local type=$(get_vmid_type "$vmid")
                if [[ "$type" == "lxc" ]]; then
                    log_info "Starte LXC $vmid..."
                    pct start "$vmid" && log_success "LXC $vmid gestartet" || log_error "Fehler beim Starten von LXC $vmid"
                elif [[ "$type" == "vm" ]]; then
                    log_info "Starte VM $vmid..."
                    qm start "$vmid" && log_success "VM $vmid gestartet" || log_error "Fehler beim Starten von VM $vmid"
                else
                    log_error "VMID $vmid nicht gefunden"
                fi
                ;;
            2)
                read -rp "VMID eingeben: " vmid
                if [[ -z "$vmid" ]]; then
                    log_error "Keine VMID angegeben"
                    continue
                fi

                local type=$(get_vmid_type "$vmid")
                if [[ "$type" == "lxc" ]]; then
                    log_info "Stoppe LXC $vmid..."
                    pct stop "$vmid" && log_success "LXC $vmid gestoppt" || log_error "Fehler beim Stoppen von LXC $vmid"
                elif [[ "$type" == "vm" ]]; then
                    log_info "Stoppe VM $vmid..."
                    qm stop "$vmid" && log_success "VM $vmid gestoppt" || log_error "Fehler beim Stoppen von VM $vmid"
                else
                    log_error "VMID $vmid nicht gefunden"
                fi
                ;;
            3)
                read -rp "VMID eingeben: " vmid
                if [[ -z "$vmid" ]]; then
                    log_error "Keine VMID angegeben"
                    continue
                fi

                local type=$(get_vmid_type "$vmid")
                if [[ "$type" == "lxc" ]]; then
                    log_info "Starte LXC $vmid neu..."
                    pct restart "$vmid" && log_success "LXC $vmid neu gestartet" || log_error "Fehler beim Neustart von LXC $vmid"
                elif [[ "$type" == "vm" ]]; then
                    log_info "Starte VM $vmid neu..."
                    qm restart "$vmid" && log_success "VM $vmid neu gestartet" || log_error "Fehler beim Neustart von VM $vmid"
                else
                    log_error "VMID $vmid nicht gefunden"
                fi
                ;;
            4)
                read -rp "VMID eingeben: " vmid
                if [[ -z "$vmid" ]]; then
                    log_error "Keine VMID angegeben"
                    continue
                fi

                local type=$(get_vmid_type "$vmid")
                if [[ "$type" == "lxc" ]]; then
                    pct status "$vmid"
                elif [[ "$type" == "vm" ]]; then
                    qm status "$vmid"
                else
                    log_error "VMID $vmid nicht gefunden"
                fi
                ;;
            5)
                show_banner
                show_network_schema
                count_resources
                show_lxc_containers
                show_vms
                check_ip_conflicts
                show_free_ranges
                ;;
            6)
                ping_test_all
                ;;
            q|Q)
                log_info "Beende interaktive Verwaltung"
                break
                ;;
            *)
                log_error "Ungültige Auswahl: $choice"
                ;;
        esac
    done
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

show_usage() {
    cat << EOF
Verwendung: $0 [OPTIONEN]

Zeigt eine Übersicht aller Proxmox Container und VMs mit ihren IP-Adressen.

Optionen:
    -h, --help           Zeigt diese Hilfe an
    -i, --interactive    Startet den interaktiven Modus für Container-Verwaltung
    -p, --ping           Führt einen Ping-Test für alle laufenden Container durch
    -c, --csv [FILE]     Exportiert die Daten als CSV (Standard: /tmp/proxmox-ip-map-YYYYMMDD-HHMMSS.csv)
    -j, --json [FILE]    Exportiert die Daten als JSON (Standard: /tmp/proxmox-ip-map-YYYYMMDD-HHMMSS.json)
    -e, --export-both    Exportiert sowohl CSV als auch JSON

Beispiele:
    $0                           # Normale Anzeige
    $0 --interactive             # Interaktiver Modus
    $0 --ping                    # Ping-Test aller Container
    $0 --csv                     # Export als CSV mit Standard-Dateinamen
    $0 --csv /tmp/export.csv     # Export als CSV mit eigenem Dateinamen
    $0 --export-both             # Exportiert CSV und JSON
EOF
}

main() {
    require_proxmox

    local export_csv_file=""
    local export_json_file=""
    local show_display=true
    local interactive_mode=false
    local ping_mode=false

    # Parse Kommandozeilen-Argumente
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -i|--interactive)
                interactive_mode=true
                show_display=false
                shift
                ;;
            -p|--ping)
                ping_mode=true
                show_display=false
                shift
                ;;
            -c|--csv)
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    export_csv_file="$2"
                    shift
                else
                    export_csv_file="/tmp/proxmox-ip-map-$(date +%Y%m%d-%H%M%S).csv"
                fi
                show_display=false
                shift
                ;;
            -j|--json)
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    export_json_file="$2"
                    shift
                else
                    export_json_file="/tmp/proxmox-ip-map-$(date +%Y%m%d-%H%M%S).json"
                fi
                show_display=false
                shift
                ;;
            -e|--export-both)
                export_csv_file="/tmp/proxmox-ip-map-$(date +%Y%m%d-%H%M%S).csv"
                export_json_file="/tmp/proxmox-ip-map-$(date +%Y%m%d-%H%M%S).json"
                show_display=false
                shift
                ;;
            *)
                log_error "Unbekannte Option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Interaktiver Modus
    if [[ "$interactive_mode" == true ]]; then
        show_banner
        interactive_menu
        exit 0
    fi

    # Ping-Test Modus
    if [[ "$ping_mode" == true ]]; then
        show_banner
        ping_test_all
        exit 0
    fi

    # Normale Anzeige
    if [[ "$show_display" == true ]]; then
        show_banner
        show_network_schema
        count_resources
        show_lxc_containers
        show_vms
        check_ip_conflicts
        show_free_ranges
        log_success "IP-Uebersicht abgeschlossen"
    fi

    # Exports
    [[ -n "$export_csv_file" ]] && export_csv "$export_csv_file"
    [[ -n "$export_json_file" ]] && export_json "$export_json_file"

    # Explizit mit Exit-Code 0 beenden
    exit 0
}

set +e
trap '' ERR

main "$@"
