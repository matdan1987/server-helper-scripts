#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox Resource Monitor
# Beschreibung: Überwacht Ressourcen und sendet Alerts bei Problemen
# Autor: matdan1987
# Version: 1.0.0
# Features: CPU, RAM, Disk Monitoring, Alerts, Dashboard, Logs
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

CPU_THRESHOLD="${CPU_THRESHOLD:-80}"          # CPU Warnung bei >80%
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-85}"    # RAM Warnung bei >85%
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"        # Disk Warnung bei >90%
LOG_FILE="${LOG_FILE:-/var/log/proxmox-monitor.log}"

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Proxmox Resource Monitor"
    echo
}

get_host_cpu_usage() {
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    echo "${cpu_usage%.*}"  # Runde ab
}

get_host_memory_usage() {
    local total=$(free | grep Mem | awk '{print $2}')
    local used=$(free | grep Mem | awk '{print $3}')
    local percent=$((used * 100 / total))
    echo "$percent"
}

get_host_disk_usage() {
    local usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    echo "$usage"
}

get_container_cpu() {
    local vmid="$1"
    local type=$(get_vmid_type "$vmid")

    if [[ "$type" == "lxc" ]]; then
        pct exec "$vmid" -- top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | head -1 || echo "0"
    else
        echo "N/A"
    fi
}

get_container_memory() {
    local vmid="$1"
    local type=$(get_vmid_type "$vmid")

    if [[ "$type" == "lxc" ]]; then
        local config=$(pct config "$vmid" 2>/dev/null | grep "memory:" | awk '{print $2}')
        local used=$(pct exec "$vmid" -- free | grep Mem | awk '{print $3}' 2>/dev/null || echo "0")
        local total=$(pct exec "$vmid" -- free | grep Mem | awk '{print $2}' 2>/dev/null || echo "1")
        local percent=$((used * 100 / total))
        echo "$percent"
    else
        echo "N/A"
    fi
}

show_host_status() {
    log_info "Host-Ressourcen"
    echo

    local cpu=$(get_host_cpu_usage)
    local memory=$(get_host_memory_usage)
    local disk=$(get_host_disk_usage)

    # CPU Status
    echo -n "  CPU:    ${cpu}% "
    if [[ $cpu -gt $CPU_THRESHOLD ]]; then
        echo -e "${RED}⚠ WARNUNG${NC}"
    else
        echo -e "${GREEN}✓${NC}"
    fi

    # Memory Status
    echo -n "  Memory: ${memory}% "
    if [[ $memory -gt $MEMORY_THRESHOLD ]]; then
        echo -e "${RED}⚠ WARNUNG${NC}"
    else
        echo -e "${GREEN}✓${NC}"
    fi

    # Disk Status
    echo -n "  Disk:   ${disk}% "
    if [[ $disk -gt $DISK_THRESHOLD ]]; then
        echo -e "${RED}⚠ WARNUNG${NC}"
    else
        echo -e "${GREEN}✓${NC}"
    fi

    echo
}

show_container_resources() {
    log_info "Container-Ressourcen (Top 10 nach CPU)"
    echo

    printf "  %-6s %-20s %-8s %-8s %-8s %s\n" "VMID" "NAME" "CPU%" "MEM%" "STATUS" "ALERT"
    printf "  %-6s %-20s %-8s %-8s %-8s %s\n" "------" "--------------------" "--------" "--------" "--------" "-----"

    local container_data=()

    # Sammle Daten
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $2}')
        local name=$(echo "$line" | awk '{print $3}')

        if [[ "$status" == "running" ]]; then
            local cpu=$(get_container_cpu "$vmid" 2>/dev/null || echo "0")
            local mem=$(get_container_memory "$vmid" 2>/dev/null || echo "0")

            # Alert-Status
            local alert=""
            if [[ "${cpu%.*}" -gt "$CPU_THRESHOLD" ]] 2>/dev/null; then
                alert="${RED}CPU${NC}"
            fi
            if [[ "${mem%.*}" -gt "$MEMORY_THRESHOLD" ]] 2>/dev/null; then
                alert="$alert ${RED}MEM${NC}"
            fi
            [[ -z "$alert" ]] && alert="${GREEN}OK${NC}"

            container_data+=("$cpu|$vmid|$name|$mem|$status|$alert")
        fi
    done < <(pct list 2>/dev/null | tail -n +2)

    # Sortiere nach CPU (absteigend) und zeige Top 10
    printf '%s\n' "${container_data[@]}" | sort -t'|' -k1 -nr | head -10 | while IFS='|' read -r cpu vmid name mem status alert; do
        printf "  %-6s %-20s %-8s %-8s %-8s %b\n" "$vmid" "${name:0:20}" "${cpu}%" "${mem}%" "$status" "$alert"
    done

    echo
}

check_alerts() {
    local alert_count=0

    log_step "Prüfe Ressourcen-Alerts"

    # Host Checks
    local cpu=$(get_host_cpu_usage)
    local memory=$(get_host_memory_usage)
    local disk=$(get_host_disk_usage)

    if [[ $cpu -gt $CPU_THRESHOLD ]]; then
        log_warn "Host CPU über Schwellwert: ${cpu}% (Schwelle: ${CPU_THRESHOLD}%)"
        alert_count=$((alert_count + 1))
        log_to_file "WARNING" "Host CPU high: ${cpu}%"
    fi

    if [[ $memory -gt $MEMORY_THRESHOLD ]]; then
        log_warn "Host Memory über Schwellwert: ${memory}% (Schwelle: ${MEMORY_THRESHOLD}%)"
        alert_count=$((alert_count + 1))
        log_to_file "WARNING" "Host Memory high: ${memory}%"
    fi

    if [[ $disk -gt $DISK_THRESHOLD ]]; then
        log_warn "Host Disk über Schwellwert: ${disk}% (Schwelle: ${DISK_THRESHOLD}%)"
        alert_count=$((alert_count + 1))
        log_to_file "WARNING" "Host Disk high: ${disk}%"
    fi

    # Container Checks
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $2}')
        local name=$(echo "$line" | awk '{print $3}')

        if [[ "$status" == "running" ]]; then
            local cpu=$(get_container_cpu "$vmid" 2>/dev/null || echo "0")
            local mem=$(get_container_memory "$vmid" 2>/dev/null || echo "0")

            if [[ "${cpu%.*}" -gt "$CPU_THRESHOLD" ]] 2>/dev/null; then
                log_warn "Container $vmid ($name) CPU hoch: ${cpu}%"
                alert_count=$((alert_count + 1))
                log_to_file "WARNING" "Container $vmid ($name) CPU high: ${cpu}%"
            fi

            if [[ "${mem%.*}" -gt "$MEMORY_THRESHOLD" ]] 2>/dev/null; then
                log_warn "Container $vmid ($name) Memory hoch: ${mem}%"
                alert_count=$((alert_count + 1))
                log_to_file "WARNING" "Container $vmid ($name) Memory high: ${mem}%"
            fi
        fi
    done < <(pct list 2>/dev/null | tail -n +2)

    if [[ $alert_count -eq 0 ]]; then
        log_success "Alle Ressourcen im normalen Bereich"
        log_to_file "INFO" "All resources within thresholds"
    else
        log_warn "$alert_count Alerts gefunden"
    fi

    echo
}

log_to_file() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

show_dashboard() {
    # Endlos-Loop für Live-Dashboard
    while true; do
        clear
        show_banner
        show_host_status
        show_container_resources

        echo -e "${CYAN}Drücke Ctrl+C zum Beenden. Aktualisierung alle 5 Sekunden...${NC}"
        sleep 5
    done
}

generate_report() {
    local output_file="${1:-/tmp/proxmox-resource-report-$(date +%Y%m%d-%H%M%S).txt}"

    log_info "Erstelle Ressourcen-Report: $output_file"

    {
        echo "======================================================================"
        echo "Proxmox Resource Report"
        echo "Erstellt: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "======================================================================"
        echo

        echo "HOST RESSOURCEN:"
        echo "  CPU:    $(get_host_cpu_usage)% (Schwelle: ${CPU_THRESHOLD}%)"
        echo "  Memory: $(get_host_memory_usage)% (Schwelle: ${MEMORY_THRESHOLD}%)"
        echo "  Disk:   $(get_host_disk_usage)% (Schwelle: ${DISK_THRESHOLD}%)"
        echo

        echo "CONTAINER/VMs (Laufend):"
        printf "  %-6s %-20s %-8s %-8s %s\n" "VMID" "NAME" "CPU%" "MEM%" "STATUS"
        printf "  %-6s %-20s %-8s %-8s %s\n" "------" "--------------------" "--------" "--------" "--------"

        while read -r line; do
            [[ -z "$line" ]] && continue
            local vmid=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{print $2}')
            local name=$(echo "$line" | awk '{print $3}')

            if [[ "$status" == "running" ]]; then
                local cpu=$(get_container_cpu "$vmid" 2>/dev/null || echo "N/A")
                local mem=$(get_container_memory "$vmid" 2>/dev/null || echo "N/A")
                printf "  %-6s %-20s %-8s %-8s %s\n" "$vmid" "${name:0:20}" "$cpu" "$mem" "$status"
            fi
        done < <(pct list 2>/dev/null | tail -n +2)

        echo
        echo "ALERTS:"
        check_alerts 2>&1 | grep -E "(WARN|ERROR)" || echo "  Keine Alerts"

        echo
        echo "======================================================================"
    } > "$output_file"

    log_success "Report erstellt: $output_file"
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

show_usage() {
    cat << EOF
Verwendung: $0 [OPTIONEN]

Proxmox Ressourcen-Monitor für CPU, RAM und Disk.

Optionen:
    -h, --help              Zeigt diese Hilfe an
    -s, --status            Zeigt Host-Status an
    -c, --containers        Zeigt Container-Ressourcen an
    -a, --alerts            Prüft und zeigt Alerts
    -d, --dashboard         Startet Live-Dashboard (Ctrl+C zum Beenden)
    -r, --report [FILE]     Erstellt detaillierten Report
    -l, --log               Zeigt Log-Datei

Schwellwerte (Umgebungsvariablen):
    CPU_THRESHOLD           CPU-Warnschwelle in % (Standard: $CPU_THRESHOLD)
    MEMORY_THRESHOLD        RAM-Warnschwelle in % (Standard: $MEMORY_THRESHOLD)
    DISK_THRESHOLD          Disk-Warnschwelle in % (Standard: $DISK_THRESHOLD)
    LOG_FILE                Log-Datei Pfad (Standard: $LOG_FILE)

Beispiele:
    $0 --status                 # Zeigt Host-Status
    $0 --containers             # Zeigt Container-Ressourcen
    $0 --alerts                 # Prüft Alerts
    $0 --dashboard              # Live-Dashboard
    $0 --report /tmp/report.txt # Erstellt Report

    # Mit benutzerdefinierten Schwellwerten
    CPU_THRESHOLD=90 MEMORY_THRESHOLD=95 $0 --alerts

Cron-Job Beispiel:
    */5 * * * * /path/to/monitor-resources.sh --alerts >> /var/log/proxmox-monitor-cron.log 2>&1
EOF
}

main() {
    require_proxmox

    local action="status"
    local report_file=""

    # Parse Argumente
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -s|--status)
                action="status"
                shift
                ;;
            -c|--containers)
                action="containers"
                shift
                ;;
            -a|--alerts)
                action="alerts"
                shift
                ;;
            -d|--dashboard)
                action="dashboard"
                shift
                ;;
            -r|--report)
                action="report"
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    report_file="$2"
                    shift
                fi
                shift
                ;;
            -l|--log)
                action="log"
                shift
                ;;
            *)
                log_error "Unbekannte Option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    case "$action" in
        status)
            show_banner
            show_host_status
            ;;
        containers)
            show_banner
            show_container_resources
            ;;
        alerts)
            show_banner
            check_alerts
            ;;
        dashboard)
            show_dashboard
            ;;
        report)
            show_banner
            generate_report "$report_file"
            ;;
        log)
            if [[ -f "$LOG_FILE" ]]; then
                tail -50 "$LOG_FILE"
            else
                log_warn "Log-Datei nicht gefunden: $LOG_FILE"
            fi
            ;;
    esac

    exit 0
}

set +e
trap '' ERR

main "$@"
