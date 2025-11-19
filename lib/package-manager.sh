#!/usr/bin/env bash
# package-manager.sh - Einheitliche Paketmanager-Schnittstelle
# Version: 1.0.0
# Unterstützt: apt, dnf, yum, pacman, zypper

# Abhängigkeiten laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/os-detection.sh"

# =============================================================================
# PAKETLISTEN AKTUALISIEREN
# =============================================================================

pkg_update() {
    log_step "Aktualisiere Paketlisten..."
    
    case "$(get_package_manager)" in
        apt)
            apt-get update -qq || die "apt-get update fehlgeschlagen!"
            ;;
        dnf)
            dnf check-update -q || true
            ;;
        yum)
            yum check-update -q || true
            ;;
        pacman)
            pacman -Sy --noconfirm || die "pacman -Sy fehlgeschlagen!"
            ;;
        zypper)
            zypper refresh || die "zypper refresh fehlgeschlagen!"
            ;;
        *)
            die "Nicht unterstützter Paketmanager: $(get_package_manager)"
            ;;
    esac
    
    log_success "Paketlisten aktualisiert"
}

# =============================================================================
# PAKETE INSTALLIEREN
# =============================================================================

pkg_install() {
    local packages=("$@")
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        log_warn "Keine Pakete zum Installieren angegeben"
        return 0
    fi
    
    log_step "Installiere Pakete: ${packages[*]}"
    
    case "$(get_package_manager)" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" || \
                die "Installation mit apt fehlgeschlagen!"
            ;;
        dnf)
            dnf install -y -q "${packages[@]}" || \
                die "Installation mit dnf fehlgeschlagen!"
            ;;
        yum)
            yum install -y -q "${packages[@]}" || \
                die "Installation mit yum fehlgeschlagen!"
            ;;
        pacman)
            pacman -S --noconfirm --needed "${packages[@]}" || \
                die "Installation mit pacman fehlgeschlagen!"
            ;;
        zypper)
            zypper install -y "${packages[@]}" || \
                die "Installation mit zypper fehlgeschlagen!"
            ;;
        *)
            die "Nicht unterstützter Paketmanager!"
            ;;
    esac
    
    log_success "Pakete erfolgreich installiert"
}

# =============================================================================
# PAKETE ENTFERNEN
# =============================================================================

pkg_remove() {
    local packages=("$@")
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        log_warn "Keine Pakete zum Entfernen angegeben"
        return 0
    fi
    
    log_step "Entferne Pakete: ${packages[*]}"
    
    case "$(get_package_manager)" in
        apt)
            apt-get remove -y -qq "${packages[@]}"
            apt-get autoremove -y -qq
            ;;
        dnf)
            dnf remove -y -q "${packages[@]}"
            dnf autoremove -y -q
            ;;
        yum)
            yum remove -y -q "${packages[@]}"
            yum autoremove -y -q
            ;;
        pacman)
            pacman -R --noconfirm "${packages[@]}"
            ;;
        zypper)
            zypper remove -y "${packages[@]}"
            ;;
        *)
            die "Nicht unterstützter Paketmanager!"
            ;;
    esac
    
    log_success "Pakete erfolgreich entfernt"
}

# =============================================================================
# SYSTEM-UPGRADE
# =============================================================================

pkg_upgrade() {
    log_step "Aktualisiere alle installierten Pakete..."
    
    case "$(get_package_manager)" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || \
                die "apt-get upgrade fehlgeschlagen!"
            ;;
        dnf)
            dnf upgrade -y -q || die "dnf upgrade fehlgeschlagen!"
            ;;
        yum)
            yum update -y -q || die "yum update fehlgeschlagen!"
            ;;
        pacman)
            pacman -Syu --noconfirm || die "pacman -Syu fehlgeschlagen!"
            ;;
        zypper)
            zypper update -y || die "zypper update fehlgeschlagen!"
            ;;
        *)
            die "Nicht unterstützter Paketmanager!"
            ;;
    esac
    
    log_success "System-Upgrade abgeschlossen"
}

# =============================================================================
# DIST-UPGRADE (nur apt)
# =============================================================================

pkg_dist_upgrade() {
    log_step "Führe Distribution-Upgrade durch..."
    
    case "$(get_package_manager)" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq || \
                die "apt-get dist-upgrade fehlgeschlagen!"
            log_success "Distribution-Upgrade abgeschlossen"
            ;;
        *)
            log_warn "dist-upgrade nur für apt verfügbar, nutze normales upgrade"
            pkg_upgrade
            ;;
    esac
}

# =============================================================================
# PAKET-STATUS PRÜFEN
# =============================================================================

pkg_is_installed() {
    local package="$1"
    
    case "$(get_package_manager)" in
        apt)
            dpkg -l "$package" 2>/dev/null | grep -q "^ii"
            ;;
        dnf|yum)
            rpm -q "$package" &>/dev/null
            ;;
        pacman)
            pacman -Q "$package" &>/dev/null
            ;;
        zypper)
            rpm -q "$package" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_ensure_installed() {
    local packages=("$@")
    local to_install=()
    
    for package in "${packages[@]}"; do
        if ! pkg_is_installed "$package"; then
            to_install+=("$package")
        else
            log_debug "Paket bereits installiert: $package"
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        pkg_install "${to_install[@]}"
    else
        log_info "Alle Pakete bereits installiert"
    fi
}

# =============================================================================
# AUFRÄUMEN
# =============================================================================

pkg_clean() {
    log_step "Räume Paket-Cache auf..."
    
    case "$(get_package_manager)" in
        apt)
            apt-get autoremove -y -qq
            apt-get autoclean -y -qq
            apt-get clean -y -qq
            ;;
        dnf)
            dnf autoremove -y -q
            dnf clean all -q
            ;;
        yum)
            yum autoremove -y -q
            yum clean all -q
            ;;
        pacman)
            pacman -Sc --noconfirm
            ;;
        zypper)
            zypper clean -a
            ;;
        *)
            log_warn "Cleanup für diesen Paketmanager nicht implementiert"
            return 1
            ;;
    esac
    
    log_success "Paket-Cache bereinigt"
}

# =============================================================================
# REPOSITORY-MANAGEMENT
# =============================================================================

pkg_add_repository() {
    local repo="$1"
    
    log_step "Füge Repository hinzu: $repo"
    
    case "$(get_package_manager)" in
        apt)
            add-apt-repository -y "$repo" || die "Repository konnte nicht hinzugefügt werden!"
            pkg_update
            ;;
        dnf)
            dnf config-manager --add-repo "$repo" || die "Repository konnte nicht hinzugefügt werden!"
            ;;
        yum)
            yum-config-manager --add-repo "$repo" || die "Repository konnte nicht hinzugefügt werden!"
            ;;
        *)
            log_warn "Repository-Management für diesen Paketmanager nicht implementiert"
            return 1
            ;;
    esac
    
    log_success "Repository hinzugefügt"
}

# =============================================================================
# PAKET-SUCHE
# =============================================================================

pkg_search() {
    local query="$1"
    
    log_info "Suche nach: $query"
    
    case "$(get_package_manager)" in
        apt)
            apt-cache search "$query"
            ;;
        dnf|yum)
            yum search "$query"
            ;;
        pacman)
            pacman -Ss "$query"
            ;;
        zypper)
            zypper search "$query"
            ;;
        *)
            log_error "Suche für diesen Paketmanager nicht implementiert"
            return 1
            ;;
    esac
}

# =============================================================================
# PAKET-INFORMATIONEN
# =============================================================================

pkg_info() {
    local package="$1"
    
    case "$(get_package_manager)" in
        apt)
            apt-cache show "$package"
            ;;
        dnf|yum)
            yum info "$package"
            ;;
        pacman)
            pacman -Si "$package"
            ;;
        zypper)
            zypper info "$package"
            ;;
        *)
            log_error "Info für diesen Paketmanager nicht implementiert"
            return 1
            ;;
    esac
}

# =============================================================================
# STATISTIKEN
# =============================================================================

pkg_count_installed() {
    case "$(get_package_manager)" in
        apt)
            dpkg -l | grep -c "^ii"
            ;;
        dnf|yum)
            rpm -qa | wc -l
            ;;
        pacman)
            pacman -Q | wc -l
            ;;
        zypper)
            rpm -qa | wc -l
            ;;
        *)
            echo "0"
            ;;
    esac
}

pkg_count_upgradable() {
    case "$(get_package_manager)" in
        apt)
            apt list --upgradable 2>/dev/null | grep -c "upgradable"
            ;;
        dnf)
            dnf check-update -q 2>/dev/null | grep -v "^$" | wc -l
            ;;
        yum)
            yum check-update -q 2>/dev/null | grep -v "^$" | wc -l
            ;;
        pacman)
            pacman -Qu 2>/dev/null | wc -l
            ;;
        *)
            echo "0"
            ;;
    esac
}

# =============================================================================
# PAKET-LISTE EXPORTIEREN/IMPORTIEREN
# =============================================================================

pkg_export_list() {
    local output_file="${1:-/tmp/package-list-$(date +%Y%m%d).txt}"
    
    log_info "Exportiere Paketliste nach: $output_file"
    
    case "$(get_package_manager)" in
        apt)
            dpkg --get-selections > "$output_file"
            ;;
        dnf|yum)
            rpm -qa > "$output_file"
            ;;
        pacman)
            pacman -Q > "$output_file"
            ;;
        *)
            log_error "Export für diesen Paketmanager nicht implementiert"
            return 1
            ;;
    esac
    
    log_success "Paketliste exportiert: $output_file"
}

pkg_import_list() {
    local input_file="$1"
    
    if [[ ! -f "$input_file" ]]; then
        die "Datei nicht gefunden: $input_file"
    fi
    
    log_info "Importiere Paketliste aus: $input_file"
    
    case "$(get_package_manager)" in
        apt)
            dpkg --set-selections < "$input_file"
            apt-get dselect-upgrade -y
            ;;
        *)
            log_error "Import für diesen Paketmanager nicht implementiert"
            return 1
            ;;
    esac
    
    log_success "Paketliste importiert"
}

# =============================================================================
# ABHÄNGIGKEITEN PRÜFEN
# =============================================================================

pkg_check_dependencies() {
    local packages=("$@")
    local missing=()
    
    for package in "${packages[@]}"; do
        if ! pkg_is_installed "$package"; then
            missing+=("$package")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Fehlende Pakete: ${missing[*]}"
        return 1
    else
        log_success "Alle Abhängigkeiten erfüllt"
        return 0
    fi
}

# =============================================================================
# AUTO-INITIALISIERUNG
# =============================================================================

log_debug "package-manager.sh geladen - Paketmanager: $(get_package_manager)"
