#!/usr/bin/env bash
# dialog-helpers.sh - Interaktive Dialog-Funktionen (whiptail/dialog)
# Version: 1.1.0

# Abhängigkeiten laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || true

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
        # Kein Dialog-Tool verfügbar - funktioniert ohne
        return 1
    fi
    return 0
}

# =============================================================================
# NACHRICHT ANZEIGEN
# =============================================================================

dialog_message() {
    local title="$1"
    local message="$2"
    local height="${3:-10}"
    local width="${4:-60}"
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        echo "[$title] $message"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --msgbox "$message" "$height" "$width" 3>&1 1>&2 2>&3 || true
    else
        dialog --title "$title" --msgbox "$message" "$height" "$width" 2>&1 1>/dev/tty || true
    fi
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        read -p "[$title] $question (j/N): " answer
        [[ "${answer,,}" =~ ^(j|ja|y|yes)$ ]]
        return $?
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --yesno "$question" "$height" "$width" 3>&1 1>&2 2>&3
        return $?
    else
        dialog --title "$title" --yesno "$question" "$height" "$width" 2>&1 1>/dev/tty
        return $?
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        read -p "[$title] $prompt [$default]: " value
        echo "${value:-$default}"
        return 0
    fi
    
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        read -s -p "[$title] $prompt: " password
        echo
        echo "$password"
        return 0
    fi
    
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        echo "$prompt"
        local i=0
        while [[ $i -lt ${#options[@]} ]]; do
            echo "${options[$i]}) ${options[$((i+1))]}"
            i=$((i + 2))
        done
        read -p "Wähle: " choice
        echo "$choice"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --menu "$prompt" "$height" "$width" "$menu_height" "${options[@]}" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --menu "$prompt" "$height" "$width" "$menu_height" "${options[@]}" 2>&1 1>/dev/tty
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
    
    # Fallback wenn kein Dialog verfügbar - gib alle "on" Items zurück
    if ! ensure_dialog_installed; then
        local result=""
        local i=0
        while [[ $i -lt ${#options[@]} ]]; do
            if [[ "${options[$((i+2))]}" == "on" ]]; then
                result="$result ${options[$i]}"
            fi
            i=$((i + 3))
        done
        echo "$result"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --checklist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --checklist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 2>&1 1>/dev/tty
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        local i=0
        while [[ $i -lt ${#options[@]} ]]; do
            if [[ "${options[$((i+2))]}" == "on" ]]; then
                echo "${options[$i]}"
                return 0
            fi
            i=$((i + 3))
        done
        echo "${options[0]}"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --radiolist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --radiolist "$prompt" "$height" "$width" "$list_height" "${options[@]}" 2>&1 1>/dev/tty
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        cat > /dev/null  # Verwerfe Input
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --gauge "$prompt" "$height" "$width" 0 3>&1 1>&2 2>&3
    else
        dialog --title "$title" --gauge "$prompt" "$height" "$width" 0
    fi
}

# =============================================================================
# TEXTBOX (Datei anzeigen)
# =============================================================================

dialog_textbox() {
    local title="$1"
    local file="$2"
    local height="${3:-20}"
    local width="${4:-70}"
    
    if [[ ! -f "$file" ]]; then
        dialog_error "Datei nicht gefunden: $file"
        return 1
    fi
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        cat "$file"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "whiptail" ]]; then
        whiptail --title "$title" --textbox "$file" "$height" "$width" --scrolltext 3>&1 1>&2 2>&3 || true
    else
        dialog --title "$title" --textbox "$file" "$height" "$width" || true
    fi
}

# =============================================================================
# PAUSE
# =============================================================================

dialog_pause() {
    local title="$1"
    local message="$2"
    local seconds="${3:-5}"
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        echo "$message"
        sleep "$seconds"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --pause "$message" 10 60 "$seconds" || return 1
    else
        # Whiptail hat kein pause, nutze msgbox mit timeout
        whiptail --title "$title" --msgbox "$message\n\n(Automatisch in ${seconds}s)" 10 60 3>&1 1>&2 2>&3 || true
        sleep "$seconds"
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
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        read -p "[$title] Pfad eingeben [$path]: " result
        echo "${result:-$path}"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --fselect "$path" "$height" "$width" 2>&1 1>/dev/tty
    else
        # Whiptail hat kein fselect
        dialog_input "$title" "Pfad eingeben:" "$path" "$height" "$width"
    fi
}

dialog_dselect() {
    local title="$1"
    local path="${2:-.}"
    local height="${3:-20}"
    local width="${4:-70}"
    
    # Fallback wenn kein Dialog verfügbar
    if ! ensure_dialog_installed; then
        read -p "[$title] Verzeichnis eingeben [$path]: " result
        echo "${result:-$path}"
        return 0
    fi
    
    if [[ "$DIALOG_TOOL" == "dialog" ]]; then
        dialog --title "$title" --dselect "$path" "$height" "$width" 2>&1 1>/dev/tty
    else
        dialog_input "$title" "Verzeichnis eingeben:" "$path" "$height" "$width"
    fi
}

# =============================================================================
# AUTO-INITIALISIERUNG
# =============================================================================

if ensure_dialog_installed; then
    log_debug "dialog-helpers.sh geladen - Tool: $DIALOG_TOOL" 2>/dev/null || true
else
    log_debug "dialog-helpers.sh geladen - Fallback-Modus (kein Dialog-Tool)" 2>/dev/null || true
fi
