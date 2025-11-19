#!/usr/bin/env bash
# ==============================================================================
# Script: Update All LXC Containers
# Beschreibung: Aktualisiert alle LXC-Container in Proxmox
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/common.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

AUTO_START_STOPPED=${AUTO_START_STOPPED:-true}
AUTO_STOP_AFTER=${AUTO_STOP_AFTER:-true}
SKIP_TEMPLATES=${SKIP_TEMPLATES:-true}
PARALLEL=${PARALLEL:-false}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "LXC Container Update - Alle Container"
}

check_requirements() {
    require_root
    
    if ! is_proxmox; then
        die "Dieses Script funktioniert nur auf Proxmox VE!" 1
    fi
    
    require_command pct "proxmox-ve"
}

get_all_containers() {
    pct list | tail -n +2 | awk '{print $1}'
}

is_container_running() {
    local ctid=$1
    pct status "$ctid" | grep -q "running"
}

is_container_template() {
    local ctid=$1
    pct config "$ctid" | grep -q "template: 1"
}

update_container() {
    local ctid=$1
    local was_stopped=false
    
    log_step "Container $ctid: $(pct config $ctid | grep -E '^hostname:' | cut -d' ' -f2)"
    
    # Template überspringen
    if [[ "$SKIP_TEMPLATES" == "true" ]] && is_container_template "$ctid"; then
        log_info "Überspringe Template-Container"
        return 0
    fi
    
    # Container starten falls gestoppt
    if ! is_container_running "$ctid"; then
        if [[ "$AUTO_START_STOPPED" == "true" ]]; then
            log_info "Starte gestoppten Container..."
            pct start "$ctid"
            sleep 5
            was_stopped=true
        else
            log_warn "Container ist gestoppt, überspringe"
            return 0
        fi
    fi
    
    # Update durchführen
    log_info "Führe Update durch..."
    
    # Versuche verschiedene Update-Methoden
    if pct exec "$ctid" -- bash -c "command -v apt-get" &>/dev/null; then
        pct exec "$ctid" -- bash -c "apt-get update && apt-get upgrade -y && apt-get autoremove -y"
    elif pct exec "$ctid" -- bash -c "command -v yum" &>/dev/null; then
        pct exec "$ctid" -- bash -c "yum update -y && yum autoremove -y"
    elif pct exec "$ctid" -- bash -c "command -v dnf" &>/dev/null; then
        pct exec "$ctid" -- bash -c "dnf upgrade -y && dnf autoremove -y"
    else
        log_warn "Kein unterstützter Paketmanager gefunden"
    fi
    
    # Container wieder stoppen falls er vorher gestoppt war
    if [[ "$was_stopped" == "true" ]] && [[ "$AUTO_STOP_AFTER" == "true" ]]; then
        log_info "Stoppe Container wieder..."
        pct stop "$ctid"
    fi
    
    log_success "Container $ctid aktualisiert"
}

main() {
    show_banner
    check_requirements
    
    local containers=($(get_all_containers))
    local total=${#containers[@]}
    local current=0
    
    log_info "Gefundene Container: $total"
    echo
    
    for ctid in "${containers[@]}"; do
        current=$((current + 1))
        echo
        log_info "[$current/$total] Aktualisiere Container $ctid"
        
        update_container "$ctid" || log_error "Fehler bei Container $ctid"
        
        progress_bar "$current" "$total" "Gesamt"
    done
    
    echo
    log_success "Alle Container aktualisiert!"
    show_elapsed_time
}

trap 'log_error "Update fehlgeschlagen!"; exit 1' ERR
trap 'log_info "Update abgebrochen"; exit 130' INT TERM

main "$@"
