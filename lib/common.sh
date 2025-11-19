#!/usr/bin/env bash
# common.sh - Wiederverwendbare Basis-Funktionen für alle Scripts
# Version: 1.0.0

# Strikte Fehlerbehandlung
set -euo pipefail

# Farben für Terminal-Ausgabe
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export MAGENTA='\033[0;35m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# Script-Informationen
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
START_TIME=$(date +%s)

# =============================================================================
# LOGGING-FUNKTIONEN
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"
    fi
}

log_step() {
    echo -e "\n${CYAN}▶${NC} $*"
}

# =============================================================================
# FEHLERBEHANDLUNG
# =============================================================================

die() {
    log_error "$1"
    exit "${2:-1}"
}

# Cleanup-Funktion für Trap
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script wurde mit Fehlercode $exit_code beendet!"
    fi
}

# Trap für Cleanup
trap cleanup EXIT

# =============================================================================
# VALIDIERUNGS-FUNKTIONEN
# =============================================================================

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Dieses Script muss als root ausgeführt werden! Nutze: sudo $SCRIPT_NAME" 1
    fi
}

require_command() {
    local cmd="$1"
    local package="${2:-$cmd}"
    
    if ! command -v "$cmd" &> /dev/null; then
        die "Erforderlicher Befehl '$cmd' nicht gefunden! Installiere: $package" 1
    fi
}

command_exists() {
    command -v "$1" &> /dev/null
}

# =============================================================================
# INTERAKTIVE FUNKTIONEN
# =============================================================================

ask_yes_no() {
    local question="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        local prompt="[J/n]"
    else
        local prompt="[j/N]"
    fi
    
    while true; do
        read -rp "$question $prompt: " answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            j|ja|y|yes ) return 0 ;;
            n|nein|no ) return 1 ;;
            * ) echo "Bitte mit j (ja) oder n (nein) antworten." ;;
        esac
    done
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value
    
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " value
        echo "${value:-$default}"
    else
        read -rp "$prompt: " value
        echo "$value"
    fi
}

# =============================================================================
# DATEI-OPERATIONEN
# =============================================================================

create_backup() {
    local file="$1"
    local backup_dir="${2:-/var/backups/helper-scripts}"
    
    if [[ -f "$file" ]]; then
        mkdir -p "$backup_dir"
        local backup_file="$backup_dir/$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
        cp "$file" "$backup_file"
        log_info "Backup erstellt: $backup_file"
        echo "$backup_file"
    fi
}

safe_replace() {
    local file="$1"
    local search="$2"
    local replace="$3"
    
    create_backup "$file"
    sed -i "s|$search|$replace|g" "$file"
}

append_if_not_exists() {
    local file="$1"
    local line="$2"
    
    if ! grep -qF "$line" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
        log_debug "Zeile zu $file hinzugefügt: $line"
    fi
}

# =============================================================================
# FORTSCHRITTS-ANZEIGE
# =============================================================================

spinner() {
    local pid=$1
    local message="${2:-Verarbeite}"
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " ${CYAN}%c${NC} $message..." "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
    done
    printf "    \r"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local prefix="${3:-Fortschritt}"
    
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    
    printf "\r%s: [" "$prefix"
    printf "%${completed}s" | tr ' ' '█'
    printf "%$((width - completed))s" | tr ' ' '░'
    printf "] %3d%%" "$percentage"
    
    if [[ $current -eq $total ]]; then
        echo
    fi
}

# =============================================================================
# SYSTEM-INFORMATIONEN
# =============================================================================

get_total_memory() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

get_free_memory() {
    awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo
}

get_disk_usage() {
    df -h / | awk 'NR==2 {print $5}' | sed 's/%//'
}

get_cpu_count() {
    nproc
}

# =============================================================================
# NETZWERK-FUNKTIONEN
# =============================================================================

get_primary_ip() {
    ip route get 1 | awk '{print $7}' | head -1
}

get_public_ip() {
    curl -s ifconfig.me || curl -s icanhazip.com || echo "N/A"
}

is_port_open() {
    local port=$1
    netstat -tuln | grep -q ":$port "
}

# =============================================================================
# ZEIT-FUNKTIONEN
# =============================================================================

show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    
    if [[ $minutes -gt 0 ]]; then
        log_info "Ausführungszeit: ${minutes}m ${seconds}s"
    else
        log_info "Ausführungszeit: ${seconds}s"
    fi
}

# =============================================================================
# BANNER & HEADER
# =============================================================================

show_header() {
    local title="$1"
    local width=60
    
    echo
    printf "${CYAN}"
    printf '═%.0s' $(seq 1 $width)
    echo
    printf "  %s\n" "$title"
    printf '═%.0s' $(seq 1 $width)
    printf "${NC}\n"
    echo
}

show_system_info() {
    log_info "System: $(uname -s) $(uname -r)"
    log_info "Hostname: $(hostname)"
    log_info "RAM: $(get_total_memory)MB ($(get_free_memory)MB verfügbar)"
    log_info "CPUs: $(get_cpu_count)"
    log_info "Disk: $(get_disk_usage)% genutzt"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Automatisch bei Source aufrufen
log_debug "common.sh geladen von: $SCRIPT_NAME"
