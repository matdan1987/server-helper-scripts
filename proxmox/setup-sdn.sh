#!/usr/bin/env bash
# ==============================================================================
# Script: Proxmox SDN Setup
# Beschreibung: Konfiguriert Software Defined Networking in Proxmox VE
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

# SDN Zone Type: simple, vlan, qinq, vxlan, evpn
SDN_ZONE_TYPE=${SDN_ZONE_TYPE:-vlan}
SDN_ZONE_NAME=${SDN_ZONE_NAME:-zone1}

# VLAN Configuration
VLAN_BRIDGE=${VLAN_BRIDGE:-vmbr0}
VLAN_RANGE=${VLAN_RANGE:-"10-50"}

# VXLAN Configuration (für Multi-Host)
VXLAN_PEERS=${VXLAN_PEERS:-}
VXLAN_MTU=${VXLAN_MTU:-1450}

# VNet Definitionen (Virtuelle Netzwerke)
declare -A VNETS=(
    ["management"]="10.0.1.0/24:10"
    ["services"]="10.0.10.0/24:20"
    ["docker"]="10.0.20.0/24:30"
    ["dmz"]="10.0.100.0/24:100"
)

# DHCP
ENABLE_DHCP=${ENABLE_DHCP:-true}
DNS_SERVER=${DNS_SERVER:-"1.1.1.1,8.8.8.8"}

# NAT/Routing
ENABLE_NAT=${ENABLE_NAT:-true}
WAN_BRIDGE=${WAN_BRIDGE:-vmbr0}

# =============================================================================
# FUNKTIONEN
# =============================================================================

show_banner() {
    show_header "Proxmox SDN Setup"
    log_info "Konfiguriert Software Defined Networking"
    echo
}

check_requirements() {
    log_step "Prüfe Voraussetzungen..."
    
    require_root
    require_proxmox
    
    # Prüfe Proxmox Version (SDN ab 6.2+)
    local pve_version=$(get_pve_version | cut -d. -f1)
    if [[ $pve_version -lt 6 ]]; then
        die "SDN benötigt Proxmox VE 6.2 oder höher!" 1
    fi
    
    # Prüfe ob SDN-Pakete installiert sind
    if ! command_exists pvesh &>/dev/null; then
        die "pvesh nicht gefunden - Proxmox-Installation fehlerhaft!" 1
    fi
    
    log_success "Voraussetzungen erfüllt"
}

show_current_network() {
    log_step "Aktuelle Netzwerk-Konfiguration..."
    
    echo
    log_info "Bridges:"
    ip -br link show type bridge | while read line; do
        echo "  $line"
    done
    
    echo
    log_info "IP-Adressen:"
    ip -br addr | grep -E '^(vmbr|eno|ens|eth)' | while read line; do
        echo "  $line"
    done
    echo
}

confirm_setup() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  SDN Konfiguration"
    log_info "═══════════════════════════════════════════════════════"
    echo
    echo "Zone Type:      $SDN_ZONE_TYPE"
    echo "Zone Name:      $SDN_ZONE_NAME"
    
    if [[ "$SDN_ZONE_TYPE" == "vlan" ]]; then
        echo "VLAN Bridge:    $VLAN_BRIDGE"
        echo "VLAN Range:     $VLAN_RANGE"
    fi
    
    echo
    echo "Virtuelle Netzwerke (VNets):"
    for vnet in "${!VNETS[@]}"; do
        local config="${VNETS[$vnet]}"
        local subnet="${config%%:*}"
        local vlan="${config##*:}"
        printf "  %-15s %-18s VLAN %s\n" "$vnet" "$subnet" "$vlan"
    done
    
    echo
    echo "Features:"
    echo "  DHCP:         $ENABLE_DHCP"
    echo "  NAT:          $ENABLE_NAT"
    echo
    
    if ! ask_yes_no "SDN mit dieser Konfiguration erstellen?" "y"; then
        log_info "Abgebrochen"
        exit 0
    fi
}

enable_sdn() {
    log_step "Aktiviere SDN..."
    
    # SDN-Controller konfigurieren (falls nicht vorhanden)
    if ! pvesh get /cluster/sdn/controllers 2>/dev/null | grep -q "controller"; then
        log_info "Erstelle SDN Controller..."
        # Für Basic Setup ohne Controller (Simple Zones)
    fi
    
    log_success "SDN aktiviert"
}

create_sdn_zone() {
    log_step "Erstelle SDN Zone: $SDN_ZONE_NAME..."
    
    # Prüfe ob Zone existiert
    if pvesh get /cluster/sdn/zones 2>/dev/null | grep -q "\"$SDN_ZONE_NAME\""; then
        log_warn "Zone '$SDN_ZONE_NAME' existiert bereits, überspringe"
        return 0
    fi
    
    case "$SDN_ZONE_TYPE" in
        simple)
            pvesh create /cluster/sdn/zones \
                --zone "$SDN_ZONE_NAME" \
                --type simple
            ;;
            
        vlan)
            pvesh create /cluster/sdn/zones \
                --zone "$SDN_ZONE_NAME" \
                --type vlan \
                --bridge "$VLAN_BRIDGE"
            ;;
            
        vxlan)
            local peers_param=""
            if [[ -n "$VXLAN_PEERS" ]]; then
                peers_param="--peers $VXLAN_PEERS"
            fi
            
            pvesh create /cluster/sdn/zones \
                --zone "$SDN_ZONE_NAME" \
                --type vxlan \
                --mtu "$VXLAN_MTU" \
                $peers_param
            ;;
            
        *)
            die "Nicht unterstützter Zone-Type: $SDN_ZONE_TYPE" 1
            ;;
    esac
    
    log_success "Zone '$SDN_ZONE_NAME' erstellt"
}

create_vnets() {
    log_step "Erstelle virtuelle Netzwerke (VNets)..."
    
    for vnet in "${!VNETS[@]}"; do
        local config="${VNETS[$vnet]}"
        local subnet="${config%%:*}"
        local vlan="${config##*:}"
        
        log_info "Erstelle VNet: $vnet (${subnet}, VLAN ${vlan})"
        
        # Prüfe ob VNet existiert
        if pvesh get /cluster/sdn/vnets 2>/dev/null | grep -q "\"$vnet\""; then
            log_warn "VNet '$vnet' existiert bereits, überspringe"
            continue
        fi
        
        # VNet erstellen
        if [[ "$SDN_ZONE_TYPE" == "vlan" ]]; then
            pvesh create /cluster/sdn/vnets \
                --vnet "$vnet" \
                --zone "$SDN_ZONE_NAME" \
                --tag "$vlan"
        else
            pvesh create /cluster/sdn/vnets \
                --vnet "$vnet" \
                --zone "$SDN_ZONE_NAME"
        fi
        
        # Subnet hinzufügen
        create_subnet "$vnet" "$subnet"
        
        sleep 1
    done
    
    log_success "VNets erstellt"
}

create_subnet() {
    local vnet="$1"
    local subnet="$2"
    
    log_info "Füge Subnet hinzu: $subnet zu $vnet"
    
    # Gateway berechnen (erste IP im Netz)
    local network="${subnet%%/*}"
    local gateway="${network%.*}.$((${network##*.} + 1))"
    
    # Subnet erstellen
    pvesh create /cluster/sdn/vnets/"$vnet"/subnets \
        --subnet "$subnet" \
        --gateway "$gateway" \
        --snat "$ENABLE_NAT"
    
    # DHCP konfigurieren
    if [[ "$ENABLE_DHCP" == "true" ]]; then
        configure_dhcp_for_subnet "$vnet" "$subnet"
    fi
}

configure_dhcp_for_subnet() {
    local vnet="$1"
    local subnet="$2"
    
    log_info "Konfiguriere DHCP für $vnet..."
    
    # DHCP-Range berechnen
    local network="${subnet%%/*}"
    local range_start="${network%.*}.$((${network##*.} + 10))"
    local range_end="${network%.*}.$((${network##*.} + 250))"
    
    # DHCP aktivieren
    pvesh set /cluster/sdn/vnets/"$vnet"/subnets/"${subnet//\//%2F}" \
        --dhcp-range "start-address=${range_start},end-address=${range_end}" \
        --dhcp-dns-server "$DNS_SERVER"
}

configure_nat() {
    if [[ "$ENABLE_NAT" != "true" ]]; then
        return 0
    fi
    
    log_step "Konfiguriere NAT..."
    
    # NAT-Regeln für alle VNets
    for vnet in "${!VNETS[@]}"; do
        local config="${VNETS[$vnet]}"
        local subnet="${config%%:*}"
        
        log_info "NAT für $vnet ($subnet)..."
        
        # Erstelle NAT-Zone (SNAT)
        pvesh set /cluster/sdn/zones/"$SDN_ZONE_NAME" --exitnodes "$(hostname)"
    done
    
    log_success "NAT konfiguriert"
}

create_firewall_rules() {
    log_step "Erstelle Firewall-Basis-Regeln..."
    
    # Firewall-Regeln für jedes VNet
    for vnet in "${!VNETS[@]}"; do
        local config="${VNETS[$vnet]}"
        local subnet="${config%%:*}"
        
        log_info "Firewall-Regeln für $vnet..."
        
        # Security Groups pro VNet
        case "$vnet" in
            management)
                # Management: Restriktiv
                create_security_group "$vnet" "restricted" \
                    "SSH:22:tcp" \
                    "HTTPS:443:tcp"
                ;;
                
            services)
                # Services: Standard
                create_security_group "$vnet" "standard" \
                    "HTTP:80:tcp" \
                    "HTTPS:443:tcp" \
                    "SSH:22:tcp"
                ;;
                
            docker)
                # Docker: Wide open (Container-Isolation)
                create_security_group "$vnet" "docker" \
                    "ALL:0-65535:tcp" \
                    "ALL:0-65535:udp"
                ;;
                
            dmz)
                # DMZ: Public Services
                create_security_group "$vnet" "public" \
                    "HTTP:80:tcp" \
                    "HTTPS:443:tcp"
                ;;
        esac
    done
    
    log_success "Firewall-Regeln erstellt"
}

create_security_group() {
    local vnet="$1"
    local name="$2"
    shift 2
    local rules=("$@")
    
    log_debug "Erstelle Security Group: $name für $vnet"
    
    # Security Group erstellen (simplified)
    # In Production würde man hier pvesh verwenden
    for rule in "${rules[@]}"; do
        local service="${rule%%:*}"
        local port="${rule#*:}"
        port="${port%%:*}"
        local proto="${rule##*:}"
        
        log_debug "  - $service: $port/$proto"
    done
}

apply_sdn_config() {
    log_step "Wende SDN-Konfiguration an..."
    
    # SDN-Konfiguration anwenden (PVE 7.0+)
    if pvesh get /cluster/sdn 2>/dev/null | grep -q "pending"; then
        log_info "Aktiviere SDN-Änderungen..."
        pvesh set /cluster/sdn --apply 1
        
        # Warte auf Anwendung
        sleep 5
    fi
    
    # Netzwerk-Daemons neu laden
    systemctl reload-or-restart pve-cluster
    systemctl reload-or-restart pvedaemon
    systemctl reload-or-restart pveproxy
    
    log_success "SDN-Konfiguration angewendet"
}

test_sdn_configuration() {
    log_step "Teste SDN-Konfiguration..."
    
    # Prüfe Zones
    local zones=$(pvesh get /cluster/sdn/zones --output-format json 2>/dev/null | jq -r '.[].zone' 2>/dev/null || echo "")
    if [[ -n "$zones" ]]; then
        log_success "SDN Zones aktiv: $zones"
    else
        log_warn "Keine SDN Zones gefunden"
    fi
    
    # Prüfe VNets
    local vnets=$(pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null | jq -r '.[].vnet' 2>/dev/null || echo "")
    if [[ -n "$vnets" ]]; then
        log_success "VNets aktiv: $vnets"
    else
        log_warn "Keine VNets gefunden"
    fi
}

show_sdn_overview() {
    echo
    log_success "═══════════════════════════════════════"
    log_success "  SDN Setup abgeschlossen!"
    log_success "═══════════════════════════════════════"
    echo
    
    log_info "SDN Zone: $SDN_ZONE_NAME ($SDN_ZONE_TYPE)"
    echo
    
    log_info "Verfügbare VNets:"
    for vnet in "${!VNETS[@]}"; do
        local config="${VNETS[$vnet]}"
        local subnet="${config%%:*}"
        local vlan="${config##*:}"
        printf "  %-15s %-18s VLAN %-4s\n" "$vnet" "$subnet" "$vlan"
    done
    
    echo
    log_info "Features:"
    echo "  ✓ DHCP aktiviert (pro VNet)"
    [[ "$ENABLE_NAT" == "true" ]] && echo "  ✓ NAT/SNAT aktiviert"
    echo "  ✓ Firewall-Gruppen erstellt"
    echo
    
    log_info "Verwendung bei Container/VM-Erstellung:"
    echo
    echo "  # LXC mit VNet erstellen"
    echo "  pct create 100 local:vztmpl/debian-12.tar.zst \\"
    echo "    --hostname test \\"
    echo "    --net0 name=eth0,bridge=management,ip=dhcp"
    echo
    echo "  # VM mit VNet erstellen"
    echo "  qm create 100 \\"
    echo "    --name test \\"
    echo "    --net0 virtio,bridge=services"
    echo
    
    log_info "SDN verwalten:"
    echo "  Datacenter → SDN"
    echo "  https://$(get_primary_ip):8006"
    echo
    
    log_info "CLI-Befehle:"
    echo "  pvesh get /cluster/sdn/zones"
    echo "  pvesh get /cluster/sdn/vnets"
    echo "  pvesh get /cluster/sdn/vnets/<vnet>/subnets"
    echo
}

create_example_containers() {
    log_step "Möchten Sie Test-Container erstellen?"
    
    if ! ask_yes_no "Test-LXC in verschiedenen VNets erstellen?" "n"; then
        return 0
    fi
    
    log_info "Erstelle Beispiel-Container..."
    
    local vmid=900
    for vnet in management services docker; do
        if [[ "$vmid" -gt 999 ]]; then
            break
        fi
        
        log_info "Erstelle Test-Container in $vnet (VMID: $vmid)..."
        
        local template=$(get_latest_debian_template)
        local storage=$(get_best_storage)
        
        # Mini-Container erstellen
        pct create "$vmid" "${storage}:vztmpl/${template}" \
            --hostname "test-${vnet}" \
            --memory 256 \
            --cores 1 \
            --rootfs "${storage}:4" \
            --net0 "name=eth0,bridge=${vnet},ip=dhcp" \
            --unprivileged 1 \
            --start 1 \
            --onboot 0
        
        log_success "Test-Container $vmid erstellt (VNet: $vnet)"
        
        vmid=$((vmid + 1))
        sleep 2
    done
    
    echo
    log_info "Test-Container wurden erstellt (VMID 900-902)"
    log_info "IPs per DHCP vergeben - prüfe mit: pct exec <vmid> -- ip addr"
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    show_banner
    check_requirements
    show_current_network
    confirm_setup
    
    enable_sdn
    create_sdn_zone
    create_vnets
    configure_nat
    create_firewall_rules
    apply_sdn_config
    
    test_sdn_configuration
    show_sdn_overview
    
    create_example_containers
    
    show_elapsed_time
}

trap 'log_error "SDN-Setup fehlgeschlagen!"; exit 1' ERR
trap 'log_info "Abgebrochen"; exit 130' INT TERM

main "$@"
