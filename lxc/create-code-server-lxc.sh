#!/usr/bin/env bash
# ==============================================================================
# Script: Code Server LXC
# Beschreibung: Erstellt LXC mit VS Code Server (Browser-IDE)
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

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

VMID=${VMID:-$(get_next_vmid lxc)}
HOSTNAME=${HOSTNAME:-code-server}
MEMORY=${MEMORY:-$(calculate_lxc_memory code-server)}
DISK=${DISK:-$(calculate_lxc_disk code-server)}
CORES=${CORES:-$(calculate_lxc_cores code-server)}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}
TEMPLATE=${TEMPLATE:-$(get_latest_debian_template)}

CODE_SERVER_PORT=${CODE_SERVER_PORT:-8443}
CODE_SERVER_PASSWORD=${CODE_SERVER_PASSWORD:-$(openssl rand -base64 16)}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Code Server LXC"
    log_info "VS Code im Browser - IDE für remote Coding"
    echo
    show_ip_allocation
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    require_root
    require_proxmox
    
    if ! validate_vmid_range "$VMID" "lxc"; then
        if ! ask_yes_no "VMID außerhalb Bereich. Fortfahren?"; then
            exit 0
        fi
    fi
    
    if vmid_exists "$VMID"; then
        die "VMID $VMID ist bereits vergeben!" 1
    fi
    
    log_success "Voraussetzungen erfüllt"
}

create_code_server_container() {
    log_step "Erstelle LXC Container..."
    
    if ! template_exists "$TEMPLATE" "$STORAGE"; then
        download_template "$TEMPLATE" "$STORAGE"
    fi
    
    local ROOTPW=$(openssl rand -base64 16)
    local ip=$(get_ip_for_vmid "$VMID")
    local net_config=$(create_network_string "$VMID" "$BRIDGE" "eth0")
    
    log_info "Container-Details:"
    log_info "  VMID: $VMID"
    log_info "  IP: ${ip}/${NETMASK}"
    
    pct create "$VMID" "${STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --password "$ROOTPW" \
        --net0 "$net_config" \
        --nameserver "1.1.1.1 8.8.8.8" \
        --features "nesting=1" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1
    
    log_success "LXC erstellt"
    
    # Info speichern
    local info_dir="/root/.lxc-info"
    mkdir -p "$info_dir"
    
    cat > "$info_dir/${VMID}-${HOSTNAME}.txt" << EOF
# Code Server LXC
Created: $(date '+%Y-%m-%d %H:%M:%S')
VMID: $VMID
IP: ${ip}/${NETMASK}
Gateway: $GATEWAY
Root Password: $ROOTPW

Code Server:
  URL: https://${ip}:${CODE_SERVER_PORT}
  Password: $CODE_SERVER_PASSWORD
EOF
    
    chmod 600 "$info_dir/${VMID}-${HOSTNAME}.txt"
    
    wait_for_lxc "$VMID" 60
}

install_dependencies() {
    log_step "Installiere Abhängigkeiten..."
    
    lxc_exec "$VMID" bash -c "
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    "
    
    lxc_install_package "$VMID" \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        build-essential \
        python3 \
        python3-dev \
        git
}

install_code_server() {
    log_step "Installiere Code Server..."
    
    log_info "Lade neueste Version herunter..."
    local latest_version=$(curl -s https://api.github.com/repos/coder/code-server/releases/latest | \
        grep -oP '"tag_name": "\K(.*)(?=")' | head -1)
    
    log_info "Version: $latest_version"
    
    local arch=$(pct exec "$VMID" -- uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
    esac
    
    # Download und Installation
    lxc_exec "$VMID" bash -c "
        cd /tmp
        curl -fsSL https://github.com/coder/code-server/releases/download/${latest_version}/code-server_${latest_version:1}_${arch}.deb -o code-server.deb
        apt-get install -y /tmp/code-server.deb
        rm /tmp/code-server.deb
    "
    
    log_success "Code Server installiert"
}

configure_code_server() {
    log_step "Konfiguriere Code Server..."
    
    local config_dir="/root/.config/code-server"
    
    lxc_exec "$VMID" mkdir -p "$config_dir"
    
    lxc_exec "$VMID" bash -c "cat > ${config_dir}/config.yaml" << CONFIG_EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
disable-update-check: true
disable-telemetry: true
log: info
CONFIG_EOF
    
    # Systemd Service
    lxc_exec "$VMID" bash -c "cat > /etc/systemd/system/code-server.service" << 'SERVICE_EOF'
[Unit]
Description=Code Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/code-server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    
    # Service starten
    lxc_exec "$VMID" bash -c "
        systemctl daemon-reload
        systemctl enable code-server
        systemctl start code-server
    "
    
    log_success "Code Server konfiguriert und gestartet"
}

show_post_install_info() {
    local ip=$(get_ip_for_vmid "$VMID")
    
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Code Server LXC erstellt!"
    log_success "═══════════════════════════════════════"
    echo
    
    log_info "Container-Details:"
    echo "  VMID:     $VMID"
    echo "  IP:       ${ip}/${NETMASK}"
    echo
    
    log_info "Code Server Access:"
    echo "  URL:      https://${ip}:${CODE_SERVER_PORT}"
    echo "  Password: $CODE_SERVER_PASSWORD"
    echo
    
    log_info "Nützliche Befehle:"
    echo "  Status:   pct exec $VMID -- systemctl status code-server"
    echo "  Logs:     pct exec $VMID -- journalctl -u code-server -f"
    echo "  Restart:  pct exec $VMID -- systemctl restart code-server"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    create_code_server_container
    install_dependencies
    install_code_server
    configure_code_server
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Fehler!"; exit 1' ERR
trap 'log_info "Abgebrochen"; exit 130' INT TERM

main "$@"
