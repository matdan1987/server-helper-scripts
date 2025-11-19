#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox Post-Installation
# Beschreibung: Konfiguriert Proxmox VE nach der Installation
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

DISABLE_ENTERPRISE_REPO=${DISABLE_ENTERPRISE_REPO:-true}
ENABLE_NO_SUBSCRIPTION_REPO=${ENABLE_NO_SUBSCRIPTION_REPO:-true}
REMOVE_SUBSCRIPTION_NOTICE=${REMOVE_SUBSCRIPTION_NOTICE:-true}
UPDATE_SYSTEM=${UPDATE_SYSTEM:-true}
INSTALL_USEFUL_TOOLS=${INSTALL_USEFUL_TOOLS:-true}
CONFIGURE_SWAPPINESS=${CONFIGURE_SWAPPINESS:-true}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Proxmox VE Post-Installation"
    log_info "Optimiert und konfiguriert Proxmox VE"
    echo
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    
    require_root
    
    # Prüfe ob Proxmox installiert ist
    if ! is_proxmox; then
        die "Dieses Script funktioniert nur auf Proxmox VE!" 1
    fi
    
    # Proxmox Version ermitteln
    if [[ -f /etc/pve/local/pve-ssl.pem ]]; then
        local pve_version=$(pveversion | cut -d'/' -f2)
        log_info "Proxmox VE Version: $pve_version"
    fi
    
    log_success "Proxmox VE erkannt"
}

disable_enterprise_repository() {
    if [[ "$DISABLE_ENTERPRISE_REPO" != "true" ]]; then
        return 0
    fi
    
    log_step "Deaktiviere Enterprise Repository..."
    
    local enterprise_list="/etc/apt/sources.list.d/pve-enterprise.list"
    
    if [[ -f "$enterprise_list" ]]; then
        create_backup "$enterprise_list"
        
        # Enterprise Repo auskommentieren
        sed -i 's/^deb/# deb/' "$enterprise_list"
        
        log_success "Enterprise Repository deaktiviert"
    else
        log_warn "Enterprise Repository nicht gefunden"
    fi
}

enable_no_subscription_repository() {
    if [[ "$ENABLE_NO_SUBSCRIPTION_REPO" != "true" ]]; then
        return 0
    fi
    
    log_step "Aktiviere No-Subscription Repository..."
    
    local sources_list="/etc/apt/sources.list"
    local repo_line="deb http://download.proxmox.com/debian/pve $(. /etc/os-release && echo $VERSION_CODENAME) pve-no-subscription"
    
    # Prüfe ob bereits vorhanden
    if grep -q "pve-no-subscription" "$sources_list" 2>/dev/null; then
        log_info "No-Subscription Repository bereits aktiv"
        return 0
    fi
    
    create_backup "$sources_list"
    
    # Repository hinzufügen
    echo "" >> "$sources_list"
    echo "# Proxmox VE No-Subscription Repository" >> "$sources_list"
    echo "$repo_line" >> "$sources_list"
    
    log_success "No-Subscription Repository aktiviert"
}

update_sources_list() {
    log_step "Aktualisiere sources.list..."
    
    local sources_list="/etc/apt/sources.list"
    create_backup "$sources_list"
    
    # Debian Standard-Repos sicherstellen
    cat > "$sources_list" << EOF
# Debian Standard Repositories
deb http://ftp.debian.org/debian $(. /etc/os-release && echo $VERSION_CODENAME) main contrib non-free non-free-firmware
deb http://ftp.debian.org/debian $(. /etc/os-release && echo $VERSION_CODENAME)-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $(. /etc/os-release && echo $VERSION_CODENAME)-security main contrib non-free non-free-firmware

# Proxmox VE No-Subscription Repository
deb http://download.proxmox.com/debian/pve $(. /etc/os-release && echo $VERSION_CODENAME) pve-no-subscription
EOF
    
    log_success "sources.list aktualisiert"
}

remove_subscription_notice() {
    if [[ "$REMOVE_SUBSCRIPTION_NOTICE" != "true" ]]; then
        return 0
    fi
    
    log_step "Entferne Subscription-Hinweis..."
    
    local js_file="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    
    if [[ ! -f "$js_file" ]]; then
        log_warn "JavaScript-Datei nicht gefunden: $js_file"
        return 0
    fi
    
    create_backup "$js_file"
    
    # Subscription Check auskommentieren
    sed -i.bak "s/data.status !== 'Active'/false/g" "$js_file"
    
    # Proxmox Services neu starten
    systemctl restart pveproxy
    
    log_success "Subscription-Hinweis entfernt"
    log_warn "Hinweis wird nach Updates möglicherweise wieder angezeigt"
}

update_proxmox_system() {
    if [[ "$UPDATE_SYSTEM" != "true" ]]; then
        return 0
    fi
    
    log_step "Aktualisiere Proxmox System..."
    
    pkg_update
    
    log_info "Führe System-Upgrade durch..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
    
    pkg_clean
    
    log_success "System aktualisiert"
}

install_useful_tools() {
    if [[ "$INSTALL_USEFUL_TOOLS" != "true" ]]; then
        return 0
    fi
    
    log_step "Installiere nützliche Tools..."
    
    local tools=(
        vim
        htop
        iotop
        iftop
        ncdu
        net-tools
        curl
        wget
        git
        screen
        tmux
        sudo
        lm-sensors
        ethtool
    )
    
    pkg_ensure_installed "${tools[@]}"
    
    log_success "Nützliche Tools installiert"
}

configure_swappiness() {
    if [[ "$CONFIGURE_SWAPPINESS" != "true" ]]; then
        return 0
    fi
    
    log_step "Konfiguriere Swappiness..."
    
    local sysctl_conf="/etc/sysctl.conf"
    create_backup "$sysctl_conf"
    
    # Swappiness auf 10 setzen (Standard: 60)
    if grep -q "vm.swappiness" "$sysctl_conf"; then
        sed -i 's/^vm.swappiness.*/vm.swappiness=10/' "$sysctl_conf"
    else
        echo "vm.swappiness=10" >> "$sysctl_conf"
    fi
    
    # Sofort anwenden
    sysctl -w vm.swappiness=10 &>/dev/null
    
    log_success "Swappiness auf 10 gesetzt"
}

configure_timezone() {
    log_step "Prüfe Zeitzone..."
    
    local current_tz=$(timedatectl show -p Timezone --value)
    log_info "Aktuelle Zeitzone: $current_tz"
    
    if [[ "$current_tz" != "Europe/Berlin" ]]; then
        if ask_yes_no "Zeitzone auf Europe/Berlin setzen?"; then
            timedatectl set-timezone Europe/Berlin
            log_success "Zeitzone gesetzt: Europe/Berlin"
        fi
    fi
}

optimize_pve_storage() {
    log_step "Optimiere Storage-Konfiguration..."
    
    # Prüfe ob ZFS verwendet wird
    if command_exists zpool && zpool list &>/dev/null; then
        log_info "ZFS erkannt, optimiere..."
        
        # ARC Limit setzen (50% RAM)
        local total_ram=$(get_total_memory)
        local arc_max=$((total_ram * 512))  # MB zu Bytes * 50%
        
        echo "$arc_max" > /sys/module/zfs/parameters/zfs_arc_max
        
        log_info "ZFS ARC Maximum: $((arc_max / 1024 / 1024))MB"
    fi
}

show_system_info() {
    echo
    log_info "═══════════════════════════════════════"
    log_info "  Proxmox System-Informationen"
    log_info "═══════════════════════════════════════"
    
    # Proxmox Version
    log_info "PVE Version: $(pveversion | cut -d'/' -f2)"
    
    # Kernel
    log_info "Kernel: $(uname -r)"
    
    # CPU
    log_info "CPU: $(nproc) Cores"
    
    # RAM
    log_info "RAM: $(get_total_memory)MB ($(get_free_memory)MB frei)"
    
    # Storage
    pvesm status 2>/dev/null | tail -n +2 | while read line; do
        log_info "Storage: $line"
    done
    
    # Cluster Status
    if pvecm status &>/dev/null; then
        log_info "Cluster: Aktiv"
    else
        log_info "Cluster: Nicht konfiguriert"
    fi
    
    echo
}

create_useful_aliases() {
    log_step "Erstelle nützliche Aliases..."
    
    local bashrc="/root/.bashrc"
    
    # Aliases hinzufügen
    cat >> "$bashrc" << 'EOF'

# Proxmox Helper Aliases
alias pve-update='apt update && apt dist-upgrade -y && apt autoremove -y'
alias pve-cleanup='pveam update && apt clean && apt autoremove -y'
alias pve-backup='vzdump --all --mode snapshot --compress zstd'
alias lxc-list='pct list'
alias vm-list='qm list'
alias pve-status='pvesh get /cluster/resources'
EOF
    
    log_success "Aliases erstellt (wirksam nach neuem Login)"
}

show_post_install_info() {
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Post-Installation abgeschlossen!"
    log_success "═══════════════════════════════════════"
    echo
    log_info "Nächste Schritte:"
    echo
    echo "  1. Web-Interface öffnen:"
    echo "     https://$(get_primary_ip):8006"
    echo
    echo "  2. Subscription-Status prüfen:"
    echo "     pvesubscription get"
    echo
    echo "  3. Updates installieren:"
    echo "     pve-update  (oder: apt update && apt dist-upgrade)"
    echo
    echo "  4. Storage konfigurieren:"
    echo "     pvesm status"
    echo
    echo "  5. Backup einrichten:"
    echo "     Datacenter → Backup"
    echo
    
    log_info "Nützliche Befehle wurden als Aliases hinzugefügt (siehe .bashrc)"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    disable_enterprise_repository
    update_sources_list
    enable_no_subscription_repository
    remove_subscription_notice
    update_proxmox_system
    install_useful_tools
    configure_swappiness
    configure_timezone
    optimize_pve_storage
    create_useful_aliases
    show_system_info
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Post-Installation fehlgeschlagen!"; exit 1' ERR
trap 'log_info "Installation abgebrochen"; exit 130' INT TERM

main "$@"
