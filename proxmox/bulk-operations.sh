#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox Bulk Operations
# Beschreibung: Massenoperationen für mehrere Container/VMs gleichzeitig
# Autor: matdan1987
# Version: 1.0.0
# Features: Start, Stop, Restart, Update, Backup, Snapshot für mehrere VMs
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
    show_header "Proxmox Bulk Operations"
    echo
}

bulk_start() {
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0

    log_step "Starte $total Container/VMs"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo -n "  VMID $vmid (LXC)... "
            if pct start "$vmid" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -n "  VMID $vmid (VM)... "
            if qm start "$vmid" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success gestartet, $failed fehlgeschlagen"
}

bulk_stop() {
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0

    log_step "Stoppe $total Container/VMs"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo -n "  VMID $vmid (LXC)... "
            if pct stop "$vmid" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -n "  VMID $vmid (VM)... "
            if qm stop "$vmid" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success gestoppt, $failed fehlgeschlagen"
}

bulk_restart() {
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0

    log_step "Starte $total Container/VMs neu"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo -n "  VMID $vmid (LXC)... "
            if pct restart "$vmid" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -n "  VMID $vmid (VM)... "
            if qm restart "$vmid" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success neu gestartet, $failed fehlgeschlagen"
}

bulk_update() {
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0

    log_step "Aktualisiere $total LXC Container"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo "  VMID $vmid (LXC)..."
            if pct exec "$vmid" -- bash -c "apt-get update -qq && apt-get upgrade -y -qq" &>/dev/null; then
                echo -e "    ${GREEN}✓ Aktualisiert${NC}"
                success=$((success + 1))
            else
                echo -e "    ${RED}✗ Fehler${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -e "  VMID $vmid (VM)... ${YELLOW}Übersprungen (nur LXC wird unterstützt)${NC}"
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success aktualisiert, $failed fehlgeschlagen"
}

bulk_snapshot() {
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0
    local snapshot_name="snapshot-$(date +%Y%m%d-%H%M%S)"

    log_step "Erstelle Snapshots für $total Container/VMs"
    log_info "Snapshot-Name: $snapshot_name"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo -n "  VMID $vmid (LXC)... "
            if pct snapshot "$vmid" "$snapshot_name" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -n "  VMID $vmid (VM)... "
            if qm snapshot "$vmid" "$snapshot_name" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success Snapshots erstellt, $failed fehlgeschlagen"
}

bulk_set_memory() {
    local memory="$1"
    shift
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0

    log_step "Setze Speicher auf ${memory}MB für $total Container/VMs"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo -n "  VMID $vmid (LXC)... "
            if pct set "$vmid" --memory "$memory" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -n "  VMID $vmid (VM)... "
            if qm set "$vmid" --memory "$memory" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success konfiguriert, $failed fehlgeschlagen"
}

bulk_set_cores() {
    local cores="$1"
    shift
    local vmids=("$@")
    local total=${#vmids[@]}
    local success=0
    local failed=0

    log_step "Setze CPU-Cores auf $cores für $total Container/VMs"

    for vmid in "${vmids[@]}"; do
        local type=$(get_vmid_type "$vmid")

        if [[ "$type" == "lxc" ]]; then
            echo -n "  VMID $vmid (LXC)... "
            if pct set "$vmid" --cores "$cores" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        elif [[ "$type" == "vm" ]]; then
            echo -n "  VMID $vmid (VM)... "
            if qm set "$vmid" --cores "$cores" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
                success=$((success + 1))
            else
                echo -e "${RED}✗${NC}"
                failed=$((failed + 1))
            fi
        else
            echo -e "  VMID $vmid... ${YELLOW}nicht gefunden${NC}"
            failed=$((failed + 1))
        fi
    done

    echo
    log_success "$success konfiguriert, $failed fehlgeschlagen"
}

parse_vmid_range() {
    local range="$1"

    if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        seq "$start" "$end"
    else
        echo "$range"
    fi
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

show_usage() {
    cat << EOF
Verwendung: $0 [OPERATION] [OPTIONEN] VMID1 [VMID2 VMID3 ...]

Massenoperationen für mehrere Proxmox Container/VMs gleichzeitig.

Operationen:
    start               Startet alle angegebenen Container/VMs
    stop                Stoppt alle angegebenen Container/VMs
    restart             Startet alle angegebenen Container/VMs neu
    update              Aktualisiert alle angegebenen LXC Container (apt update && upgrade)
    snapshot            Erstellt Snapshots für alle angegebenen Container/VMs
    set-memory MB       Setzt Arbeitsspeicher für alle Container/VMs
    set-cores N         Setzt CPU-Cores für alle Container/VMs

VMID-Angabe:
    - Einzelne VMIDs: 100 101 102
    - Bereiche: 100-110 (erstellt Liste von 100 bis 110)
    - Gemischt: 100 105-110 115

Beispiele:
    $0 start 100 101 102                    # Startet Container 100, 101, 102
    $0 stop 100-110                         # Stoppt Container 100 bis 110
    $0 restart 100 105-110 115              # Startet gemischte Liste neu
    $0 update 100-150                       # Aktualisiert alle LXC Container von 100-150
    $0 snapshot 100 101 102                 # Erstellt Snapshots
    $0 set-memory 4096 100-110              # Setzt 4GB RAM für Container 100-110
    $0 set-cores 4 100 101 102              # Setzt 4 CPU-Cores

Interaktiv:
    $0 start --all-running                  # Startet alle aktuell laufenden Container neu
    $0 stop --all-lxc                       # Stoppt alle LXC Container
    $0 stop --all-vms                       # Stoppt alle VMs
EOF
}

main() {
    require_proxmox

    if [[ $# -lt 2 ]]; then
        show_usage
        exit 1
    fi

    local operation="$1"
    shift

    show_banner

    # Parse VMIDs
    local vmids=()
    local special_flag=""

    for arg in "$@"; do
        case "$arg" in
            --all-running)
                special_flag="all-running"
                ;;
            --all-lxc)
                special_flag="all-lxc"
                ;;
            --all-vms)
                special_flag="all-vms"
                ;;
            --all)
                special_flag="all"
                ;;
            *)
                # Parse range oder einzelne VMID
                for vmid in $(parse_vmid_range "$arg"); do
                    vmids+=("$vmid")
                done
                ;;
        esac
    done

    # Spezial-Flags verarbeiten
    if [[ -n "$special_flag" ]]; then
        case "$special_flag" in
            all-running)
                vmids=($(pct list 2>/dev/null | awk '$2=="running" {print $1}'))
                vmids+=($(qm list 2>/dev/null | awk '$3=="running" {print $1}'))
                ;;
            all-lxc)
                vmids=($(pct list 2>/dev/null | tail -n +2 | awk '{print $1}'))
                ;;
            all-vms)
                vmids=($(qm list 2>/dev/null | tail -n +2 | awk '{print $1}'))
                ;;
            all)
                vmids=($(pct list 2>/dev/null | tail -n +2 | awk '{print $1}'))
                vmids+=($(qm list 2>/dev/null | tail -n +2 | awk '{print $1}'))
                ;;
        esac
    fi

    if [[ ${#vmids[@]} -eq 0 ]]; then
        log_error "Keine VMIDs angegeben"
        show_usage
        exit 1
    fi

    log_info "Ausgewählte VMIDs: ${vmids[*]}"
    echo

    case "$operation" in
        start)
            bulk_start "${vmids[@]}"
            ;;
        stop)
            bulk_stop "${vmids[@]}"
            ;;
        restart)
            bulk_restart "${vmids[@]}"
            ;;
        update)
            bulk_update "${vmids[@]}"
            ;;
        snapshot)
            bulk_snapshot "${vmids[@]}"
            ;;
        set-memory)
            if [[ ${#vmids[@]} -lt 2 ]]; then
                log_error "Speichergröße und mindestens eine VMID erforderlich"
                exit 1
            fi
            local memory="${vmids[0]}"
            unset 'vmids[0]'
            bulk_set_memory "$memory" "${vmids[@]}"
            ;;
        set-cores)
            if [[ ${#vmids[@]} -lt 2 ]]; then
                log_error "Core-Anzahl und mindestens eine VMID erforderlich"
                exit 1
            fi
            local cores="${vmids[0]}"
            unset 'vmids[0]'
            bulk_set_cores "$cores" "${vmids[@]}"
            ;;
        *)
            log_error "Unbekannte Operation: $operation"
            show_usage
            exit 1
            ;;
    esac

    exit 0
}

set +e
trap '' ERR

main "$@"
