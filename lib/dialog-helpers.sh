#!/usr/bin/env bash
# dialog-helpers.sh - Interaktive Dialog-Funktionen (whiptail/dialog)
# Version: 1.0.0

# Abhängigkeiten laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# =============================================================================
# DIALOG-COMMAND AUSWÄHLEN
# =============================================================================

select_dialog_tool() {
    if command -v whiptail &> /dev/null; then
        echo "whiptail"
    elif command -v dialog &> /dev/null; then
        echo "dialog"
    else
        return 1
    fi
}

DIALOG_TOOL=$(select_dialog_tool)

# Dialog installieren falls nicht vorhanden
ensure_dialog_installed() {
    if [[ -z "$DIALOG_TOOL" ]]; then
        log_warn "Kein Dialog-Tool gefunden, installiere whiptail..."
        
        if is_debian_based; then
            apt-get install -y whiptail 2>/dev/null
        elif is_redhat_based; then
            yum install -y newt 2>/dev/null
        fi
        
        DIALOG_TOOL=$(select_dialog_tool)
        
        if [[ -z "$DIALOG_TOOL" ]]; then
            log_error "Konnte kein Dialog-Tool installieren!"
            return 1
        fi
    fi
    
    log_debug "Verwende Dialog-Tool: $DIALOG_TOOL"
    return 0
}

# =============================================================================
# WRAPPER-FUNKTIONEN
# =============================================================================

_run_dialog() {
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail "$@" 3>&1 1>&2 2>&3
    else
        dialog "$@" 2>&1 1>/dev/tty
    fi
}

# =============================================================================
# NACHRICHT ANZEIGEN
# =============================================================================

dialog_message() {
    local title="$1"
    local message="$2"
    local height="${3:-10}"
    local width="${4:-60}"
    
    ensure_dialog_installed || return 1
    
    _run_dialog --title "$title" --msgbox "$message" "$height" "$width"
}

dialog_info() {
    dialog_message "ℹ️  Information" "$1" "${2:-10}" "${3:-60}"
}

dialog_warning() {
    dialog_message "⚠️  Warnung" "$1" "${2:-10}" "${3:-60}"
}

dialog_error() {
    dialog_message "❌ Fehler" "$1" "${2:-10}" "${3:-60}"
}

dialog_success() {
    dialog_message "✅ Erfolg" "$1" "${2:-10}" "${3:-60}"
}

# =============================================================================
# JA/NEIN-FRAGE
# =============================================================================

dialog_yesno() {
    local title="$1"
    local question="$2"
    local height="${3:-10}"
    local width="${4:-60}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --yesno "$question" "$height" "$width"
    else
        dialog --title "$title" --yesno "$question" "$height" "$width"
    fi
}

dialog_confirm() {
    dialog_yesno "Bestätigung" "$1" "${2:-10}" "${3:-60}"
}

# =============================================================================
# EINGABEFELD
# =============================================================================

dialog_input() {
    local title="$1"
    local prompt="$2"
    local default="${3:-}"
    local height="${4:-10}"
    local width="${5:-60}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --inputbox "$prompt" "$height" "$width" "$default" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --inputbox "$prompt" "$height" "$width" "$default" 2>&1 1>/dev/tty
    fi
}

dialog_password() {
    local title="$1"
    local prompt="$2"
    local height="${3:-10}"
    local width="${4:-60}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --passwordbox "$prompt" "$height" "$width" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --passwordbox "$prompt" "$height" "$width" 2>&1 1>/dev/tty
    fi
}

# =============================================================================
# MENÜ
# =============================================================================

dialog_menu() {
    local title="$1"
    local prompt="$2"
    local height="${3:-20}"
    local width="${4:-60}"
    local menu_height="${5:-10}"
    shift 5
    local options=("$@")
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --menu "$prompt" "$height" "$width" "$menu_height" "${options[@]}" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --menu "$prompt" "$height" "$width" "$menu_height" "${options[@]}" 2>&1 1>/dev/tty
    fi
}

# =============================================================================
# RADIOLIST (Einzelauswahl)
# =============================================================================

dialog_radiolist() {
    local title="$1"
    local prompt="$2"
    local height="${3:-20}"
    local width="${4:-60}"
    local list_height="${5:-10}"
    shift 5
    local options=("$@")
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --radiolist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --radiolist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 2>&1 1>/dev/tty
    fi
}

# =============================================================================
# CHECKLIST (Mehrfachauswahl)
# =============================================================================

dialog_checklist() {
    local title="$1"
    local prompt="$2"
    local height="${3:-20}"
    local width="${4:-60}"
    local list_height="${5:-10}"
    shift 5
    local options=("$@")
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --checklist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --checklist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 2>&1 1>/dev/tty
    fi
}

# =============================================================================
# FORTSCHRITTSANZEIGE
# =============================================================================

dialog_gauge() {
    local title="$1"
    local prompt="$2"
    local height="${3:-10}"
    local width="${4:-60}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --gauge "$prompt" "$height" "$width" 0
    else
        dialog --title "$title" --gauge "$prompt" "$height" "$width" 0
    fi
}

# Progress mit Updates
dialog_progress() {
    local title="$1"
    local total="$2"
    local current=0
    
    (
        while read -r line; do
            current=$((current + 1))
            local percentage=$((current * 100 / total))
            echo "$percentage"
            echo "XXX"
            echo "$line"
            echo "XXX"
        done
    ) | dialog_gauge "$title" "Verarbeite..." 10 70
}

# =============================================================================
# TEXTBOX (Datei anzeigen)
# =============================================================================

dialog_textbox() {
    local title="$1"
    local file="$2"
    local height="${3:-20}"
    local width="${4:-70}"
    
    ensure_dialog_installed || return 1
    
    if [[ ! -f "$file" ]]; then
        dialog_error "Datei nicht gefunden: $file"
        return 1
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --textbox "$file" "$height" "$width" --scrolltext
    else
        dialog --title "$title" --textbox "$file" "$height" "$width"
    fi
}

# =============================================================================
# DATEI-/VERZEICHNIS-AUSWAHL
# =============================================================================

dialog_fselect() {
    local title="$1"
    local path="${2:-.}"
    local height="${3:-20}"
    local width="${4:-70}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --fselect "$path" "$height" "$width" 2>&1 1>/dev/tty
    else
        # Whiptail hat kein fselect, verwende Input
        dialog_input "$title" "Pfad eingeben:" "$path" "$height" "$width"
    fi
}

dialog_dselect() {
    local title="$1"
    local path="${2:-.}"
    local height="${3:-20}"
    local width="${4:-70}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --dselect "$path" "$height" "$width" 2>&1 1>/dev/tty
    else
        dialog_input "$title" "Verzeichnis eingeben:" "$path" "$height" "$width"
    fi
}

# =============================================================================
# FORM (Mehrere Eingabefelder)
# =============================================================================

dialog_form() {
    local title="$1"
    local height="${2:-20}"
    local width="${3:-70}"
    local form_height="${4:-10}"
    shift 4
    local fields=("$@")
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --form "Formular ausfüllen:" "$height" "$width" "$form_height" "${fields[@]}" 2>&1 1>/dev/tty
    else
        # Whiptail hat kein Form, einzelne Inputs
        local results=()
        local i=0
        while [[ $i -lt ${#fields[@]} ]]; do
            local label="${fields[$i]}"
            local default="${fields[$((i+3))]}"
            local result=$(dialog_input "$title" "$label" "$default")
            results+=("$result")
            i=$((i + 8))
        done
        printf "%s\n" "${results[@]}"
    fi
}

# =============================================================================
# HELPER-FUNKTIONEN
# =============================================================================

dialog_pause() {
    local title="$1"
    local message="$2"
    local seconds="${3:-5}"
    
    ensure_dialog_installed || return 1
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --pause "$message" 10 60 "$seconds"
    else
        whiptail --title "$title" --msgbox "$message\n\n(Automatische Fortsetzung in ${seconds}s)" 10 60
    fi
}

# =============================================================================
# BEISPIEL-VERWENDUNG
# =============================================================================

dialog_example() {
    cat << 'EOF'
# Beispiele für dialog-helpers.sh

# Einfache Nachricht
dialog_info "Dies ist eine Info-Nachricht"

# Ja/Nein-Frage
if dialog_confirm "Möchten Sie fortfahren?"; then
    echo "Bestätigt!"
fi

# Eingabe
name=$(dialog_input "Benutzername" "Geben Sie Ihren Namen ein:" "admin")

# Passwort
password=$(dialog_password "Passwort" "Geben Sie Ihr Passwort ein:")

# Menü
choice=$(dialog_menu "Hauptmenü" "Wählen Sie eine Option:" 15 60 5 \
    "1" "Option 1" \
    "2" "Option 2" \
    "3" "Option 3")

# Checklist
selected=$(dialog_checklist "Features auswählen" "Wählen Sie Features:" 15 60 5 \
    "feature1" "Feature 1" on \
    "feature2" "Feature 2" off \
    "feature3" "Feature 3" on)

# Fortschritt
echo -e "0\n25\n50\n75\n100" | dialog_gauge "Installation" "Installiere..." 10 70
EOF
}

# =============================================================================
# AUTO-INITIALISIERUNG
# =============================================================================

if ensure_dialog_installed; then
    log_debug "dialog-helpers.sh geladen - Tool: $DIALOG_TOOL"
else
    log_warn "Dialog-Tool konnte nicht initialisiert werden"
fi
