#!/usr/bin/env bash
# ==============================================================================
# Script: Interactive Template
# Beschreibung: Template für interaktive Scripts mit Dialog/Whiptail
# Autor: matdan1987
# Version: 1.0.0
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/common.sh"
source "$LIB_DIR/os-detection.sh"
source "$LIB_DIR/dialog-helpers.sh"

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_welcome() {
    dialog_message "Willkommen" \
        "Dieses Script hilft bei...\n\n\
Funktionen:\n\
  - Feature 1\n\
  - Feature 2\n\
  - Feature 3\n\n\
Drücken Sie OK zum Fortfahren." 16 70
}

show_main_menu() {
    local choice
    choice=$(dialog_menu "Hauptmenü" "Wählen Sie eine Option:" 20 70 10 \
        "1" "Option 1 - Beschreibung" \
        "2" "Option 2 - Beschreibung" \
        "3" "Option 3 - Beschreibung" \
        "4" "Einstellungen" \
        "5" "Hilfe" \
        "0" "Beenden")
    
    echo "$choice"
}

handle_option_1() {
    dialog_info "Option 1" "Führe Option 1 aus..."
    
    # Deine Logik hier
    
    dialog_success "Option 1 erfolgreich ausgeführt"
}

handle_option_2() {
    local input
    input=$(dialog_input "Eingabe" "Bitte eingeben:")
    
    if [[ -n "$input" ]]; then
        # Verarbeite Eingabe
        dialog_success "Verarbeitet: $input"
    fi
}

show_settings() {
    local options
    options=$(dialog_checklist "Einstellungen" "Wählen Sie Optionen:" 18 70 6 \
        "1" "Option A" on \
        "2" "Option B" off \
        "3" "Option C" on)
    
    dialog_info "Gewählt" "Ausgewählte Optionen:\n$options"
}

main() {
    require_root
    show_welcome
    
    while true; do
        choice=$(show_main_menu)
        
        case "$choice" in
            1) handle_option_1 ;;
            2) handle_option_2 ;;
            3) handle_option_3 ;;
            4) show_settings ;;
            5) show_help ;;
            0|"") break ;;
            *) dialog_error "Ungültige Auswahl" ;;
        esac
    done
    
    dialog_info "Auf Wiedersehen" "Script beendet."
}

main "$@"
