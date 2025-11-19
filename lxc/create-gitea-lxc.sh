#!/usr/bin/env bash
# ==============================================================================
# Script: Gitea LXC Creator
# Beschreibung: Erstellt LXC mit Gitea (Self-Hosted Git Service)
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

# =============================================================================
# PFAD-ERKENNUNG
# =============================================================================

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
HOSTNAME=${HOSTNAME:-gitea}
MEMORY=${MEMORY:-2048}
DISK=${DISK:-20}
CORES=${CORES:-2}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

GITEA_PORT=${GITEA_PORT:-3000}
SSH_PORT=${SSH_PORT:-2222}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Gitea LXC Container"
    log_info "Painless Self-Hosted Git Service"
    echo
    show_ip_allocation
}

create_container() {
    log_step "Erstelle LXC Container..."

    local ip=$(get_ip_for_vmid "$VMID")
    local network_config=$(create_network_string "$VMID" "$BRIDGE" "eth0")

    pct create "$VMID" local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --net0 "$network_config" \
        --features nesting=1 \
        --unprivileged 1 \
        --onboot 1 \
        --start 1

    log_success "Container erstellt: $VMID ($ip)"
}

install_gitea() {
    log_step "Installiere Gitea..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # Dependencies installieren
    lxc_install_package "$VMID" git curl wget sqlite3

    # Git User erstellen
    lxc_exec "$VMID" bash -c "adduser --system --group --disabled-password --home /home/git git"

    # Gitea herunterladen
    lxc_exec "$VMID" bash -c "
        cd /tmp
        wget -O gitea https://dl.gitea.com/gitea/1.21/gitea-1.21-linux-amd64
        chmod +x gitea
        mv gitea /usr/local/bin/gitea
    "

    # Verzeichnisse erstellen
    lxc_exec "$VMID" bash -c "
        mkdir -p /var/lib/gitea/{custom,data,log}
        chown -R git:git /var/lib/gitea/
        chmod -R 750 /var/lib/gitea/
        mkdir -p /etc/gitea
        chown root:git /etc/gitea
        chmod 770 /etc/gitea
    "

    # Systemd Service erstellen
    lxc_exec "$VMID" bash -c "cat > /etc/systemd/system/gitea.service << 'EOF'
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target

[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF
"

    # Initiale Konfiguration
    lxc_exec "$VMID" bash -c "cat > /etc/gitea/app.ini << EOF
[server]
HTTP_PORT = ${GITEA_PORT}
DOMAIN = $(get_ip_for_vmid "$VMID")
ROOT_URL = http://$(get_ip_for_vmid "$VMID"):${GITEA_PORT}/
SSH_PORT = ${SSH_PORT}

[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/data/gitea.db

[repository]
ROOT = /var/lib/gitea/data/gitea-repositories

[security]
INSTALL_LOCK = false
SECRET_KEY = $(openssl rand -base64 32)
INTERNAL_TOKEN = $(openssl rand -base64 32)

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW = false
EOF
"

    lxc_exec "$VMID" bash -c "chown git:git /etc/gitea/app.ini"

    # Service aktivieren und starten
    lxc_exec "$VMID" bash -c "systemctl daemon-reload && systemctl enable --now gitea"

    log_success "Gitea installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "Gitea LXC erfolgreich erstellt!"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Container-Info"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  VMID:          $VMID"
    echo "  Hostname:      $HOSTNAME"
    echo "  IP:            $ip"
    echo "  Memory:        ${MEMORY}MB"
    echo "  Disk:          ${DISK}GB"
    echo "  Cores:         $CORES"
    echo
    echo "  Web UI:        http://$ip:$GITEA_PORT"
    echo "  SSH:           ssh://git@$ip:$SSH_PORT"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Nächste Schritte:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  1. UI öffnen: http://$ip:$GITEA_PORT"
    echo "  2. Installation durchlaufen (Datenbank bereits konfiguriert)"
    echo "  3. Admin-Account erstellen"
    echo "  4. Repositories erstellen"
    echo
    echo "  Repository klonen:"
    echo "    git clone http://$ip:$GITEA_PORT/username/repo.git"
    echo
    echo "  Status prüfen:"
    echo "    pct exec $VMID -- systemctl status gitea"
    echo
    echo "  Logs:"
    echo "    pct exec $VMID -- journalctl -u gitea -f"
    echo "═══════════════════════════════════════════════════════════════"
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    require_root
    require_proxmox

    show_banner
    create_container
    install_gitea
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
