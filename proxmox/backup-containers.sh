#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox Container/VM Backup Manager
# Beschreibung: Automatisches Backup-Management für Container und VMs
# Autor: matdan1987
# Version: 1.0.0
# Features: Backup, Restore, Rotation, Kompression, Snapshots
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

BACKUP_DIR="${BACKUP_DIR:-/var/lib/vz/dump}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
COMPRESSION="${COMPRESSION:-zstd}"  # zstd, gzip, lzo, none

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Proxmox Backup Manager"
    echo
}

list_backups() {
    local vmid="${1:-}"

    log_info "Verfügbare Backups"
    echo

    if [[ -z "$vmid" ]]; then
        # Alle Backups
        find "$BACKUP_DIR" -type f -name "*.tar.*" -o -name "*.vma.*" 2>/dev/null | while read -r backup; do
            local filename=$(basename "$backup")
            local size=$(du -h "$backup" | awk '{print $1}')
            local date=$(stat -c %y "$backup" | awk '{print $1, $2}' | cut -d'.' -f1)
            printf "  %-50s %10s  %s\n" "$filename" "$size" "$date"
        done | sort
    else
        # Backups für spezifische VMID
        find "$BACKUP_DIR" -type f \( -name "vzdump-*-${vmid}-*.tar.*" -o -name "vzdump-*-${vmid}-*.vma.*" \) 2>/dev/null | while read -r backup; do
            local filename=$(basename "$backup")
            local size=$(du -h "$backup" | awk '{print $1}')
            local date=$(stat -c %y "$backup" | cut -d'.' -f1)
            printf "  %-50s %10s  %s\n" "$filename" "$size" "$date"
        done | sort
    fi
    echo
}

backup_container() {
    local vmid="$1"
    local mode="${2:-snapshot}"  # snapshot, suspend, stop

    log_step "Erstelle Backup für Container/VM $vmid"

    local type=$(get_vmid_type "$vmid")
    if [[ "$type" == "none" ]]; then
        log_error "VMID $vmid nicht gefunden"
        return 1
    fi

    local backup_file="$BACKUP_DIR/vzdump-${type}-${vmid}-$(date +%Y_%m_%d-%H_%M_%S).tar"

    if [[ "$type" == "lxc" ]]; then
        log_info "Sichere LXC Container $vmid (Modus: $mode)..."
        vzdump "$vmid" --storage local --mode "$mode" --compress "$COMPRESSION" --remove 0
    elif [[ "$type" == "vm" ]]; then
        log_info "Sichere VM $vmid (Modus: $mode)..."
        vzdump "$vmid" --storage local --mode "$mode" --compress "$COMPRESSION" --remove 0
    fi

    log_success "Backup erstellt für VMID $vmid"
}

backup_all() {
    local mode="${1:-snapshot}"

    log_step "Erstelle Backups für alle Container und VMs"

    local total=0
    local success=0
    local failed=0

    # LXC Container
    while read -r vmid; do
        [[ -z "$vmid" ]] && continue
        total=$((total + 1))
        if backup_container "$vmid" "$mode"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(pct list 2>/dev/null | tail -n +2 | awk '{print $1}')

    # VMs
    while read -r vmid; do
        [[ -z "$vmid" ]] && continue
        total=$((total + 1))
        if backup_container "$vmid" "$mode"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(qm list 2>/dev/null | tail -n +2 | awk '{print $1}')

    echo
    log_info "Backup-Zusammenfassung:"
    echo "  Total:       $total"
    echo "  Erfolgreich: $success"
    echo "  Fehlgeschlagen: $failed"
    echo
}

backup_running_only() {
    local mode="${1:-snapshot}"

    log_step "Erstelle Backups nur für laufende Container/VMs"

    local total=0
    local success=0

    # Laufende LXC Container
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $2}')

        if [[ "$status" == "running" ]]; then
            total=$((total + 1))
            if backup_container "$vmid" "$mode"; then
                success=$((success + 1))
            fi
        fi
    done < <(pct list 2>/dev/null | tail -n +2)

    # Laufende VMs
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid=$(echo "$line" | awk '{print $1}')
        local status=$(echo "$line" | awk '{print $3}')

        if [[ "$status" == "running" ]]; then
            total=$((total + 1))
            if backup_container "$vmid" "$mode"; then
                success=$((success + 1))
            fi
        fi
    done < <(qm list 2>/dev/null | tail -n +2)

    echo
    log_success "$success von $total laufenden Containern/VMs gesichert"
}

cleanup_old_backups() {
    local days="${1:-$RETENTION_DAYS}"

    log_step "Lösche Backups älter als $days Tage"

    local count=0
    local freed_space=0

    while read -r backup; do
        local size=$(stat -c%s "$backup" 2>/dev/null || echo 0)
        freed_space=$((freed_space + size))
        rm -f "$backup"
        count=$((count + 1))
        log_debug "Gelöscht: $(basename "$backup")"
    done < <(find "$BACKUP_DIR" -type f -mtime "+$days" \( -name "*.tar.*" -o -name "*.vma.*" \) 2>/dev/null)

    if [[ $count -gt 0 ]]; then
        local freed_mb=$((freed_space / 1024 / 1024))
        log_success "$count Backups gelöscht, ${freed_mb}MB freigegeben"
    else
        log_info "Keine alten Backups gefunden"
    fi
}

restore_container() {
    local backup_file="$1"
    local vmid="${2:-}"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup-Datei nicht gefunden: $backup_file"
        return 1
    fi

    log_step "Stelle Container/VM wieder her"
    log_info "Backup: $(basename "$backup_file")"

    if [[ -n "$vmid" ]]; then
        log_info "Ziel-VMID: $vmid"
        pct restore "$vmid" "$backup_file"
    else
        log_info "Verwende Original-VMID"
        # Extrahiere VMID aus Dateinamen
        local original_vmid=$(basename "$backup_file" | grep -oP 'vzdump-[^-]+-\K[0-9]+')
        pct restore "$original_vmid" "$backup_file"
    fi

    log_success "Wiederherstellung abgeschlossen"
}

show_backup_stats() {
    log_info "Backup-Statistiken"
    echo

    local total_backups=$(find "$BACKUP_DIR" -type f \( -name "*.tar.*" -o -name "*.vma.*" \) 2>/dev/null | wc -l)
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    local oldest=$(find "$BACKUP_DIR" -type f \( -name "*.tar.*" -o -name "*.vma.*" \) -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | awk '{print $1}')
    local newest=$(find "$BACKUP_DIR" -type f \( -name "*.tar.*" -o -name "*.vma.*" \) -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1 | awk '{print $1}')

    echo "  Backup-Verzeichnis: $BACKUP_DIR"
    echo "  Anzahl Backups:     $total_backups"
    echo "  Gesamtgröße:        $total_size"
    echo "  Ältestes Backup:    ${oldest:-N/A}"
    echo "  Neuestes Backup:    ${newest:-N/A}"
    echo "  Retention:          $RETENTION_DAYS Tage"
    echo

    # Backups pro VMID
    log_info "Backups pro Container/VM:"
    echo
    printf "  %-8s %s\n" "VMID" "Anzahl"
    printf "  %-8s %s\n" "--------" "------"
    find "$BACKUP_DIR" -type f \( -name "*.tar.*" -o -name "*.vma.*" \) 2>/dev/null | while read -r backup; do
        basename "$backup" | grep -oP 'vzdump-[^-]+-\K[0-9]+'
    done | sort | uniq -c | while read -r count vmid; do
        printf "  %-8s %s\n" "$vmid" "$count"
    done
    echo
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

show_usage() {
    cat << EOF
Verwendung: $0 [OPTIONEN] [VMID]

Proxmox Backup Manager für Container und VMs.

Optionen:
    -h, --help              Zeigt diese Hilfe an
    -l, --list [VMID]       Listet alle Backups auf (optional für spezifische VMID)
    -b, --backup VMID       Erstellt Backup für spezifische VMID
    -a, --backup-all        Erstellt Backups für alle Container/VMs
    -r, --running-only      Backup nur für laufende Container/VMs
    -c, --cleanup [DAYS]    Löscht Backups älter als X Tage (Standard: $RETENTION_DAYS)
    -s, --stats             Zeigt Backup-Statistiken
    --restore FILE [VMID]   Stellt Backup wieder her
    --mode MODE             Backup-Modus: snapshot, suspend, stop (Standard: snapshot)

Umgebungsvariablen:
    BACKUP_DIR              Backup-Verzeichnis (Standard: $BACKUP_DIR)
    RETENTION_DAYS          Aufbewahrungszeit in Tagen (Standard: $RETENTION_DAYS)
    COMPRESSION             Kompression: zstd, gzip, lzo, none (Standard: $COMPRESSION)

Beispiele:
    $0 --list               # Alle Backups anzeigen
    $0 --list 100           # Backups für Container 100 anzeigen
    $0 --backup 100         # Backup für Container 100 erstellen
    $0 --backup-all         # Alle Container/VMs sichern
    $0 --running-only       # Nur laufende Container sichern
    $0 --cleanup 7          # Backups älter als 7 Tage löschen
    $0 --stats              # Statistiken anzeigen
    $0 --restore /path/to/backup.tar.zst 200  # Backup wiederherstellen als VMID 200
EOF
}

main() {
    require_proxmox

    local action=""
    local vmid=""
    local backup_file=""
    local mode="snapshot"
    local cleanup_days="$RETENTION_DAYS"

    # Parse Argumente
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -l|--list)
                action="list"
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    vmid="$2"
                    shift
                fi
                shift
                ;;
            -b|--backup)
                action="backup"
                vmid="$2"
                shift 2
                ;;
            -a|--backup-all)
                action="backup-all"
                shift
                ;;
            -r|--running-only)
                action="running-only"
                shift
                ;;
            -c|--cleanup)
                action="cleanup"
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    cleanup_days="$2"
                    shift
                fi
                shift
                ;;
            -s|--stats)
                action="stats"
                shift
                ;;
            --restore)
                action="restore"
                backup_file="$2"
                if [[ -n "$3" ]] && [[ "$3" != -* ]]; then
                    vmid="$3"
                    shift
                fi
                shift 2
                ;;
            --mode)
                mode="$2"
                shift 2
                ;;
            *)
                log_error "Unbekannte Option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    show_banner

    case "$action" in
        list)
            list_backups "$vmid"
            ;;
        backup)
            if [[ -z "$vmid" ]]; then
                log_error "VMID erforderlich für --backup"
                exit 1
            fi
            backup_container "$vmid" "$mode"
            ;;
        backup-all)
            backup_all "$mode"
            ;;
        running-only)
            backup_running_only "$mode"
            ;;
        cleanup)
            cleanup_old_backups "$cleanup_days"
            ;;
        stats)
            show_backup_stats
            ;;
        restore)
            if [[ -z "$backup_file" ]]; then
                log_error "Backup-Datei erforderlich für --restore"
                exit 1
            fi
            restore_container "$backup_file" "$vmid"
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac

    exit 0
}

set +e
trap '' ERR

main "$@"
