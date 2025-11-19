#!/usr/bin/env bash
# ==============================================================================
# Script: Jellyfin LXC Creator
# Beschreibung: Erstellt LXC mit Jellyfin (Free Media System)
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
HOSTNAME=${HOSTNAME:-jellyfin}
MEMORY=${MEMORY:-4096}
DISK=${DISK:-20}
CORES=${CORES:-4}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

JELLYFIN_PORT=${JELLYFIN_PORT:-8096}
JELLYFIN_HTTPS_PORT=${JELLYFIN_HTTPS_PORT:-8920}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Jellyfin Media Server LXC"
    log_info "The Free Software Media System"
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

install_jellyfin() {
    log_step "Installiere Jellyfin..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # Dependencies installieren
    lxc_install_package "$VMID" curl gnupg apt-transport-https ca-certificates

    # Jellyfin Repository hinzufügen
    lxc_exec "$VMID" bash -c "
        curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/jellyfin.gpg
        echo 'deb [arch=amd64] https://repo.jellyfin.org/debian bookworm main' > /etc/apt/sources.list.d/jellyfin.list
    "

    # Jellyfin installieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get install -y jellyfin"

    # Media-Verzeichnisse erstellen
    lxc_exec "$VMID" bash -c "
        mkdir -p /media/{movies,tvshows,music,photos}
        chown -R jellyfin:jellyfin /media
    "

    # Hardware-Beschleunigung (Intel Quick Sync) vorbereiten
    lxc_exec "$VMID" bash -c "
        if [ -d /dev/dri ]; then
            usermod -aG video jellyfin
            usermod -aG render jellyfin
        fi
    "

    log_success "Jellyfin installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "Jellyfin LXC erfolgreich erstellt!"
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
    echo "  Web UI:        http://$ip:$JELLYFIN_PORT"
    echo "  HTTPS:         https://$ip:$JELLYFIN_HTTPS_PORT"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Media-Verzeichnisse:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Filme:         /media/movies"
    echo "  TV-Serien:     /media/tvshows"
    echo "  Musik:         /media/music"
    echo "  Fotos:         /media/photos"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Nächste Schritte:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  1. UI öffnen: http://$ip:$JELLYFIN_PORT"
    echo "  2. Setup-Wizard durchlaufen"
    echo "  3. Admin-Account erstellen"
    echo "  4. Medienbibliotheken hinzufügen"
    echo
    echo "  Medien hinzufügen (vom Proxmox-Host):"
    echo "    pct push $VMID /path/to/movie.mp4 /media/movies/movie.mp4"
    echo
    echo "  Oder Bind Mount von Host einrichten:"
    echo "    pct set $VMID -mp0 /mnt/media,mp=/media"
    echo
    echo "  Hardware-Beschleunigung aktivieren (Intel Quick Sync):"
    echo "    pct set $VMID -dev0 /dev/dri/renderD128"
    echo
    echo "  Status prüfen:"
    echo "    pct exec $VMID -- systemctl status jellyfin"
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
    install_jellyfin
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
