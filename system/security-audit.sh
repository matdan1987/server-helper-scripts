#!/usr/bin/env bash
# ==============================================================================
# Script: System Security Audit
# Beschreibung: Führt Sicherheitsüberprüfung des Systems durch
# Autor: matdan1987
# Version: 1.0.0
# Features: SSH, Firewall, Updates, User, Permissions, Services Check
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

    LIB_DIR="$LIB_TMP"
    trap "rm -rf '$LIB_TMP'" EXIT
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
fi

source "$LIB_DIR/common.sh"

# =============================================================================
# KONFIGURATION
# =============================================================================

REPORT_FILE="${REPORT_FILE:-/tmp/security-audit-$(date +%Y%m%d-%H%M%S).txt}"
SCORE=0
MAX_SCORE=0
ISSUES=()

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "System Security Audit"
    echo
}

add_check() {
    local category="$1"
    local description="$2"
    local status="$3"  # pass, fail, warn
    local points="${4:-1}"

    MAX_SCORE=$((MAX_SCORE + points))

    case "$status" in
        pass)
            SCORE=$((SCORE + points))
            echo -e "  ${GREEN}✓${NC} $description"
            ;;
        fail)
            echo -e "  ${RED}✗${NC} $description"
            ISSUES+=("[$category] $description")
            ;;
        warn)
            SCORE=$((SCORE + points / 2))
            echo -e "  ${YELLOW}⚠${NC} $description"
            ISSUES+=("[$category] (Warning) $description")
            ;;
    esac
}

check_ssh_security() {
    log_info "SSH Sicherheit"
    echo

    local ssh_config="/etc/ssh/sshd_config"

    # Root Login
    if grep -q "^PermitRootLogin no" "$ssh_config" 2>/dev/null; then
        add_check "SSH" "Root-Login deaktiviert" "pass" 2
    else
        add_check "SSH" "Root-Login aktiviert (Sicherheitsrisiko!)" "fail" 2
    fi

    # Password Authentication
    if grep -q "^PasswordAuthentication no" "$ssh_config" 2>/dev/null; then
        add_check "SSH" "Passwort-Authentifizierung deaktiviert" "pass" 2
    else
        add_check "SSH" "Passwort-Authentifizierung aktiviert" "warn" 2
    fi

    # SSH Port
    local ssh_port=$(grep "^Port" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "22")
    if [[ "$ssh_port" != "22" ]]; then
        add_check "SSH" "SSH läuft auf nicht-Standard Port ($ssh_port)" "pass" 1
    else
        add_check "SSH" "SSH läuft auf Standard-Port 22" "warn" 1
    fi

    # SSH Protocol
    if grep -q "^Protocol 2" "$ssh_config" 2>/dev/null || ! grep -q "^Protocol" "$ssh_config" 2>/dev/null; then
        add_check "SSH" "SSH Protocol 2 aktiv" "pass" 1
    else
        add_check "SSH" "Unsicheres SSH Protocol" "fail" 1
    fi

    echo
}

check_firewall() {
    log_info "Firewall Status"
    echo

    # UFW
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            add_check "Firewall" "UFW aktiv" "pass" 2
        else
            add_check "Firewall" "UFW installiert aber inaktiv" "fail" 2
        fi
    # iptables
    elif command -v iptables &>/dev/null; then
        local rules=$(iptables -L 2>/dev/null | grep -v "^Chain" | grep -v "^target" | wc -l)
        if [[ $rules -gt 0 ]]; then
            add_check "Firewall" "iptables Regeln aktiv ($rules Regeln)" "pass" 2
        else
            add_check "Firewall" "iptables ohne Regeln" "fail" 2
        fi
    # firewalld
    elif command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state 2>/dev/null | grep -q "running"; then
            add_check "Firewall" "firewalld aktiv" "pass" 2
        else
            add_check "Firewall" "firewalld inaktiv" "fail" 2
        fi
    else
        add_check "Firewall" "Keine Firewall gefunden!" "fail" 2
    fi

    echo
}

check_updates() {
    log_info "System Updates"
    echo

    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        local updates=$(apt-get -s upgrade 2>/dev/null | grep -P '^\d+ upgraded' | awk '{print $1}')

        if [[ "$updates" == "0" ]]; then
            add_check "Updates" "System aktuell (keine ausstehenden Updates)" "pass" 2
        elif [[ "$updates" -lt 10 ]]; then
            add_check "Updates" "$updates Updates verfügbar" "warn" 2
        else
            add_check "Updates" "$updates Updates verfügbar (dringend aktualisieren!)" "fail" 2
        fi

        # Security Updates
        local security_updates=$(apt-get -s upgrade 2>/dev/null | grep -i security | wc -l)
        if [[ "$security_updates" -eq 0 ]]; then
            add_check "Updates" "Keine Sicherheitsupdates ausstehend" "pass" 1
        else
            add_check "Updates" "$security_updates Sicherheitsupdates verfügbar!" "fail" 1
        fi
    fi

    echo
}

check_users() {
    log_info "Benutzer-Sicherheit"
    echo

    # Root Password
    if passwd -S root 2>/dev/null | grep -q "L"; then
        add_check "Users" "Root-Account gesperrt" "pass" 2
    else
        add_check "Users" "Root-Account aktiv" "warn" 2
    fi

    # Users with UID 0
    local uid0_users=$(awk -F: '$3 == 0 {print $1}' /etc/passwd | grep -v "^root$" | wc -l)
    if [[ $uid0_users -eq 0 ]]; then
        add_check "Users" "Keine zusätzlichen UID 0 Benutzer" "pass" 2
    else
        add_check "Users" "$uid0_users zusätzliche Benutzer mit UID 0!" "fail" 2
    fi

    # Empty Passwords
    local empty_passwords=$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null | wc -l)
    if [[ $empty_passwords -eq 0 ]]; then
        add_check "Users" "Keine Benutzer ohne Passwort" "pass" 1
    else
        add_check "Users" "$empty_passwords Benutzer ohne Passwort" "warn" 1
    fi

    # Sudo Users
    local sudo_users=$(getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n' | wc -l)
    add_check "Users" "$sudo_users Benutzer mit sudo-Rechten" "pass" 0

    echo
}

check_permissions() {
    log_info "Dateiberechtigungen"
    echo

    # World-writable files
    local world_writable=$(find / -xdev -type f -perm -0002 ! -path "/proc/*" ! -path "/sys/*" 2>/dev/null | wc -l)
    if [[ $world_writable -eq 0 ]]; then
        add_check "Permissions" "Keine world-writable Dateien gefunden" "pass" 2
    elif [[ $world_writable -lt 5 ]]; then
        add_check "Permissions" "$world_writable world-writable Dateien" "warn" 2
    else
        add_check "Permissions" "$world_writable world-writable Dateien!" "fail" 2
    fi

    # SUID Files
    local suid_files=$(find / -xdev -type f -perm -4000 ! -path "/proc/*" ! -path "/sys/*" 2>/dev/null | wc -l)
    add_check "Permissions" "$suid_files SUID-Dateien gefunden" "pass" 0

    # /etc/shadow permissions
    local shadow_perm=$(stat -c %a /etc/shadow 2>/dev/null)
    if [[ "$shadow_perm" == "640" ]] || [[ "$shadow_perm" == "600" ]]; then
        add_check "Permissions" "/etc/shadow korrekte Berechtigungen ($shadow_perm)" "pass" 1
    else
        add_check "Permissions" "/etc/shadow unsichere Berechtigungen ($shadow_perm)!" "fail" 1
    fi

    echo
}

check_services() {
    log_info "Dienste & Netzwerk"
    echo

    # Listening Services
    local listening=$(netstat -tuln 2>/dev/null | grep LISTEN | wc -l)
    add_check "Services" "$listening lauschende Dienste" "pass" 0

    # Check for unnecessary services
    local unnecessary_services=("telnet" "ftp" "rsh" "rlogin")
    local found_unnecessary=0

    for service in "${unnecessary_services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            add_check "Services" "Unsicherer Dienst aktiv: $service" "fail" 2
            found_unnecessary=$((found_unnecessary + 1))
        fi
    done

    if [[ $found_unnecessary -eq 0 ]]; then
        add_check "Services" "Keine unsicheren Dienste (telnet, ftp, rsh) aktiv" "pass" 2
    fi

    # fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        add_check "Services" "fail2ban aktiv (Brute-Force Schutz)" "pass" 2
    elif command -v fail2ban-client &>/dev/null; then
        add_check "Services" "fail2ban installiert aber inaktiv" "warn" 2
    else
        add_check "Services" "fail2ban nicht installiert" "warn" 2
    fi

    echo
}

check_kernel_security() {
    log_info "Kernel-Sicherheit"
    echo

    # ASLR
    local aslr=$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null)
    if [[ "$aslr" == "2" ]]; then
        add_check "Kernel" "ASLR vollständig aktiviert" "pass" 1
    else
        add_check "Kernel" "ASLR nicht optimal konfiguriert" "warn" 1
    fi

    # IP Forwarding
    local ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [[ "$ip_forward" == "0" ]]; then
        add_check "Kernel" "IP Forwarding deaktiviert" "pass" 1
    else
        add_check "Kernel" "IP Forwarding aktiviert" "warn" 1
    fi

    # SYN Cookies
    local syn_cookies=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null)
    if [[ "$syn_cookies" == "1" ]]; then
        add_check "Kernel" "SYN Cookies aktiviert (DDoS Schutz)" "pass" 1
    else
        add_check "Kernel" "SYN Cookies deaktiviert" "warn" 1
    fi

    echo
}

generate_report() {
    local percent=$((SCORE * 100 / MAX_SCORE))

    echo
    log_info "Security Score: $SCORE / $MAX_SCORE Punkte (${percent}%)"

    if [[ $percent -ge 90 ]]; then
        echo -e "  ${GREEN}Ausgezeichnet!${NC} Ihr System ist gut gesichert."
    elif [[ $percent -ge 70 ]]; then
        echo -e "  ${YELLOW}Gut${NC}, aber es gibt Verbesserungspotenzial."
    elif [[ $percent -ge 50 ]]; then
        echo -e "  ${YELLOW}Befriedigend${NC}. Mehrere Sicherheitsprobleme gefunden."
    else
        echo -e "  ${RED}Kritisch!${NC} Dringender Handlungsbedarf!"
    fi

    if [[ ${#ISSUES[@]} -gt 0 ]]; then
        echo
        log_warn "${#ISSUES[@]} Sicherheitsprobleme gefunden:"
        for issue in "${ISSUES[@]}"; do
            echo "  - $issue"
        done
    fi

    echo
}

save_report() {
    {
        echo "======================================================================"
        echo "System Security Audit Report"
        echo "Erstellt: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host: $(hostname)"
        echo "======================================================================"
        echo
        echo "Security Score: $SCORE / $MAX_SCORE Punkte ($((SCORE * 100 / MAX_SCORE))%)"
        echo
        echo "PROBLEME:"
        for issue in "${ISSUES[@]}"; do
            echo "  - $issue"
        done
        echo
        echo "======================================================================"
    } > "$REPORT_FILE"

    log_success "Report gespeichert: $REPORT_FILE"
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

show_usage() {
    cat << EOF
Verwendung: $0 [OPTIONEN]

Führt umfassende Sicherheitsüberprüfung des Systems durch.

Optionen:
    -h, --help          Zeigt diese Hilfe an
    -f, --full          Vollständiger Audit (Standard)
    -q, --quick         Schneller Audit (nur kritische Checks)
    -r, --report FILE   Speichert Report in Datei (Standard: $REPORT_FILE)
    --ssh-only          Nur SSH-Sicherheit prüfen
    --firewall-only     Nur Firewall prüfen
    --users-only        Nur Benutzer prüfen

Geprüfte Bereiche:
    - SSH-Konfiguration
    - Firewall-Status
    - System-Updates
    - Benutzer-Accounts
    - Dateiberechtigungen
    - Laufende Dienste
    - Kernel-Sicherheit

Beispiele:
    $0                              # Vollständiger Audit
    $0 --quick                      # Schneller Audit
    $0 --ssh-only                   # Nur SSH prüfen
    $0 --report /root/audit.txt     # Mit custom Report-Pfad
EOF
}

main() {
    require_root

    local mode="full"
    local save_to_file=false

    # Parse Argumente
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -f|--full)
                mode="full"
                shift
                ;;
            -q|--quick)
                mode="quick"
                shift
                ;;
            -r|--report)
                save_to_file=true
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    REPORT_FILE="$2"
                    shift
                fi
                shift
                ;;
            --ssh-only)
                mode="ssh"
                shift
                ;;
            --firewall-only)
                mode="firewall"
                shift
                ;;
            --users-only)
                mode="users"
                shift
                ;;
            *)
                log_error "Unbekannte Option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    show_banner

    case "$mode" in
        full)
            check_ssh_security
            check_firewall
            check_updates
            check_users
            check_permissions
            check_services
            check_kernel_security
            ;;
        quick)
            check_ssh_security
            check_firewall
            check_users
            ;;
        ssh)
            check_ssh_security
            ;;
        firewall)
            check_firewall
            ;;
        users)
            check_users
            ;;
    esac

    generate_report

    if [[ "$save_to_file" == true ]]; then
        save_report
    fi

    exit 0
}

set +e
trap '' ERR

main "$@"
