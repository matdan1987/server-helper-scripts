#!/usr/bin/env bash
# ==============================================================================
# Script: Disk Cleanup
# Beschreibung: Bereinigt Festplatten durch Entfernen unnötiger Dateien
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/common.sh"
source "$LIB_DIR/os-detection.sh"
source "$LIB_DIR/package-manager.sh"
source "$LIB_DIR/dialog-helpers.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

AGGRESSIVE_CLEAN=${AGGRESSIVE_CLEAN:-false}
CLEAN_LOGS=${CLEAN_LOGS:-true}
CLEAN_CACHE=${CLEAN_CACHE:-true}
CLEAN_TMP=${CLEAN_TMP:-true}
CLEAN_DOCKER=${CLEAN_DOCKER:-false}
DRY_RUN=${DRY_RUN:-false}

# Statistiken
FREED_SPACE=0

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Festplatten-Bereinigung"
    show_disk_usage
}

show_disk_usage() {
    log_info "Aktuelle Festplattennutzung:"
    df -h / /home 2>/dev/null | grep -v "Filesystem" | while read line; do
        log_info "  $line"
    done
    echo
}

get_dir_size() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        du -sb "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo 0
    fi
}

remove_safely() {
    local path="$1"
    local description="$2"
    
    if [[ ! -e "$path" ]]; then
        log_debug "Überspringe (existiert nicht): $path"
        return 0
    fi
    
    local size_before=$(get_dir_size "$path")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Würde entfernen: $description ($path)"
        return 0
    fi
    
    log_info "Entferne: $description"
    log_debug "Pfad: $path"
    
    if [[ -d "$path" ]]; then
        rm -rf "$path"/* 2>/dev/null || true
    elif [[ -f "$path" ]]; then
        rm -f "$path" 2>/dev/null || true
    fi
    
    local freed=$((size_before / 1024 / 1024))
    if [[ $freed -gt 0 ]]; then
        log_success "Freigegeben: ${freed}MB"
        FREED_SPACE=$((FREED_SPACE + freed))
    fi
}

clean_package_cache() {
    if [[ "$CLEAN_CACHE" != "true" ]]; then
        return 0
    fi
    
    log_step "Bereinige Paket-Cache..."
    
    pkg_clean
    
    case "$(get_package_manager)" in
        apt)
            remove_safely "/var/cache/apt/archives/*.deb" "APT Archive"
            remove_safely "/var/cache/apt/archives/partial/*" "APT Partial Downloads"
            ;;
        dnf|yum)
            remove_safely "/var/cache/yum" "YUM Cache"
            remove_safely "/var/cache/dnf" "DNF Cache"
            ;;
        pacman)
            remove_safely "/var/cache/pacman/pkg" "Pacman Cache"
            ;;
    esac
}

clean_log_files() {
    if [[ "$CLEAN_LOGS" != "true" ]]; then
        return 0
    fi
    
    log_step "Bereinige Log-Dateien..."
    
    # Journal Logs (systemd)
    if has_systemd; then
        log_info "Bereinige Journal-Logs..."
        if [[ "$DRY_RUN" != "true" ]]; then
            journalctl --vacuum-time=7d 2>/dev/null || true
            journalctl --vacuum-size=100M 2>/dev/null || true
        fi
    fi
    
    # Alte Log-Dateien
    if [[ "$AGGRESSIVE_CLEAN" == "true" ]]; then
        log_info "Entferne alte Log-Dateien (>30 Tage)..."
        if [[ "$DRY_RUN" != "true" ]]; then
            find /var/log -type f -name "*.log.*" -mtime +30 -delete 2>/dev/null || true
            find /var/log -type f -name "*.gz" -mtime +30 -delete 2>/dev/null || true
        fi
    else
        log_info "Komprimiere große Log-Dateien..."
        if [[ "$DRY_RUN" != "true" ]]; then
            find /var/log -type f -size +50M -name "*.log" -exec gzip {} \; 2>/dev/null || true
        fi
    fi
    
    # Leere Log-Dateien
    remove_safely "/var/log/*.0" "Rotierte Logs"
    remove_safely "/var/log/*.1" "Alte Logs"
}

clean_tmp_files() {
    if [[ "$CLEAN_TMP" != "true" ]]; then
        return 0
    fi
    
    log_step "Bereinige temporäre Dateien..."
    
    remove_safely "/tmp/*" "Temp-Dateien (/tmp)"
    remove_safely "/var/tmp/*" "Temp-Dateien (/var/tmp)"
    remove_safely "/var/cache/apt/archives/*.deb" "APT Downloads"
    
    # User-spezifische Temps
    if [[ "$AGGRESSIVE_CLEAN" == "true" ]]; then
        find /home -type f -path "*/tmp/*" -mtime +7 -delete 2>/dev/null || true
        find /home -type f -path "*/.cache/*" -mtime +30 -delete 2>/dev/null || true
    fi
}

clean_docker() {
    if [[ "$CLEAN_DOCKER" != "true" ]] || ! command_exists docker; then
        return 0
    fi
    
    log_step "Bereinige Docker..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Würde Docker bereinigen"
        return 0
    fi
    
    log_info "Entferne ungenutzte Docker-Images..."
    docker image prune -af 2>/dev/null || true
    
    log_info "Entferne ungenutzte Docker-Container..."
    docker container prune -f 2>/dev/null || true
    
    log_info "Entferne ungenutzte Docker-Volumes..."
    docker volume prune -f 2>/dev/null || true
    
    log_info "Entferne ungenutzte Docker-Netzwerke..."
    docker network prune -f 2>/dev/null || true
    
    log_success "Docker bereinigt"
}

clean_old_kernels() {
    if ! is_debian_based; then
        return 0
    fi
    
    log_step "Bereinige alte Kernel..."
    
    local current_kernel=$(uname -r)
    log_info "Aktueller Kernel: $current_kernel"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get autoremove --purge -y 2>/dev/null || true
    fi
}

clean_thumbnails() {
    if [[ "$AGGRESSIVE_CLEAN" != "true" ]]; then
        return 0
    fi
    
    log_step "Bereinige Thumbnail-Cache..."
    
    find /home -type f -path "*/.thumbnails/*" -delete 2>/dev/null || true
    find /home -type f -path "*/.cache/thumbnails/*" -delete 2>/dev/null || true
}

analyze_large_files() {
    log_step "Suche große Dateien (>100MB)..."
    
    log_info "Top 10 größte Dateien:"
    find / -type f -size +100M -exec du -h {} \; 2>/dev/null | sort -rh | head -10 | while read line; do
        log_info "  $line"
    done
}

show_summary() {
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Bereinigung abgeschlossen!"
    log_success "═══════════════════════════════════════"
    log_info "Freigegebener Speicher: ${FREED_SPACE}MB"
    echo
    log_info "Neue Festplattennutzung:"
    show_disk_usage
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    require_root
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN Modus aktiv - keine Änderungen werden vorgenommen"
    fi
    
    clean_package_cache
    clean_log_files
    clean_tmp_files
    clean_docker
    clean_old_kernels
    clean_thumbnails
    
    if [[ "$AGGRESSIVE_CLEAN" == "true" ]]; then
        analyze_large_files
    fi
    
    show_summary
    show_elapsed_time
}

trap 'log_error "Fehler bei der Bereinigung!"; exit 1' ERR
trap 'log_info "Bereinigung abgebrochen"; exit 130' INT TERM

main "$@"
