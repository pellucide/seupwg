#!/bin/bash
set -o pipefail

PROGRAM="${0##*/}"

# Default configuration
INTERFACE="wg999"
BASEIP="192.168.88"
MANAGERIP="${BASEIP}.1"
MASK="32"
LISTENPORT=33321
EXTRA_ALLOWED_IP="0.0.0.0/0"
DNS_SERVER="1.1.1.1"
MTU_VALUE=1350
KEEPALIVE_TIMEOUT=20
INSTALL_SCRIPT_COUNT=1
DRYRUN=${DRYRUN:-}
VERBOSE=${VERBOSE:-true}
FORCE_OVERWRITE=0

# Computed values
getManagerIP() { echo "${BASEIP}.1"; }

# Colors for verify output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

die() { echo "$PROGRAM: $*" >&2; exit 1; }

runCmd() {
    [[ "$VERBOSE" ]] && echo "executing.. $*" >&2
    [[ -z "$DRYRUN" ]] && "$@"
}

checkCommand() { type "$1" &>/dev/null; }

getOutputDir() { [[ -z "$DRYRUN" ]] && echo "./${INTERFACE}" || echo "dryrun"; }

ensureOutputDir() { mkdir -p "$(getOutputDir)"; }

getPublicIp() { curl -s ipinfo.io/ip 2>/dev/null; }

interfaceStatus() { sudo wg show "$INTERFACE" &>/dev/null; }

getCurrentSetting() { sudo wg show "$INTERFACE" "$1" 2>/dev/null; }

getCurrentBaseIP() {
    sudo wg show "$INTERFACE" allowed-ips 2>/dev/null | head -1 | cut -f2 | cut -d'.' -f-3
}

findFreeIP() {
    local current_base current_last
    # In DRYRUN mode, find highest IP from existing key files
    if [[ -n "$DRYRUN" ]]; then
        local outdir="$(getOutputDir)"
        current_last=1
        local keyfile
        for keyfile in "$outdir"/*.privatekey."${INTERFACE}".script; do
            [[ -f "$keyfile" ]] || continue
            local ip=$(basename "$keyfile" | sed -n "s/.*\.\([0-9]*\)\.privatekey.*/\1/p")
            [[ -n "$ip" && "$ip" =~ ^[0-9]+$ ]] && ((ip > current_last)) && current_last=$ip
        done
        echo "${BASEIP}.$((current_last + 1))"
        return
    fi
    
    current_base=$(getCurrentBaseIP)
    [[ "$current_base" ]] && BASEIP="$current_base"
    current_last=$(sudo wg show "$INTERFACE" allowed-ips 2>/dev/null | cut -f2 | cut -d'.' -f4 | cut -d'/' -f1 | sort -n | tail -1)
    [[ -z "$current_last" ]] && current_last=1
    echo "${BASEIP}.$((current_last + 1))"
}

# =============================================================================
# KEY MANAGEMENT
# =============================================================================

generateKey() { wg genkey; }
getPublicKey() { wg pubkey <<< "$1"; }
generatePSK() { wg genpsk; }

getKeyFile() { echo "$(getOutputDir)/$1.privatekey.${INTERFACE}.script"; }

readKey() {
    local file="$(getKeyFile "$1")"
    [[ -f "$file" ]] && cat "$file" || echo ""
}

writeKey() {
    local file="$(getKeyFile "$1")"
    umask 077
    echo "$2" > "$file"
    chmod 600 "$file"
}

# =============================================================================
# CONFIG GENERATION
# =============================================================================

generatePeerConfig() {
    local peer_ip="$1" peer_privkey="$2" hub_pubkey="$3" psk="$4" endpoint="$5"
    cat <<EOF
[Interface]
ListenPort = $LISTENPORT
PrivateKey = $peer_privkey
Address = $peer_ip
DNS = $DNS_SERVER
MTU = $MTU_VALUE

[Peer]
PublicKey = $hub_pubkey
PresharedKey = $psk
AllowedIPs = $(getManagerIP)/${MASK},${EXTRA_ALLOWED_IP}
Endpoint = $endpoint
PersistentKeepalive = $KEEPALIVE_TIMEOUT
EOF
}

generateHubConfig() {
    local hub_privkey="$1"
    cat <<EOF
[Interface]
ListenPort = $LISTENPORT
PrivateKey = $hub_privkey
Address = $(getManagerIP)/${MASK}
DNS = $DNS_SERVER
MTU = $MTU_VALUE

EOF
    # Add peers from existing config files
    local outdir="$(getOutputDir)"
    for peer_config in "$outdir"/config.peer.*[0-9]; do
        [[ -f "$peer_config" ]] || continue
        [[ "$peer_config" == *.png ]] && continue
        
        local peer_ip peer_privkey peer_pubkey peer_psk
        peer_ip=$(basename "$peer_config" | sed 's/config.peer.//')
        [[ "$peer_ip" == "$MANAGERIP" ]] && continue
        
        peer_privkey=$(grep "^PrivateKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        [[ -z "$peer_privkey" ]] && continue
        
        peer_pubkey=$(getPublicKey "$peer_privkey")
        peer_psk=$(grep "^PresharedKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        [[ -z "$peer_psk" ]] && continue
        
        cat <<EOF
[Peer]
PublicKey = $peer_pubkey
PresharedKey = $peer_psk
AllowedIPs = ${peer_ip}/${MASK}
PersistentKeepalive = $KEEPALIVE_TIMEOUT

EOF
    done
}

# =============================================================================
# FILE OPERATIONS WITH CONFIRMATION
# =============================================================================

writeFileWithConfirm() {
    local target_file="$1" content="$2"
    local outdir="$(getOutputDir)"
    local full_path="$outdir/$target_file"
    
    # Create temp file with content
    local temp_file
    temp_file=$(mktemp)
    echo "$content" > "$temp_file"
    
    if [[ -f "$full_path" && "$FORCE_OVERWRITE" -eq 0 ]]; then
        echo ""
        echo "File $full_path already exists."
        echo "--- Diff (old -> new) ---"
        diff -u "$full_path" "$temp_file" || true
        echo "-------------------------"
        read -rp "Overwrite? [y/N]: " response
        if [[ ! "$response" =~ ^[yY]$ ]]; then
            rm "$temp_file"
            echo "Skipped: $full_path"
            return 1
        fi
    fi
    
    mv "$temp_file" "$full_path"
    chmod 600 "$full_path"
    if [[ "$FORCE_OVERWRITE" -eq 1 && -f "$full_path" ]]; then
        echo "Force overwritten: $full_path"
    else
        echo "Created: $full_path"
    fi
    return 0
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
WireGuard VPN Setup Script

Usage: $PROGRAM <command> [options]

Commands:
    generate [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i ip] [-c count]
        Generate new WireGuard configuration (hub + peers, configures system)
    
    prepare [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i ip] [-c count] [-f]
        Generate config files and keys WITHOUT modifying system
    
    generate [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i ip] [-c count] [-f]
        Generate new WireGuard setup (hub + peers, configures system)
    
    create [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i ip] [-s psk] [-r privkey] [-l pubkey] [-e ip]
        Create new peer for existing WireGuard setup (adds to system interface)
    
    join [-w interface] [-f <file>]
        Join a WireGuard network as a peer (run on peer computer)
        Config can be from file (-f) or piped via stdin (copy-paste)
    
    recreate [-w interface] [-t hub|peer|all] [-f]
        Recreate configs from existing keys (use -i to update endpoint, -f to force)
    
    verify [-w interface] [-b baseip]
        Verify configuration files for consistency
    
    clean [-w interface]
        Remove WireGuard interface and configuration files

Options:
    -w <interface>  WireGuard interface (default: wg999)
    -b <baseip>     Base IP (default: 192.168.88)
    -p <port>       Listen port (default: 33321)
    -d <dns>        DNS server (default: 1.1.1.1)
    -m <mtu>        MTU value (default: 1350)
    -i <ip>         Public IP (auto-detected)
    -c <count>      Number of peers (default: 1)
    -f              Force overwrite existing files
    -t <target>     Regenerate target: hub|peer|all (default: all)

Environment:
    DRYRUN=1        Show commands without executing
    VERBOSE=1       Show detailed output

EOF
    exit 1
}

# =============================================================================
# COMMAND IMPLEMENTATIONS
# =============================================================================

cmd_prepare() {
    # Reset defaults for this command
    BASEIP="192.168.88"
    MANAGERIP="${BASEIP}.1"
    FORCE_OVERWRITE=0
    local count=1 public_ip=""
    
    while getopts ":hw:c:b:p:d:m:i:f" o; do
        case "${o}" in
            w) INTERFACE="$OPTARG" ;;
            c) count="$OPTARG" ;;
            b) BASEIP="$OPTARG"; MANAGERIP="${BASEIP}.1" ;;
            p) LISTENPORT="$OPTARG" ;;
            d) DNS_SERVER="$OPTARG" ;;
            m) MTU_VALUE="$OPTARG" ;;
            i) public_ip="$OPTARG" ;;
            f) FORCE_OVERWRITE=1 ;;
            h) usage ;;
            :) die "Option -$OPTARG requires an argument" ;;
            ?) die "Invalid option: -$OPTARG" ;;
        esac
    done
    
    # Validate count
    [[ "$count" =~ ^[0-9]+$ ]] || die "Invalid count: $count"
    ((count < 1)) && count=1
    ((count > 10)) && count=10
    
    # Get public IP
    if [[ -z "$public_ip" ]]; then
        public_ip=$(getPublicIp)
        [[ -z "$public_ip" ]] && die "Cannot auto-detect public IP. Use -i option."
    fi
    
    ensureOutputDir
    
    # Generate hub keys
    local hub_privkey hub_pubkey
    hub_privkey=$(readKey "$MANAGERIP")
    if [[ -z "$hub_privkey" ]]; then
        hub_privkey=$(generateKey)
        writeKey "$MANAGERIP" "$hub_privkey"
        echo "Generated hub private key"
    else
        echo "Using existing hub private key"
    fi
    hub_pubkey=$(getPublicKey "$hub_privkey")
    
    # Find starting IP
    local last_ip=1
    local outdir="$(getOutputDir)"
    for keyfile in "$outdir"/*.privatekey."${INTERFACE}".script; do
        [[ -f "$keyfile" ]] || continue
        local ip=$(basename "$keyfile" | sed -n "s/\(.*\)\.privatekey\.${INTERFACE}\.script/\1/p")
        [[ "$ip" == "$MANAGERIP" ]] && continue
        if [[ "$ip" =~ \.([0-9]+)$ ]]; then
            local octet="${BASH_REMATCH[1]}"
            ((octet > last_ip)) && last_ip=$octet
        fi
    done
    
    # Generate peers
    for ((i=1; i<=count; i++)); do
        ((last_ip++))
        local peer_ip="${BASEIP}.${last_ip}"
        
        # Check existing
        if [[ -f "$(getKeyFile "$peer_ip")" && "$FORCE_OVERWRITE" -eq 0 ]]; then
            echo "Peer $peer_ip already exists, skipping..."
            continue
        fi
        
        # Generate keys
        local peer_privkey peer_pubkey psk
        peer_privkey=$(generateKey)
        peer_pubkey=$(getPublicKey "$peer_privkey")
        psk=$(generatePSK)
        
        writeKey "$peer_ip" "$peer_privkey"
        
        # Generate and save peer config
        local peer_config
        peer_config=$(generatePeerConfig "$peer_ip" "$peer_privkey" "$hub_pubkey" "$psk" "${public_ip}:${LISTENPORT}")
        
        if writeFileWithConfirm "config.peer.${peer_ip}" "$peer_config"; then
            if checkCommand qrencode; then
                local qr_file="$(getOutputDir)/config.peer.${peer_ip}.png"
                qrencode -r "$(getOutputDir)/config.peer.${peer_ip}" -o "$qr_file" 2>/dev/null && echo "QR code: $qr_file"
            fi
        fi
    done
    
    # Generate hub config
    local hub_config
    hub_config=$(generateHubConfig "$hub_privkey")
    writeFileWithConfirm "config.hub.$(getManagerIP)" "$hub_config"
    
    echo ""
    echo "=========================================="
    echo "Prepared files in: $(getOutputDir)"
    echo "Hub: config.hub.$(getManagerIP)"
    echo "Peers: config.peer.*"
    echo "=========================================="
}

cmd_recreate() {
    # Reset defaults for this command
    BASEIP="192.168.88"
    MANAGERIP="${BASEIP}.1"
    FORCE_OVERWRITE=0
    local target="all" endpoint_ip=""
    
    while getopts ":hw:b:p:d:m:i:t:f" o; do
        case "${o}" in
            f) FORCE_OVERWRITE=1 ;;
            w) INTERFACE="$OPTARG" ;;
            b) BASEIP="$OPTARG"; MANAGERIP="${BASEIP}.1" ;;
            p) LISTENPORT="$OPTARG" ;;
            d) DNS_SERVER="$OPTARG" ;;
            m) MTU_VALUE="$OPTARG" ;;
            i) endpoint_ip="$OPTARG" ;;
            t) target="$OPTARG" ;;
            h) usage ;;
            :) die "Option -$OPTARG requires an argument" ;;
            ?) die "Invalid option: -$OPTARG" ;;
        esac
    done
    
    [[ "$target" =~ ^(hub|peer|all)$ ]] || die "-t must be one of: hub, peer, all"
    
    local outdir="$(getOutputDir)"
    [[ -d "$outdir" ]] || die "Directory $outdir does not exist"
    
    # Get hub public key from existing key file
    local hub_privkey_file="$outdir/$(getManagerIP).privatekey.${INTERFACE}.script"
    [[ -f "$hub_privkey_file" ]] || die "Hub private key not found: $hub_privkey_file"
    local hub_pubkey=$(cat "$hub_privkey_file" | wg pubkey)
    
    echo "Recreating configs from existing keys (target: $target)..."
    
    # Recreate peer configs
    if [[ "$target" == "peer" || "$target" == "all" ]]; then
        for keyfile in "$outdir"/*.privatekey."${INTERFACE}".script; do
            [[ -f "$keyfile" ]] || continue
            
            local peer_ip=$(basename "$keyfile" | sed -n "s/\(.*\)\.privatekey\.${INTERFACE}\.script/\1/p")
            [[ -z "$peer_ip" || "$peer_ip" == "$(getManagerIP)" ]] && continue
            [[ ! "$peer_ip" =~ ^${BASEIP}\. ]] && continue
            
            local config_file="$outdir/config.peer.${peer_ip}"
            
            # Get private key
            local peer_privkey=$(cat "$keyfile" 2>/dev/null)
            [[ -z "$peer_privkey" ]] && { echo "Warning: Empty key for $peer_ip, skipping"; continue; }
            
            # Get PSK from existing config (must exist)
            local peer_psk=""
            if [[ -f "$config_file" ]]; then
                peer_psk=$(grep "^PresharedKey = " "$config_file" 2>/dev/null | cut -d' ' -f3)
            fi
            [[ -z "$peer_psk" ]] && { echo "Warning: No PSK for $peer_ip in existing config, skipping"; continue; }
            
            # Get endpoint: -i option overrides existing config
            local endpoint=""
            if [[ -n "$endpoint_ip" ]]; then
                endpoint="${endpoint_ip}:${LISTENPORT}"
            elif [[ -f "$config_file" ]]; then
                endpoint=$(grep "^Endpoint = " "$config_file" 2>/dev/null | cut -d' ' -f3)
            fi
            [[ -z "$endpoint" ]] && { echo "Warning: No endpoint for $peer_ip, use -i to specify"; continue; }
            
            # Generate config
            local peer_config
            peer_config=$(generatePeerConfig "$peer_ip" "$peer_privkey" "$hub_pubkey" "$peer_psk" "$endpoint")
            writeFileWithConfirm "config.peer.${peer_ip}" "$peer_config"
            
            # Regenerate QR code
            if checkCommand qrencode; then
                local qr_file="$outdir/config.peer.${peer_ip}.png"
                qrencode -r "$outdir/config.peer.${peer_ip}" -o "$qr_file" 2>/dev/null && echo "QR code: $qr_file"
            fi
        done
    fi
    
    # Recreate hub config
    if [[ "$target" == "hub" || "$target" == "all" ]]; then
        local hub_privkey=$(cat "$hub_privkey_file")
        local hub_config=$(generateHubConfig "$hub_privkey")
        writeFileWithConfirm "config.hub.$(getManagerIP)" "$hub_config"
    fi
    
    echo ""
    echo "=========================================="
    echo "Recreated configs in: $outdir"
    echo "=========================================="
}

cmd_generate() {
    # Reset defaults for this command
    BASEIP="192.168.88"
    MANAGERIP="${BASEIP}.1"
    local count=1 public_ip=""
    
    while getopts ":hw:c:b:p:d:m:i:f" o; do
        case "${o}" in
            w) INTERFACE="$OPTARG" ;;
            c) count="$OPTARG" ;;
            b) BASEIP="$OPTARG"; MANAGERIP="${BASEIP}.1" ;;
            p) LISTENPORT="$OPTARG" ;;
            d) DNS_SERVER="$OPTARG" ;;
            m) MTU_VALUE="$OPTARG" ;;
            i) public_ip="$OPTARG" ;;
            f) FORCE_OVERWRITE=1 ;;
            h) usage ;;
            :) die "Option -$OPTARG requires an argument" ;;
            ?) die "Invalid option: -$OPTARG" ;;
        esac
    done
    
    # Validate count
    [[ "$count" =~ ^[0-9]+$ ]] || die "Invalid count: $count"
    ((count < 0)) && count=1
    ((count > 10)) && count=10
    
    # Get public IP
    if [[ -z "$public_ip" ]]; then
        public_ip=$(getPublicIp)
        [[ -z "$public_ip" ]] && die "Cannot auto-detect public IP. Use -i option."
    fi
    
    # Check if interface exists
    if [[ -z "$DRYRUN" ]] && interfaceStatus; then
        echo "Interface $INTERFACE exists. Using existing settings."
        BASEIP=$(getCurrentBaseIP)
        MANAGERIP="${BASEIP}.1"
        LISTENPORT=$(getCurrentSetting "listen-port")
    fi
    
    ensureOutputDir
    local outdir="$(getOutputDir)"
    
    # Generate hub keys
    local hub_privkey hub_pubkey
    local hub_key_file="$outdir/$(getManagerIP).privatekey.${INTERFACE}.script"
    
    if [[ -f "$hub_key_file" ]]; then
        hub_privkey=$(cat "$hub_key_file")
        echo "Using existing hub private key"
    else
        hub_privkey=$(generateKey)
        writeKey "$(getManagerIP)" "$hub_privkey"
        echo "Generated hub private key"
    fi
    hub_pubkey=$(getPublicKey "$hub_privkey")
    
    # Create interface (if not DRYRUN)
    if [[ -z "$DRYRUN" ]]; then
        if ! interfaceStatus; then
            runCmd sudo ip link add dev "$INTERFACE" type wireguard
            runCmd sudo ip addr add dev "$INTERFACE" "$(getManagerIP)/${MASK}"
        fi
        
        # Set hub configuration
        local psk_temp=$(mktemp)
        echo "" > "$psk_temp"
        runCmd sudo wg set "$INTERFACE" listen-port "$LISTENPORT" private-key "$hub_key_file"
        rm -f "$psk_temp"
        runCmd sudo ip link set up dev "$INTERFACE"
        
        # Add route
        runCmd sudo ip route add "${BASEIP}.0/24" dev "$INTERFACE" 2>/dev/null || true
    fi
    
    # Generate peer configs
    local last_ip=1
    for ((i=1; i<=count; i++)); do
        ((last_ip++))
        local peer_ip="${BASEIP}.${last_ip}"
        local peer_key_file="$outdir/${peer_ip}.privatekey.${INTERFACE}.script"
        
        # Generate peer keys
        local peer_privkey peer_pubkey psk
        peer_privkey=$(generateKey)
        peer_pubkey=$(getPublicKey "$peer_privkey")
        psk=$(generatePSK)
        
        writeKey "$peer_ip" "$peer_privkey"
        
        # Generate peer config
        local peer_config
        peer_config=$(generatePeerConfig "$peer_ip" "$peer_privkey" "$hub_pubkey" "$psk" "${public_ip}:${LISTENPORT}")
        
        if writeFileWithConfirm "config.peer.${peer_ip}" "$peer_config"; then
            # Generate QR code
            if checkCommand qrencode; then
                local qr_file="$outdir/config.peer.${peer_ip}.png"
                qrencode -r "$outdir/config.peer.${peer_ip}" -o "$qr_file" 2>/dev/null && echo "QR code: $qr_file"
            fi
            
            # Add peer to interface (if not DRYRUN)
            if [[ -z "$DRYRUN" ]]; then
                local psk_temp=$(mktemp)
                echo "$psk" > "$psk_temp"
                runCmd sudo wg set "$INTERFACE" peer "$peer_pubkey" allowed-ips "${peer_ip}/${MASK}" preshared-key "$psk_temp" persistent-keepalive "$KEEPALIVE_TIMEOUT"
                rm -f "$psk_temp"
            fi
        fi
    done
    
    # Generate hub config
    local hub_config
    hub_config=$(generateHubConfig "$hub_privkey")
    writeFileWithConfirm "config.hub.$(getManagerIP)" "$hub_config"
    
    echo ""
    echo "=========================================="
    echo "Generated WireGuard setup: $INTERFACE"
    echo "Hub: $(getManagerIP), Port: $LISTENPORT"
    echo "Peers generated: $count"
    [[ -z "$DRYRUN" ]] && echo "Interface is UP and configured"
    echo "=========================================="
}

cmd_create() {
    # Reset defaults for this command
    BASEIP="192.168.88"
    MANAGERIP="${BASEIP}.1"
    FORCE_OVERWRITE=0
    local public_ip="" preshared_key="" private_key="" public_key=""
    
    while getopts ":hw:b:p:d:m:i:s:r:l:e:f" o; do
        case "${o}" in
            f) FORCE_OVERWRITE=1 ;;
            w) INTERFACE="$OPTARG" ;;
            b) BASEIP="$OPTARG"; MANAGERIP="${BASEIP}.1" ;;
            p) LISTENPORT="$OPTARG" ;;
            d) DNS_SERVER="$OPTARG" ;;
            m) MTU_VALUE="$OPTARG" ;;
            i) public_ip="$OPTARG" ;;
            s) preshared_key="$OPTARG" ;;
            r) private_key="$OPTARG" ;;
            l) public_key="$OPTARG" ;;
            e) local peer_ip="$OPTARG" ;;
            h) usage ;;
            :) die "Option -$OPTARG requires an argument" ;;
            ?) die "Invalid option: -$OPTARG" ;;
        esac
    done
    
    # Check if interface exists
    if [[ -z "$DRYRUN" ]] && ! interfaceStatus; then
        die "Interface $INTERFACE does not exist. Use 'generate' first."
    fi
    
    # Get current settings from existing interface
    if [[ -z "$DRYRUN" ]]; then
        BASEIP=$(getCurrentBaseIP)
        MANAGERIP="${BASEIP}.1"
        LISTENPORT=$(getCurrentSetting "listen-port")
    fi
    
    # Find free IP
    local edge_ip
    if [[ -n "$peer_ip" ]]; then
        edge_ip="$peer_ip"
    else
        edge_ip=$(findFreeIP)
    fi
    
    # Get hub public key
    local outdir="$(getOutputDir)"
    ensureOutputDir
    local hub_key_file="$outdir/$(getManagerIP).privatekey.${INTERFACE}.script"
    local hub_pubkey
    if [[ -f "$hub_key_file" ]]; then
        hub_pubkey=$(cat "$hub_key_file" | wg pubkey)
    else
        die "Hub key not found. Run 'generate' first."
    fi
    
    # Generate or use provided peer keys
    if [[ -z "$private_key" ]]; then
        private_key=$(generateKey)
    fi
    if [[ -z "$public_key" ]]; then
        public_key=$(getPublicKey "$private_key")
    fi
    if [[ -z "$preshared_key" ]]; then
        preshared_key=$(generatePSK)
    fi
    
    # Save peer key
    writeKey "$edge_ip" "$private_key"
    
    # Get public IP for endpoint
    if [[ -z "$public_ip" ]]; then
        public_ip=$(getPublicIp)
    fi
    
    # Generate peer config
    local peer_config
    peer_config=$(generatePeerConfig "$edge_ip" "$private_key" "$hub_pubkey" "$preshared_key" "${public_ip}:${LISTENPORT}")
    writeFileWithConfirm "config.peer.${edge_ip}" "$peer_config"
    
    # Generate QR code
    if checkCommand qrencode; then
        local qr_file="$outdir/config.peer.${edge_ip}.png"
        qrencode -r "$outdir/config.peer.${edge_ip}" -o "$qr_file" 2>/dev/null && echo "QR code: $qr_file"
    fi
    
    # Add peer to interface (if not DRYRUN)
    if [[ -z "$DRYRUN" ]]; then
        local psk_temp=$(mktemp)
        echo "$preshared_key" > "$psk_temp"
        runCmd sudo wg set "$INTERFACE" peer "$public_key" allowed-ips "${edge_ip}/${MASK},${EXTRA_ALLOWED_IP}" preshared-key "$psk_temp" endpoint "${public_ip}:${LISTENPORT}" persistent-keepalive "$KEEPALIVE_TIMEOUT"
        rm -f "$psk_temp"
        
        # Update hub config file
        runCmd sudo wg show "$INTERFACE" > "$outdir/wg-show-backup.txt" 2>/dev/null || true
    fi
    
    # Regenerate hub config to include new peer
    local hub_privkey=$(cat "$hub_key_file")
    local hub_config=$(generateHubConfig "$hub_privkey")
    writeFileWithConfirm "config.hub.$(getManagerIP)" "$hub_config"
    
    echo ""
    echo "=========================================="
    echo "Created new peer: $edge_ip"
    echo "Interface: $INTERFACE"
    echo "=========================================="
    echo ""
    echo "Peer config:"
    cat "$outdir/config.peer.${edge_ip}"
}

cmd_verify() {
    # Reset defaults for this command
    BASEIP="192.168.88"
    MANAGERIP="${BASEIP}.1"
    
    while getopts ":hw:b:" o; do
        case "${o}" in
            w) INTERFACE="$OPTARG" ;;
            b) BASEIP="$OPTARG"; MANAGERIP="${BASEIP}.1" ;;
            h) usage ;;
            :) die "Option -$OPTARG requires an argument" ;;
            ?) die "Invalid option: -$OPTARG" ;;
        esac
    done
    
    local outdir="$(getOutputDir)"
    [[ -d "$outdir" ]] || die "Directory $outdir does not exist"
    
    local errors=0 warnings=0
    print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
    print_err() { echo -e "${RED}[ERROR]${NC} $1"; ((errors++)); }
    print_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; ((warnings++)); }
    
    echo "=========================================="
    echo "Verifying: $INTERFACE in $outdir"
    echo "=========================================="
    
    # Check hub
    local hub_privkey hub_pubkey
    hub_privkey=$(readKey "$MANAGERIP")
    if [[ -z "$hub_privkey" ]]; then
        print_err "Hub private key not found"
    else
        print_ok "Hub private key exists"
        hub_pubkey=$(getPublicKey "$hub_privkey")
        [[ -z "$hub_pubkey" ]] && print_err "Cannot derive hub public key" || print_ok "Hub public key: ${hub_pubkey:0:20}..."
    fi
    
    # Check hub config
    local hub_config="$outdir/config.hub.$(getManagerIP)"
    [[ -f "$hub_config" ]] || print_err "Hub config not found"
    
    # Parse hub's peer data for cross-validation
    declare -A hub_peer_psk hub_peer_allowed
    if [[ -f "$hub_config" ]]; then
        local current_pubkey=""
        while IFS= read -r line; do
            [[ "$line" == "[Peer]" ]] && current_pubkey=""
            [[ "$line" == "PublicKey = "* ]] && current_pubkey="${line#PublicKey = }"
            [[ "$line" == "PresharedKey = "* && -n "$current_pubkey" ]] && hub_peer_psk["$current_pubkey"]="${line#PresharedKey = }"
            [[ "$line" == "AllowedIPs = "* && -n "$current_pubkey" ]] && hub_peer_allowed["$current_pubkey"]="${line#AllowedIPs = }"
        done < "$hub_config"
    fi
    
    # Check peers
    local peer_count=0
    for peer_file in "$outdir"/config.peer.*[0-9]; do
        [[ -f "$peer_file" ]] || continue
        [[ "$peer_file" == *.png ]] && continue
        
        ((peer_count++))
        local peer_ip=$(basename "$peer_file" | sed 's/config.peer.//')
        echo "--- Peer: $peer_ip ---"
        
        local peer_privkey peer_pubkey peer_hub_pubkey peer_psk peer_allowed
        peer_privkey=$(grep "^PrivateKey = " "$peer_file" 2>/dev/null | cut -d' ' -f3)
        peer_pubkey=$(getPublicKey "$peer_privkey" 2>/dev/null)
        peer_hub_pubkey=$(grep "^PublicKey = " "$peer_file" 2>/dev/null | cut -d' ' -f3)
        peer_psk=$(grep "^PresharedKey = " "$peer_file" 2>/dev/null | cut -d' ' -f3)
        peer_allowed=$(grep "^AllowedIPs = " "$peer_file" 2>/dev/null | cut -d' ' -f3-)
        
        # Validate
        [[ -z "$peer_privkey" ]] && print_err "Missing PrivateKey"
        [[ -f "$(getKeyFile "$peer_ip")" ]] || print_warn "Key file missing"
        [[ "$peer_hub_pubkey" == "$hub_pubkey" ]] && print_ok "PublicKey matches hub" || print_err "PublicKey doesn't match hub"
        [[ -n "$peer_psk" ]] && print_ok "Has PSK" || print_warn "Missing PSK"
        [[ "$peer_allowed" == *"$(getManagerIP)"* ]] && print_ok "AllowedIPs includes hub" || print_warn "AllowedIPs missing hub"
        
        # Cross-check with hub
        if [[ -n "${hub_peer_allowed[$peer_pubkey]}" ]]; then
            print_ok "Found in hub config"
            [[ "${hub_peer_psk[$peer_pubkey]}" == "$peer_psk" ]] && print_ok "PSK matches hub" || print_err "PSK mismatch"
            [[ "${hub_peer_allowed[$peer_pubkey]}" == "${peer_ip}/${MASK}" ]] && print_ok "AllowedIPs correct" || print_err "AllowedIPs mismatch"
        else
            print_err "Not found in hub config"
        fi
    done
    
    echo ""
    echo "=========================================="
    if ((errors == 0 && warnings == 0)); then
        echo -e "${GREEN}PASSED${NC} - All checks passed"
        exit 0
    elif ((errors == 0)); then
        echo -e "${YELLOW}PASSED with warnings${NC} - $warnings warning(s)"
        exit 0
    else
        echo -e "${RED}FAILED${NC} - $errors error(s), $warnings warning(s)"
        exit 1
    fi
}

cmd_join() {
    # Join an existing WireGuard network as a peer
    local config_file="" config_content=""
    
    while getopts ":hw:f:c:" o; do
        case "${o}" in
            w) INTERFACE="$OPTARG" ;;
            f) config_file="$OPTARG" ;;
            c) config_content="$OPTARG" ;;
            h) usage ;;
            :) die "Option -$OPTARG requires an argument" ;;
            ?) die "Invalid option: -$OPTARG" ;;
        esac
    done
    
    # Check if we have config from file, -c option, or stdin
    if [[ -z "$config_file" && -z "$config_content" ]]; then
        # Try to read from stdin (for heredoc/copy-paste)
        if [[ ! -t 0 ]]; then
            config_content=$(cat)
        fi
    fi
    
    [[ -z "$config_file" && -z "$config_content" ]] && die "No config provided. Use -f <file> or pipe config via stdin"
    
    # Read config content
    local config_data
    if [[ -n "$config_file" ]]; then
        [[ -f "$config_file" ]] || die "Config file not found: $config_file"
        config_data=$(cat "$config_file")
        echo "Using config from: $config_file"
    else
        config_data="$config_content"
        echo "Using config from stdin/argument"
    fi
    
    # Parse config
    local privkey=$(echo "$config_data" | grep "^PrivateKey = " | cut -d' ' -f3)
    local address=$(echo "$config_data" | grep "^Address = " | cut -d' ' -f3)
    local listen_port=$(echo "$config_data" | grep "^ListenPort = " | cut -d' ' -f3)
    local dns=$(echo "$config_data" | grep "^DNS = " | cut -d' ' -f3)
    local mtu=$(echo "$config_data" | grep "^MTU = " | cut -d' ' -f3)
    
    # Parse [Peer] section (the hub)
    local hub_pubkey=$(echo "$config_data" | grep "^PublicKey = " | head -1 | cut -d' ' -f3)
    local psk=$(echo "$config_data" | grep "^PresharedKey = " | head -1 | cut -d' ' -f3)
    local allowed_ips=$(echo "$config_data" | grep "^AllowedIPs = " | head -1 | cut -d' ' -f3-)
    local endpoint=$(echo "$config_data" | grep "^Endpoint = " | head -1 | cut -d' ' -f3)
    local keepalive=$(echo "$config_data" | grep "^PersistentKeepalive = " | head -1 | cut -d' ' -f3)
    
    # Validate required fields
    [[ -z "$privkey" ]] && die "Config missing PrivateKey"
    [[ -z "$address" ]] && die "Config missing Address"
    [[ -z "$hub_pubkey" ]] && die "Config missing PublicKey (hub)"
    [[ -z "$endpoint" ]] && die "Config missing Endpoint"
    
    echo ""
    echo "=========================================="
    echo "Joining WireGuard network as peer"
    echo "Interface: $INTERFACE"
    echo "Address: $address"
    echo "Hub endpoint: $endpoint"
    echo "=========================================="
    
    # Create output directory
    ensureOutputDir
    local outdir="$(getOutputDir)"
    
    # Save the config file locally
    echo "$config_data" > "$outdir/config.joined"
    chmod 600 "$outdir/config.joined"
    echo "Config saved to: $outdir/config.joined"
    
    # Create interface (if not DRYRUN)
    if [[ -z "$DRYRUN" ]]; then
        # Delete existing interface if present
        if interfaceStatus; then
            echo "Removing existing interface $INTERFACE..."
            sudo ip link del "$INTERFACE" 2>/dev/null || true
        fi
        
        # Create interface
        runCmd sudo ip link add dev "$INTERFACE" type wireguard
        
        # Set private key
        local key_temp=$(mktemp)
        echo "$privkey" > "$key_temp"
        runCmd sudo wg set "$INTERFACE" private-key "$key_temp"
        rm -f "$key_temp"
        
        # Add IP address
        runCmd sudo ip addr add dev "$INTERFACE" "$address"
        
        # Add peer (the hub)
        local psk_temp=$(mktemp)
        echo "$psk" > "$psk_temp"
        
        # Build wg set command
        local wg_cmd="sudo wg set $INTERFACE peer $hub_pubkey"
        [[ -n "$psk" ]] && wg_cmd="$wg_cmd preshared-key $psk_temp"
        [[ -n "$allowed_ips" ]] && wg_cmd="$wg_cmd allowed-ips $allowed_ips"
        [[ -n "$endpoint" ]] && wg_cmd="$wg_cmd endpoint $endpoint"
        [[ -n "$keepalive" ]] && wg_cmd="$wg_cmd persistent-keepalive $keepalive"
        
        runCmd eval "$wg_cmd"
        rm -f "$psk_temp"
        
        # Bring up interface
        runCmd sudo ip link set up dev "$INTERFACE"
        
        # Add routes for AllowedIPs
        if [[ -n "$allowed_ips" ]]; then
            IFS=',' read -ra ips <<< "$allowed_ips"
            for ip in "${ips[@]}"; do
                ip=$(echo "$ip" | xargs)  # trim
                [[ "$ip" == "0.0.0.0/0" ]] && continue  # Skip default route for now
                runCmd sudo ip route add "$ip" dev "$INTERFACE" 2>/dev/null || echo "Route $ip may already exist"
            done
        fi
        
        # Set DNS if provided (using resolvconf or systemd-resolved)
        if [[ -n "$dns" ]]; then
            echo "Note: DNS setting ($dns) should be configured manually or via wg-quick"
        fi
        
        echo ""
        echo "=========================================="
        echo "Successfully joined network!"
        echo "Interface $INTERFACE is UP"
        echo "Run 'sudo wg show $INTERFACE' to verify"
        echo "=========================================="
    else
        echo ""
        echo "[DRYRUN] Would create interface $INTERFACE with:"
        echo "  Address: $address"
        echo "  Hub: $endpoint"
        echo "  AllowedIPs: $allowed_ips"
    fi
}

cmd_clean() {
    while getopts ":hw:" o; do
        case "${o}" in
            w) INTERFACE="$OPTARG" ;;
            h) usage ;;
        esac
    done
    
    local outdir="$(getOutputDir)"
    echo "Cleaning interface: $INTERFACE"
    
    if [[ -z "$DRYRUN" ]]; then
        sudo ip link del "$INTERFACE" 2>/dev/null && echo "Removed interface $INTERFACE"
        rm -rf "$outdir" 2>/dev/null && echo "Removed $outdir"
    else
        echo "[DRYRUN] Would remove interface and $outdir"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

[[ $# -eq 0 ]] && usage

# Check required commands
checkCommand wg || die "wireguard-tools not installed"
checkCommand curl || die "curl not installed"

COMMAND="$1"
shift

case "$COMMAND" in
    prepare) cmd_prepare "$@" ;;
    generate) cmd_generate "$@" ;;
    create) cmd_create "$@" ;;
    recreate) cmd_recreate "$@" ;;
    verify) cmd_verify "$@" ;;
    join) cmd_join "$@" ;;
    clean) cmd_clean "$@" ;;
    help|--help|-h) usage ;;
    *) die "Unknown command: $COMMAND" ;;
esac
