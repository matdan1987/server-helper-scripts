#!/usr/bin/env bash
# ==============================================================================
# Script: Nextcloud LXC Creator
# Beschreibung: Erstellt LXC mit Nextcloud (Self-Hosted Cloud)
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
HOSTNAME=${HOSTNAME:-nextcloud}
MEMORY=${MEMORY:-4096}
DISK=${DISK:-50}
CORES=${CORES:-4}
STORAGE=${STORAGE:-$(get_best_storage)}
BRIDGE=${BRIDGE:-vmbr0}

NEXTCLOUD_PORT=${NEXTCLOUD_PORT:-80}
DB_PASSWORD=$(openssl rand -base64 16)
ADMIN_PASSWORD=$(openssl rand -base64 16)

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Nextcloud LXC Container"
    log_info "A Safe Home for All Your Data"
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

install_nextcloud() {
    log_step "Installiere Nextcloud..."

    wait_for_lxc "$VMID"

    # System aktualisieren
    lxc_exec "$VMID" bash -c "apt-get update && apt-get upgrade -y"

    # LAMP Stack installieren
    lxc_install_package "$VMID" apache2 mariadb-server

    # PHP und benötigte Extensions
    lxc_install_package "$VMID" php php-{apcu,bcmath,cli,common,curl,gd,gmp,imagick,intl,mbstring,mysql,zip,xml}
    lxc_install_package "$VMID" libmagickcore-6.q16-6-extra wget unzip

    # MariaDB konfigurieren
    lxc_exec "$VMID" bash -c "
        mysql -e \"CREATE DATABASE IF NOT EXISTS nextcloud;\"
        mysql -e \"CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';\"
        mysql -e \"GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';\"
        mysql -e \"FLUSH PRIVILEGES;\"
    "

    # Nextcloud herunterladen
    lxc_exec "$VMID" bash -c "
        cd /tmp
        wget https://download.nextcloud.com/server/releases/latest.zip
        unzip -q latest.zip
        mv nextcloud /var/www/
        chown -R www-data:www-data /var/www/nextcloud
    "

    # Apache VHost konfigurieren
    lxc_exec "$VMID" bash -c "cat > /etc/apache2/sites-available/nextcloud.conf << 'EOF'
<VirtualHost *:80>
    ServerAdmin admin@localhost
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        SetEnv HOME /var/www/nextcloud
        SetEnv HTTP_HOME /var/www/nextcloud
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF
"

    # Apache Module aktivieren
    lxc_exec "$VMID" bash -c "
        a2ensite nextcloud.conf
        a2enmod rewrite headers env dir mime setenvif ssl
        a2dissite 000-default.conf
        systemctl reload apache2
    "

    # Nextcloud Installation
    lxc_exec "$VMID" bash -c "
        cd /var/www/nextcloud
        sudo -u www-data php occ maintenance:install \
            --database='mysql' \
            --database-name='nextcloud' \
            --database-user='nextcloud' \
            --database-pass='${DB_PASSWORD}' \
            --admin-user='admin' \
            --admin-pass='${ADMIN_PASSWORD}'
    "

    # Trusted Domains konfigurieren
    local ip=$(get_ip_for_vmid "$VMID")
    lxc_exec "$VMID" bash -c "
        cd /var/www/nextcloud
        sudo -u www-data php occ config:system:set trusted_domains 1 --value='$ip'
    "

    # Cron-Job einrichten
    lxc_exec "$VMID" bash -c "
        crontab -u www-data -l 2>/dev/null | { cat; echo '*/5 * * * * php -f /var/www/nextcloud/cron.php'; } | crontab -u www-data -
        sudo -u www-data php /var/www/nextcloud/occ background:cron
    "

    log_success "Nextcloud installiert"
}

show_info() {
    local ip=$(get_ip_for_vmid "$VMID")

    echo
    log_success "Nextcloud LXC erfolgreich erstellt!"
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
    echo "  Nextcloud:     http://$ip"
    echo
    echo "  Admin-Login:"
    echo "    Benutzer:    admin"
    echo "    Passwort:    $ADMIN_PASSWORD"
    echo
    echo "  Datenbank:"
    echo "    Typ:         MariaDB"
    echo "    Name:        nextcloud"
    echo "    User:        nextcloud"
    echo "    Passwort:    $DB_PASSWORD"
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Nächste Schritte:"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  1. UI öffnen: http://$ip"
    echo "  2. Mit Admin-Credentials einloggen"
    echo "  3. Apps installieren (Office, Talk, Calendar, etc.)"
    echo "  4. Benutzer anlegen"
    echo
    echo "  WICHTIG: Passwörter sicher aufbewahren!"
    echo
    echo "  Empfohlene Apps:"
    echo "    - Nextcloud Office (Collabora/OnlyOffice)"
    echo "    - Nextcloud Talk (Video-Calls)"
    echo "    - Calendar & Contacts"
    echo "    - Notes"
    echo "    - Tasks"
    echo
    echo "  Performance optimieren:"
    echo "    pct exec $VMID -- sudo -u www-data php /var/www/nextcloud/occ db:add-missing-indices"
    echo "    pct exec $VMID -- sudo -u www-data php /var/www/nextcloud/occ db:convert-filecache-bigint"
    echo
    echo "  Für HTTPS:"
    echo "    - Reverse Proxy (nginx/caddy) einrichten"
    echo "    - Let's Encrypt Zertifikat"
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
    install_nextcloud
    show_info

    exit 0
}

set +e
trap '' ERR

main "$@"
