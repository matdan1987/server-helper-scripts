#!/usr/bin/env bash
# ==============================================================================
# Script: Code Server Installation
# Beschreibung: Installiert VS Code Server (coder/code-server)
# Autor: matdan1987
# Version: 1.0.0
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
    
    LIB_DIR="$LIB_TMP"
    trap "rm -rf '$LIB_TMP'" EXIT
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
fi

source "$LIB_DIR/common.sh"
source "$LIB_DIR/os-detection.sh"
source "$LIB_DIR/package-manager.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

CODE_SERVER_VERSION=${CODE_SERVER_VERSION:-latest}
CODE_SERVER_USER=${CODE_SERVER_USER:-codeserver}
CODE_SERVER_HOME="/home/$CODE_SERVER_USER"
CODE_SERVER_PORT=${CODE_SERVER_PORT:-8443}
CODE_SERVER_PASSWORD=${CODE_SERVER_PASSWORD:-}
ENABLE_SERVICE=${ENABLE_SERVICE:-true}
AUTO_START=${AUTO_START:-true}
INSTALL_EXTENSIONS=${INSTALL_EXTENSIONS:-true}
USE_SYSTEMD=${USE_SYSTEMD:-true}

# Extensions zum Installieren
EXTENSIONS=(
    "ms-python.python"
    "ms-vscode.cpptools"
    "rust-lang.rust-analyzer"
    "golang.go"
    "hashicorp.terraform"
    "ms-vscode-remote.remote-ssh"
    "ms-docker.docker"
    "eamodio.gitlens"
)

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Code Server Installation"
    log_info "Installiert VS Code Server für Browser-basierte Entwicklung"
    echo
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    
    require_root
    
    # Prüfe OS-Unterstützung
    if ! is_debian_based && ! is_redhat_based; then
        die "Nicht unterstütztes Betriebssystem: $OS_NAME" 1
    fi
    
    # Prüfe ob Code Server bereits installiert ist
    if command_exists code-server; then
        local current_version=$(code-server --version 2>/dev/null | head -1 || echo "unknown")
        log_warn "Code Server ist bereits installiert: $current_version"
        
        if ! ask_yes_no "Neu installieren?"; then
            log_info "Installation abgebrochen"
            exit 0
        fi
    fi
    
    # Prüfe Node.js/npm
    if ! command_exists npm; then
        log_info "Node.js wird benötigt, installiere..."
        pkg_install nodejs npm
    fi
    
    log_success "Alle Voraussetzungen erfüllt"
}

create_user() {
    log_step "Erstelle Systembenutzer für Code Server..."
    
    if id "$CODE_SERVER_USER" &>/dev/null; then
        log_info "Benutzer '$CODE_SERVER_USER' existiert bereits"
        return 0
    fi
    
    useradd -m -s /bin/bash "$CODE_SERVER_USER"
    log_success "Benutzer '$CODE_SERVER_USER' erstellt"
}

install_dependencies() {
    log_step "Installiere Abhängigkeiten..."
    
    local deps=(
        curl
        wget
        git
        build-essential
        python3
        python3-dev
        python3-pip
        pkg-config
    )
    
    # Zusätzliche Dependencies für spezifische Systeme
    if is_debian_based; then
        deps+=(
            libx11-dev
            libxkbfile-dev
        )
    fi
    
    pkg_ensure_installed "${deps[@]}"
    
    log_success "Abhängigkeiten installiert"
}

install_code_server_from_repo() {
    log_step "Installiere Code Server..."
    
    if [[ "$CODE_SERVER_VERSION" == "latest" ]]; then
        # Neueste Version ermitteln
        local latest_version=$(curl -s https://api.github.com/repos/coder/code-server/releases/latest | \
            grep -oP '"tag_name": "\K(.*)(?=")' || echo "v4.31.0")
        CODE_SERVER_VERSION="${latest_version#v}"
    fi
    
    log_info "Installiere Version: $CODE_SERVER_VERSION"
    
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="amd64"
            ;;
        aarch64)
            arch="arm64"
            ;;
        armv7l)
            arch="armv7"
            ;;
    esac
    
    local download_url="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${arch}.deb"
    
    if is_debian_based; then
        log_info "Lade Code Server herunter..."
        local temp_deb="/tmp/code-server_${CODE_SERVER_VERSION}_${arch}.deb"
        
        if ! curl -fsSL "$download_url" -o "$temp_deb"; then
            die "Download fehlgeschlagen! Möglicherweise nicht unterstützte Architektur: $arch" 1
        fi
        
        log_info "Installiere DEB-Paket..."
        dpkg -i "$temp_deb"
        rm -f "$temp_deb"
    elif is_redhat_based; then
        log_info "Nutze npm für Installation (Red Hat basiert)..."
        npm install --global code-server
    fi
    
    log_success "Code Server installiert"
}

configure_code_server() {
    log_step "Konfiguriere Code Server..."
    
    # Erstelle Config-Verzeichnis
    local config_dir="$CODE_SERVER_HOME/.config/code-server"
    mkdir -p "$config_dir"
    
    # Generiere Passwort falls nicht vorhanden
    if [[ -z "$CODE_SERVER_PASSWORD" ]]; then
        CODE_SERVER_PASSWORD=$(openssl rand -base64 16)
        log_info "Generiertes Passwort: $CODE_SERVER_PASSWORD"
    fi
    
    # Erstelle config.yaml
    cat > "$config_dir/config.yaml" << EOF
# Code Server Konfiguration

# Bind-Adresse und Port
bind-addr: 0.0.0.0:$CODE_SERVER_PORT
auth: password
password: $CODE_SERVER_PASSWORD
cert: false

# Session-Einstellungen
session: true

# Proxy-Einstellungen (optional für Reverse Proxy)
# proxy-domain: code.example.com

# Extensions-Verzeichnis
extensions-dir: $CODE_SERVER_HOME/.local/share/code-server/extensions
user-data-dir: $CODE_SERVER_HOME/.local/share/code-server

# Update-Check deaktivieren
disable-update-check: true

# Telemetrie deaktivieren
disable-telemetry: true
EOF

    # Berechtigungen setzen
    chown -R $CODE_SERVER_USER:$CODE_SERVER_USER "$CODE_SERVER_HOME"
    chmod 700 "$config_dir"
    chmod 600 "$config_dir/config.yaml"
    
    log_success "Code Server konfiguriert"
}

create_systemd_service() {
    if [[ "$USE_SYSTEMD" != "true" ]]; then
        return 0
    fi
    
    log_step "Erstelle systemd Service..."
    
    cat > /etc/systemd/system/code-server.service << 'EOF'
[Unit]
Description=Code Server
After=network.target

[Service]
Type=simple
User=codeserver
WorkingDirectory=/home/codeserver
ExecStart=/usr/bin/code-server --config /home/codeserver/.config/code-server/config.yaml
Restart=on-failure
RestartSec=10

# Security Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/home/codeserver

# Limits
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF
    
    # Systemd neu laden
    systemctl daemon-reload
    
    # Service aktivieren
    if [[ "$AUTO_START" == "true" ]]; then
        systemctl enable code-server
        log_info "Service für Autostart aktiviert"
    fi
    
    log_success "systemd Service erstellt"
}

start_code_server() {
    log_step "Starte Code Server..."
    
    if [[ "$USE_SYSTEMD" == "true" ]]; then
        systemctl start code-server
        
        # Warte bis Service bereit ist
        local max_wait=30
        local count=0
        while ! systemctl is-active --quiet code-server; do
            sleep 1
            count=$((count + 1))
            if [[ $count -ge $max_wait ]]; then
                log_warn "Service-Start dauert länger als erwartet"
                break
            fi
        done
    fi
    
    log_success "Code Server gestartet"
}

install_extensions() {
    if [[ "$INSTALL_EXTENSIONS" != "true" ]]; then
        return 0
    fi
    
    log_step "Installiere VS Code Extensions..."
    
    # Warte bis Code Server läuft
    sleep 5
    
    local extension_count=0
    for ext in "${EXTENSIONS[@]}"; do
        log_info "Installiere Extension: $ext"
        
        sudo -u $CODE_SERVER_USER code-server --install-extension "$ext" 2>/dev/null || {
            log_warn "Extension konnte nicht installiert werden: $ext"
        }
        
        extension_count=$((extension_count + 1))
        progress_bar "$extension_count" "${#EXTENSIONS[@]}" "Extensions"
    done
    
    echo
    log_success "Extensions installiert"
}

configure_firewall() {
    if ! command_exists ufw &>/dev/null; then
        return 0
    fi
    
    log_step "Konfiguriere Firewall..."
    
    if ufw status | grep -q "Status: active"; then
        log_info "Öffne Port $CODE_SERVER_PORT in UFW..."
        ufw allow "$CODE_SERVER_PORT/tcp"
        log_success "Firewall konfiguriert"
    fi
}

setup_reverse_proxy() {
    log_step "Reverse Proxy Setup-Informationen..."
    
    local hostname=$(hostname -f 2>/dev/null || hostname)
    
    echo
    echo "═══════════════════════════════════════════════════════"
    echo "  Nginx/Traefik Reverse Proxy Configuration"
    echo "═══════════════════════════════════════════════════════"
    echo
    
    # Nginx
    echo "Nginx Configuration:"
    cat << EOF
server {
    listen 443 ssl http2;
    server_name code.example.com;
    
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    
    location / {
        proxy_pass http://localhost:$CODE_SERVER_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket Support
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
    
    echo
    echo "Traefik Configuration (docker-compose.yml):"
    cat << 'EOF'
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.code-server.rule=Host(\`code.example.com\`)"
  - "traefik.http.routers.code-server.entrypoints=websecure"
  - "traefik.http.routers.code-server.tls.certresolver=letsencrypt"
  - "traefik.http.services.code-server.loadbalancer.server.port=8443"
  - "traefik.http.services.code-server.loadbalancer.server.scheme=https"
EOF
    
    echo
}

show_post_install_info() {
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Code Server Installation abgeschlossen!"
    log_success "═══════════════════════════════════════"
    echo
    
    local service_status="stopped"
    if systemctl is-active --quiet code-server 2>/dev/null; then
        service_status="running"
    fi
    
    log_info "Status: $service_status"
    log_info "Version: $(code-server --version 2>/dev/null | head -1)"
    echo
    
    log_info "Zugriff:"
    echo "  http://$(get_primary_ip):$CODE_SERVER_PORT"
    echo "  Passwort: $CODE_SERVER_PASSWORD"
    echo
    
    log_info "Nützliche Befehle:"
    echo "  - Service starten:   sudo systemctl start code-server"
    echo "  - Service stoppen:   sudo systemctl stop code-server"
    echo "  - Logs ansehen:      sudo systemctl status code-server"
    echo "  - Logs folgen:       sudo journalctl -u code-server -f"
    echo
    
    log_info "Sicherheit:"
    echo "  - Nutze Reverse Proxy (Nginx/Traefik)"
    echo "  - Enablee HTTPS/SSL"
    echo "  - Ändere Passwort in config.yaml"
    echo "  - Firewall Port begrenzen"
    echo
    
    setup_reverse_proxy
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    create_user
    install_dependencies
    install_code_server_from_repo
    configure_code_server
    create_systemd_service
    start_code_server
    install_extensions
    configure_firewall
    show_post_install_info
    show_elapsed_time
}

trap 'log_error "Installation fehlgeschlagen!"; exit 1' ERR
trap 'log_info "Installation abgebrochen"; exit 130' INT TERM

main "$@"
