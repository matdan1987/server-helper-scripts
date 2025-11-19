#!/usr/bin/env bash
# ==============================================================================
# Script: Docker Installation
# Beschreibung: Installiert Docker Engine und Docker Compose
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

INSTALL_COMPOSE=${INSTALL_COMPOSE:-true}
DOCKER_VERSION=${DOCKER_VERSION:-latest}
ADD_CURRENT_USER=${ADD_CURRENT_USER:-true}
ENABLE_SERVICE=${ENABLE_SERVICE:-true}
CONFIGURE_FIREWALL=${CONFIGURE_FIREWALL:-false}

DOCKER_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Docker Installation"
    log_info "Installation von Docker Engine und Docker Compose"
    echo
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    
    require_root
    
    # Prüfe OS-Unterstützung
    if ! is_debian_based && ! is_redhat_based; then
        die "Nicht unterstütztes Betriebssystem: $OS_NAME" 1
    fi
    
    # Prüfe ob Docker bereits installiert ist
    if command_exists docker; then
        local current_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_warn "Docker ist bereits installiert: Version $current_version"
        
        if ! ask_yes_no "Docker neu installieren?"; then
            log_info "Installation abgebrochen"
            exit 0
        fi
    fi
    
    log_success "Voraussetzungen erfüllt"
}

remove_old_docker() {
    log_step "Entferne alte Docker-Versionen..."
    
    local old_packages=(
        docker
        docker-engine
        docker.io
        containerd
        runc
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )
    
    case "$(get_package_manager)" in
        apt)
            for pkg in "${old_packages[@]}"; do
                if pkg_is_installed "$pkg"; then
                    log_info "Entferne: $pkg"
                    apt-get remove -y -qq "$pkg" 2>/dev/null || true
                fi
            done
            ;;
        dnf|yum)
            for pkg in "${old_packages[@]}"; do
                if pkg_is_installed "$pkg"; then
                    log_info "Entferne: $pkg"
                    yum remove -y -q "$pkg" 2>/dev/null || true
                fi
            done
            ;;
    esac
    
    # Alte Docker-Daten behalten
    if [[ -d /var/lib/docker ]]; then
        log_warn "Docker-Daten bleiben in /var/lib/docker erhalten"
    fi
    
    log_success "Alte Versionen entfernt"
}

install_dependencies() {
    log_step "Installiere Abhängigkeiten..."
    
    if is_debian_based; then
        pkg_ensure_installed \
            ca-certificates \
            curl \
            gnupg \
            lsb-release \
            apt-transport-https \
            software-properties-common
    elif is_redhat_based; then
        pkg_ensure_installed \
            yum-utils \
            device-mapper-persistent-data \
            lvm2
    fi
    
    log_success "Abhängigkeiten installiert"
}

setup_docker_repository_debian() {
    log_step "Richte Docker Repository ein (Debian/Ubuntu)..."
    
    # GPG-Key hinzufügen
    install -m 0755 -d /etc/apt/keyrings
    
    log_info "Lade Docker GPG-Key..."
    curl -fsSL "https://download.docker.com/linux/${OS_NAME}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Repository hinzufügen
    log_info "Füge Docker Repository hinzu..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/${OS_NAME} \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    pkg_update
    
    log_success "Repository eingerichtet"
}

setup_docker_repository_redhat() {
    log_step "Richte Docker Repository ein (CentOS/Fedora)..."
    
    local repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
    
    if is_fedora; then
        repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
    fi
    
    log_info "Füge Docker Repository hinzu..."
    yum-config-manager --add-repo "$repo_url"
    
    log_success "Repository eingerichtet"
}

install_docker_engine() {
    log_step "Installiere Docker Engine..."
    
    if is_debian_based; then
        pkg_install \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    elif is_redhat_based; then
        pkg_install \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    fi
    
    log_success "Docker Engine installiert"
}

install_docker_compose_standalone() {
    if [[ "$INSTALL_COMPOSE" != "true" ]]; then
        return 0
    fi
    
    log_step "Installiere Docker Compose (standalone)..."
    
    # Neueste Version ermitteln
    log_info "Ermittle neueste Docker Compose Version..."
    local compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | \
        grep -oP '"tag_name": "\K(.*)(?=")' || echo "v2.24.0")
    
    log_info "Installiere Version: $compose_version"
    
    # Download und Installation
    curl -L "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    
    chmod +x /usr/local/bin/docker-compose
    
    # Symlink erstellen
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    
    log_success "Docker Compose installiert: $compose_version"
}

configure_docker_service() {
    if [[ "$ENABLE_SERVICE" != "true" ]]; then
        return 0
    fi
    
    log_step "Konfiguriere Docker Service..."
    
    # Service aktivieren und starten
    systemctl enable docker
    systemctl start docker
    
    # Warte bis Docker bereit ist
    local max_wait=30
    local count=0
    while ! docker info &>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [[ $count -ge $max_wait ]]; then
            die "Docker Service konnte nicht gestartet werden!" 1
        fi
    done
    
    log_success "Docker Service läuft"
}

add_user_to_docker_group() {
    if [[ "$ADD_CURRENT_USER" != "true" ]] || [[ -z "$DOCKER_USER" ]]; then
        return 0
    fi
    
    log_step "Füge Benutzer zur docker-Gruppe hinzu..."
    
    # Docker-Gruppe erstellen (falls nicht vorhanden)
    if ! getent group docker &>/dev/null; then
        groupadd docker
    fi
    
    # User hinzufügen
    if id "$DOCKER_USER" &>/dev/null; then
        usermod -aG docker "$DOCKER_USER"
        log_success "Benutzer '$DOCKER_USER' zur docker-Gruppe hinzugefügt"
        log_warn "Bitte neu einloggen, damit die Gruppen-Änderung wirksam wird!"
    else
        log_warn "Benutzer '$DOCKER_USER' nicht gefunden, überspringe"
    fi
}

configure_docker_daemon() {
    log_step "Konfiguriere Docker Daemon..."
    
    local daemon_config="/etc/docker/daemon.json"
    
    # Backup erstellen falls vorhanden
    if [[ -f "$daemon_config" ]]; then
        create_backup "$daemon_config"
    fi
    
    # Standard-Konfiguration erstellen
    cat > "$daemon_config" << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF
    
    # Docker neu laden
    systemctl daemon-reload
    systemctl restart docker
    
    log_success "Docker Daemon konfiguriert"
}

verify_installation() {
    log_step "Verifiziere Installation..."
    
    # Docker Version
    local docker_version=$(docker --version)
    log_info "Docker: $docker_version"
    
    # Docker Compose Version (Plugin)
    if docker compose version &>/dev/null; then
        local compose_version=$(docker compose version)
        log_info "Docker Compose Plugin: $compose_version"
    fi
    
    # Docker Compose Version (Standalone)
    if command_exists docker-compose; then
        local compose_standalone=$(docker-compose --version)
        log_info "Docker Compose Standalone: $compose_standalone"
    fi
    
    # Test-Container ausführen
    log_info "Führe Test-Container aus..."
    if docker run --rm hello-world &>/dev/null; then
        log_success "Test-Container erfolgreich ausgeführt"
    else
        log_warn "Test-Container konnte nicht ausgeführt werden"
    fi
    
    log_success "Installation erfolgreich verifiziert"
}

show_post_install_info() {
    echo
    log_success "═══════════════════════════════════════"
    log_success "  Docker Installation abgeschlossen!"
    log_success "═══════════════════════════════════════"
    echo
    log_info "Nächste Schritte:"
    echo
    
    if [[ -n "$DOCKER_USER" ]]; then
        echo "  1. Neu einloggen, damit Gruppen-Änderungen wirksam werden:"
        echo "     exit"
        echo "     ssh $DOCKER_USER@$(hostname)"
        echo
    fi
    
    echo "  2. Docker testen:"
    echo "     docker run hello-world"
    echo
    echo "  3. Docker Compose testen:"
    echo "     docker compose version"
    echo
    echo "  4. Beispiel-Container starten:"
    echo "     docker run -d -p 8080:80 nginx"
    echo
    
    log_info "Dokumentation: https://docs.docker.com/"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    remove_old_docker
    install_dependencies
    
    if is_debian_based; then
        setup_docker_repository_debian
