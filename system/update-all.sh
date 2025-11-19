#!/usr/bin/env bash
# ==============================================================================
# Script: System Update All
# Beschreibung: Aktualisiert alle System-Pakete auf Debian/Ubuntu/CentOS/Fedora
# Autor: matdan1987
# Version: 1.2.0
# ==============================================================================

set -euo pipefail

# =============================================================================
# PFAD-ERKENNUNG (funktioniert mit curl und lokal)
# =============================================================================

if [[ "$0" == "/dev/fd/"* ]] || [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]]; then
    GITHUB_RAW="https://raw.githubusercontent.com/matdan1987/server-helper-scripts/main"
    LIB_TMP="/tmp/helper-scripts-lib-$$"
    mkdir -p "$LIB_TMP"
    
    echo "Lade Bibliotheken..."
    curl -fsSL "$GITHUB_RAW/lib/common.sh" -o "$LIB_TMP/common.sh"
    curl -fsSL "$GITHUB_RAW/lib/os-detection.sh" -o "$LIB_TMP/os-detection.sh"
    curl -fsSL "$GITHUB_RAW/lib/package-manager.sh" -o "$LIB_TMP/package-manager.sh"
    curl -fsSL "$GITHUB_RAW/lib/dialog-helpers.sh" -o "$LIB_TMP/dialog-helpers.sh"
    
    LIB_DIR="$LIB_TMP"
    trap "rm -rf '$LIB_TMP'" EXIT
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
fi

source "$LIB_DIR/common.sh"
source "$LIB_DIR/os-detection.sh"
source "$LIB_DIR/package-manager.sh"
source "$LIB_DIR/dialog-helpers.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

AUTO_REBOOT=${AUTO_REBOOT:-false}
CREATE_BACKUP=${CREATE_BACKUP:-true}
INCLUDE_KERNEL=${INCLUDE_KERNEL:-true}
CLEANUP_AFTER=${CLEANUP_AFTER:-true}
INTERACTIVE=${INTERACTIVE:-false}
BACKUP_DIR="/var/backups/helper-scripts"

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "System Update - Alle Pakete aktualisieren"
    show_system_info
    echo
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    require_root
    
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        die "Keine Internetverbindung verfügbar!" 1
    fi
    
    log_success "Alle Voraussetzungen erfüllt"
}

get_user_options() {
    if [[ "$INTERACTIVE" != "true" ]] || [[ ! -t 0 ]]; then
        log_info "Nicht-interaktiver Modus, verwende Defaults"
        return 0
    fi
    
    if ! ask_yes_no "Möchten Sie das System jetzt aktualisieren?" "y"; then
        log_info "Update abgebrochen durch Benutzer"
        exit 0
    fi
}

create_package_backup() {
    if [[ "$CREATE_BACKUP" != "true" ]]; then
        return 0
    fi
    
    log_step "Erstelle Backup der Paketliste..."
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    case "$(get_package_manager)" in
        apt)
            dpkg --get-selections > "$BACKUP_DIR/dpkg-selections-$timestamp.txt"
            apt-mark showauto > "$BACKUP_DIR/apt-auto-$timestamp.txt"
            ;;
        dnf|yum)
            rpm -qa > "$BACKUP_DIR/rpm-packages-$timestamp.txt"
            ;;
        pacman)
            pacman -Q > "$BACKUP_DIR/pacman-packages-$timestamp.txt"
            ;;
    esac
    
    log_success "Backup erstellt in: $BACKUP_DIR"
}

show_upgrade_info() {
    log_step "Sammle Update-Informationen..."
    
    local upgradable=$(pkg_count_upgradable)
    local installed=$(pkg_count_installed)
    
    log_info "Installierte Pakete: $installed"
    log_info "Verfügbare Updates: $upgradable"
    
    if [[ $upgradable -eq 0 ]]; then
        log_success "System ist bereits aktuell!"
        echo
        echo "═══════════════════════════════════════"
        echo "  ✅ Keine Updates verfügbar"
        echo "═══════════════════════════════════════"
        echo
        exit 0
    fi
}

perform_update() {
    log_step "Starte System-Update..."
    pkg_update
    
    if [[ "${DIST_UPGRADE:-false}" == "true" ]] && is_debian_based; then
        log_info "Führe Distribution-Upgrade durch..."
        pkg_dist_upgrade
    else
        pkg_upgrade
    fi
    
    log_success "System-Update abgeschlossen"
}

cleanup_system() {
    if [[ "$CLEANUP_AFTER" != "true" ]]; then
        return 0
    fi
    
    log_step "Räume System auf..."
    pkg_clean
    
    case "$(get_package_manager)" in
        apt)
            if [[ "$INCLUDE_KERNEL" == "true" ]]; then
                log_info "Entferne alte Kernel..."
                apt-get autoremove --purge -y -qq 2>/dev/null || true
            fi
            ;;
    esac
    
    log_success "System aufgeräumt"
}

check_reboot_required() {
    log_step "Prüfe ob Neustart erforderlich ist..."
    
    local reboot_needed=false
    
    if [[ -f /var/run/reboot-required ]]; then
        reboot_needed=true
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            log_info "Neustart erforderlich durch Pakete:"
            cat /var/run/reboot-required.pkgs | while read pkg; do
                log_info "  - $pkg"
            done
        fi
    fi
    
    if [[ "$INCLUDE_KERNEL" == "true" ]]; then
        local running_kernel=$(uname -r)
        local latest_kernel=""
        
        case "$(get_package_manager)" in
            apt)
                latest_kernel=$(dpkg -l 'linux-image-*' | grep ^ii | tail -1 | awk '{print $2}' | sed 's/linux-image-//')
                ;;
            dnf|yum)
                latest_kernel=$(rpm -q kernel | tail -1 | sed 's/kernel-//')
                ;;
        esac
        
        if [[ -n "$latest_kernel" ]] && [[ "$running_kernel" != "$latest_kernel" ]]; then
            reboot_needed=true
            log_warn "Neuer Kernel installiert: $latest_kernel (aktuell: $running_kernel)"
        fi
    fi
    
    if [[ "$reboot_needed" == "true" ]]; then
        handle_reboot
    else
        log_success "Kein Neustart erforderlich"
    fi
}

handle_reboot() {
    log_warn "Ein Neustart wird empfohlen!"
    
    if [[ "$AUTO_REBOOT" == "true" ]]; then
        log_info "Automatischer Neustart aktiviert"
        schedule_reboot 60
    elif [[ "$INTERACTIVE" == "true" ]]; then
        if ask_yes_no "Jetzt neustarten?"; then
            schedule_reboot 10
        else
            log_info "Neustart übersprungen. Bitte später manuell durchführen!"
        fi
    else
        log_warn "Bitte führen Sie später einen Neustart durch: sudo reboot"
    fi
}

schedule_reboot() {
    local seconds=$1
    log_warn "System wird in $seconds Sekunden neu gestartet..."
    
    for ((i=$seconds; i>0; i--)); do
        echo -ne "\rNeustart in $i Sekunden... (Strg+C zum Abbrechen)  "
        sleep 1
    done
    echo
    
    log_info "Starte System neu..."
    reboot
}

show_summary() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    
    echo
    log_success "═══════════════════════════════════════"
    log_success "  System-Update erfolgreich!"
    log_success "═══════════════════════════════════════"
    log_info "Dauer: $((duration / 60))m $((duration % 60))s"
    log_info "Hostname: $(hostname)"
    log_info "Kernel: $(uname -r)"
    log_info "OS: $OS_PRETTY_NAME"
    
    if [[ "$CREATE_BACKUP" == "true" ]]; then
        log_info "Backup: $BACKUP_DIR"
    fi
    
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    get_user_options
    create_package_backup
    show_upgrade_info
    perform_update
    cleanup_system
    check_reboot_required
    show_summary
    show_elapsed_time
}

trap 'log_error "Script wurde durch Fehler beendet!"; exit 1' ERR
trap 'log_info "Script durch Benutzer abgebrochen"; exit 130' INT TERM

main "$@"
