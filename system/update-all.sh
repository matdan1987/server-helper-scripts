#!/usr/bin/env bash
# ==============================================================================
# Script: System Update All
# Beschreibung: Aktualisiert alle System-Pakete auf Debian/Ubuntu/CentOS/Fedora
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

# Script-Verzeichnis ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Bibliotheken laden
source "$LIB_DIR/common.sh"
source "$LIB_DIR/os-detection.sh"
source "$LIB_DIR/package-manager.sh"
source "$LIB_DIR/dialog-helpers.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

# Umgebungsvariablen mit Defaults
AUTO_REBOOT=${AUTO_REBOOT:-false}
CREATE_BACKUP=${CREATE_BACKUP:-true}
INCLUDE_KERNEL=${INCLUDE_KERNEL:-true}
CLEANUP_AFTER=${CLEANUP_AFTER:-true}
INTERACTIVE=${INTERACTIVE:-true}

# Backup-Verzeichnis
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
    
    # Prüfe Internetverbindung
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
    
    # Willkommensdialog
    if ! dialog_confirm "Möchten Sie das System jetzt aktualisieren?"; then
        log_info "Update abgebrochen durch Benutzer"
        exit 0
    fi
    
    # Optionen auswählen
    local options
    options=$(dialog_checklist "Update-Optionen" "Wählen Sie Optionen:" 18 70 6 \
        "1" "Automatischer Neustart (bei Bedarf)" off \
        "2" "Backup der Paketliste erstellen" on \
        "3" "Kernel-Updates einschließen" on \
        "4" "Nach Update aufräumen" on \
        "5" "Distribution-Upgrade (nur apt)" off \
        "6" "Debug-Modus aktivieren" off) || {
        log_info "Update abgebrochen"
        exit 0
    }
    
    # Optionen parsen
    [[ "$options" =~ "1" ]] && AUTO_REBOOT=true
    [[ "$options" =~ "2" ]] && CREATE_BACKUP=true
    [[ "$options" =~ "3" ]] && INCLUDE_KERNEL=true
    [[ "$options" =~ "4" ]] && CLEANUP_AFTER=true
    [[ "$options" =~ "5" ]] && DIST_UPGRADE=true
    [[ "$options" =~ "6" ]] && DEBUG=1
    
    log_debug "Optionen: AUTO_REBOOT=$AUTO_REBOOT, CREATE_BACKUP=$CREATE_BACKUP, INCLUDE_KERNEL=$INCLUDE_KERNEL"
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
        if [[ "$INTERACTIVE" == "true" ]]; then
            dialog_info "System ist aktuell" "Es sind keine Updates verfügbar."
        fi
        exit 0
    fi
    
    if [[ "$INTERACTIVE" == "true" ]]; then
        dialog_info "Update-Information" "Verfügbare Updates: $upgradable Pakete"
    fi
}

perform_update() {
    log_step "Starte System-Update..."
    
    # Paketlisten aktualisieren
    pkg_update
    
    # Upgrade durchführen
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
    
    # Zusätzliches Cleanup
    case "$(get_package_manager)" in
        apt)
            # Alte Kernel entfernen (außer aktueller und vorheriger)
            if [[ "$INCLUDE_KERNEL" == "true" ]]; then
                log_info "Entferne alte Kernel..."
                local current_kernel=$(uname -r)
                apt-get autoremove --purge -y -qq 2>/dev/null || true
            fi
            ;;
    esac
    
    log_success "System aufgeräumt"
}

check_reboot_required() {
    log_step "Prüfe ob Neustart erforderlich ist..."
    
    local reboot_needed=false
    
    # Debian/Ubuntu
    if [[ -f /var/run/reboot-required ]]; then
        reboot_needed=true
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            log_info "Neustart erforderlich durch Pakete:"
            cat /var/run/reboot-required.pkgs | while read pkg; do
                log_info "  - $pkg"
            done
        fi
    fi
    
    # Kernel-Update
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
        if dialog_yesno "Neustart erforderlich" "Ein Neustart wird empfohlen.\n\nJetzt neustarten?" 10 60; then
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
    
    if [[ "$INTERACTIVE" == "true" ]]; then
        dialog_pause "Neustart" "System wird in $seconds Sekunden neu gestartet.\n\nDrücken Sie Esc zum Abbrechen." $seconds || {
            log_info "Neustart abgebrochen"
            return 0
        }
    else
        sleep $seconds
    fi
    
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

# Error-Handler
trap 'log_error "Script wurde durch Fehler beendet!"; exit 1' ERR
trap 'log_info "Script durch Benutzer abgebrochen"; exit 130' INT TERM

# Script ausführen
main "$@"
