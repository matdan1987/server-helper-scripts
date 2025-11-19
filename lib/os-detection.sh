#!/usr/bin/env bash
# os-detection.sh - Betriebssystem und Distribution erkennen
# Version: 1.0.0

# Globale Variablen für OS-Informationen
export OS_NAME=""
export OS_VERSION=""
export OS_VERSION_ID=""
export OS_PRETTY_NAME=""
export OS_CODENAME=""

# =============================================================================
# HAUPT-ERKENNUNGSFUNKTION
# =============================================================================

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # Moderne Linux-Distributionen
        source /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        OS_VERSION_ID="$VERSION_ID"
        OS_PRETTY_NAME="$PRETTY_NAME"
        OS_CODENAME="${VERSION_CODENAME:-}"
        
    elif [[ -f /etc/debian_version ]]; then
        # Ältere Debian-basierte Systeme
        OS_NAME="debian"
        OS_VERSION=$(cat /etc/debian_version)
        OS_PRETTY_NAME="Debian $OS_VERSION"
        
    elif [[ -f /etc/redhat-release ]]; then
        # Ältere RedHat-basierte Systeme
        OS_NAME="redhat"
        OS_VERSION=$(grep -oP '\d+\.\d+' /etc/redhat-release | head -1)
        OS_PRETTY_NAME=$(cat /etc/redhat-release)
        
    elif [[ -f /etc/arch-release ]]; then
        # Arch Linux
        OS_NAME="arch"
        OS_VERSION="rolling"
        OS_PRETTY_NAME="Arch Linux"
        
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
        OS_PRETTY_NAME="Unknown OS"
    fi
    
    log_debug "OS erkannt: $OS_PRETTY_NAME ($OS_NAME $OS_VERSION)"
}

# =============================================================================
# DISTRIBUTIONS-CHECKS
# =============================================================================

is_debian_based() {
    [[ "$OS_NAME" =~ ^(debian|ubuntu|linuxmint|pop|elementary|zorin)$ ]]
}

is_ubuntu() {
    [[ "$OS_NAME" == "ubuntu" ]]
}

is_debian() {
    [[ "$OS_NAME" == "debian" ]]
}

is_redhat_based() {
    [[ "$OS_NAME" =~ ^(rhel|centos|fedora|rocky|alma|oracle)$ ]]
}

is_centos() {
    [[ "$OS_NAME" == "centos" ]]
}

is_fedora() {
    [[ "$OS_NAME" == "fedora" ]]
}

is_arch_based() {
    [[ "$OS_NAME" =~ ^(arch|manjaro|endeavouros)$ ]]
}

is_suse_based() {
    [[ "$OS_NAME" =~ ^(opensuse|sles)$ ]]
}

# =============================================================================
# PAKETMANAGER-ERKENNUNG
# =============================================================================

get_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# =============================================================================
# VERSIONS-CHECKS
# =============================================================================

version_compare() {
    # Vergleicht zwei Versionsnummern
    # Rückgabe: 0 wenn gleich, 1 wenn v1 > v2, 2 wenn v1 < v2
    local v1="$1"
    local v2="$2"
    
    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi
    
    local IFS=.
    local i ver1=($v1) ver2=($v2)
    
    for ((i=0; i<${#ver1[@]} || i<${#ver2[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            return 1
        elif [[ -z ${ver1[i]} ]]; then
            return 2
        elif ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        elif ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    
    return 0
}

min_version_required() {
    local required="$1"
    version_compare "$OS_VERSION" "$required"
    local result=$?
    [[ $result -eq 0 || $result -eq 1 ]]
}

# =============================================================================
# SYSTEM-TYP-ERKENNUNG
# =============================================================================

is_wsl() {
    [[ -f /proc/version ]] && grep -qi microsoft /proc/version
}

is_docker_container() {
    [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null
}

is_lxc_container() {
    [[ -f /run/container_type ]] && [[ "$(cat /run/container_type)" == "lxc" ]]
}

is_proxmox() {
    [[ -f /etc/pve/local/pve-ssl.pem ]]
}

is_vm() {
    local virt=$(systemd-detect-virt 2>/dev/null || echo "none")
    [[ "$virt" != "none" ]]
}

get_virtualization() {
    systemd-detect-virt 2>/dev/null || echo "none"
}

# =============================================================================
# INIT-SYSTEM-ERKENNUNG
# =============================================================================

has_systemd() {
    command -v systemctl &> /dev/null && [[ -d /run/systemd/system ]]
}

has_sysvinit() {
    [[ -f /etc/init.d/cron ]] || [[ -f /etc/init.d/networking ]]
}

get_init_system() {
    if has_systemd; then
        echo "systemd"
    elif has_sysvinit; then
        echo "sysvinit"
    else
        echo "unknown"
    fi
}

# =============================================================================
# ARCHITEKTUR-ERKENNUNG
# =============================================================================

get_architecture() {
    uname -m
}

is_x86_64() {
    [[ "$(uname -m)" == "x86_64" ]]
}

is_arm64() {
    [[ "$(uname -m)" =~ ^(aarch64|arm64)$ ]]
}

is_arm() {
    [[ "$(uname -m)" =~ ^arm ]]
}

# =============================================================================
# INFORMATIONS-AUSGABE
# =============================================================================

show_os_info() {
    detect_os
    
    echo "OS-Informationen:"
    echo "  Name: $OS_NAME"
    echo "  Version: $OS_VERSION"
    echo "  Pretty Name: $OS_PRETTY_NAME"
    echo "  Codename: ${OS_CODENAME:-N/A}"
    echo "  Architektur: $(get_architecture)"
    echo "  Paketmanager: $(get_package_manager)"
    echo "  Init-System: $(get_init_system)"
    echo "  Virtualisierung: $(get_virtualization)"
}

# =============================================================================
# AUTO-INITIALISIERUNG
# =============================================================================

# OS beim Laden automatisch erkennen
detect_os
