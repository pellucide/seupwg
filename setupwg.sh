#!/bin/bash
set -o pipefail
PROGRAM="${0##*/}"
INTERFACE="wg999"
BASEIP="192.168.88"
MANAGERIP=${BASEIP}.1
EDGEIP=${BASEIP}.2
MASK="32"
LISTENPORT=33321
EXTRA_ALLOWED_IP="0.0.0.0/0"
INSTALL_SCRIPT_COUNT=1
KEEPALIVE_TIMEOUT=20
DNS_SERVER="1.1.1.1"
MTU_VALUE=1350
DRYRUN=${DRYRUN:-}
VERBOSE=${VERBOSE:-true}
DRYRUN_DIR="dryrun"

function runCmd() {
    if [ ! -z "$VERBOSE" ]; then
        echo "executing.. $*" >&2
    fi

    if [ -z "$DRYRUN" ]; then
        "$@"
        return $?
    else
        return 0
    fi
}

function getOutputDir() {
    if [ -z "$DRYRUN" ]; then
        echo "./${INTERFACE}"
    else
        echo "$DRYRUN_DIR"
    fi
}

function ensureDryRunDir() {
    if [ ! -z "$DRYRUN" ] && [ ! -d "$DRYRUN_DIR" ]; then
        mkdir -p "$DRYRUN_DIR"
    fi
}

function ensureOutputDir() {
    local outdir
    outdir=$(getOutputDir)
    if [ ! -d "$outdir" ]; then
        mkdir -p "$outdir"
    fi
}

die() {
    echo "$PROGRAM: $*" >&2
    exit 1
}

function interfaceStatus() {
    #redirect both stderr and stdout to /dev/null
    sudo wg show $INTERFACE &> /dev/null
}

function getPublicIp() {
   #curl ifconfig.me
   curl -s ipinfo.io/ip
}

function getCurrentWireguardSetting() {
    sudo wg show $INTERFACE "$1"
}

function getBaseIPCurrentWireguardSetting() {
    sudo wg show $INTERFACE allowed-ips | head -1 | cut -f2 | cut -d'.' -f-3
}

function checkCommand() {
    type $1 &> /dev/null
}

function findFreeIP() {
    BASEIP_CURRENT=$(getBaseIPCurrentWireguardSetting)
    if [ ! -z "$BASEIP_CURRENT" ]; then
         BASEIP=$BASEIP_CURRENT
    fi
    lastIP=$(sudo wg show $INTERFACE allowed-ips | cut -f2 | cut -d'.' -f4 | cut -d'/' -f1 | sort | uniq | sed --expression='/\(none\)/d' | tail -1)

    if [ -z "$lastIP" ]; then 
        lastIP=2;
    else
        lastIP=$((lastIP+1))
    fi
    echo ${BASEIP}.${lastIP}
}


function usage() {
    cat <<EOF
WireGuard VPN Setup Script

Usage: $0 <command> [options]

Commands:
    generate [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i publicip]
        Generate new WireGuard configuration (hub + peers)
        Default: hub at .1, 2 peers, wg999 interface, 33321 port

    prepare [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i publicip] [-c count] [-f]
        Generate config files and keys WITHOUT modifying system
        Use -f to force overwrite existing files
        Files created: config.hub.*, config.peer.*, *.privatekey.*.script

    create [-w interface] [-b baseip] [-p port] [-d dns] [-m mtu] [-i publicip]
        Create new peer configuration for existing WireGuard setup
        Automatically assigns next available IP address

    regenerate [-w interface] [-t hub|peer|all]
        Regenerate configuration files from existing files
        -t: regenerate only hub, only peer, or all configs (default: all)
        Uses existing key files and config files

    verify [-w interface] [-b baseip]
        Verify generated configuration files for consistency
        Checks key files, configs, AllowedIPs, PSKs, cross-references
        Returns exit code 0 if valid, non-zero if errors found

    clean [-w interface]
        Remove WireGuard interface and all configuration files
        Removes /etc/wireguard/{interface}* and down the interface

    help
        Show this help message

Options:
    -w <interface>  WireGuard interface name (default: wg999)
    -b <baseip>     Base IP address (default: 192.168.88)
    -p <port>       Listen port (default: 33321)
    -d <dns>        DNS server (default: 1.1.1.1)
    -m <mtu>        MTU value (default: 1350)
    -i <ip>         Public IP address (auto-detected if not specified)
    -c <count>      Number of peers to generate (default: 1 for prepare, 2 for generate)
    -f              Force overwrite existing files (prepare mode only)
    -t <target>     Target for regenerate: hub|peer|all (default: all)

Environment Variables:
    DRYRUN=1        Show commands without executing
    VERBOSE=1       Show detailed output

Examples:
    # Generate hub + 2 peers with defaults
    $0 generate

    # Generate hub + 5 peers on custom network
    $0 generate -c 5 -b 10.10.9

    # Prepare files for wg999 (no system changes)
    $0 prepare -w wg999 -c 3

    # Force overwrite existing files
    $0 prepare -w wg999 -c 3 -f

    # Create additional peer for existing setup
    $0 create -w wg999

    # Regenerate all configs from existing keys
    $0 regenerate -w wg999

    # Regenerate only hub config
    $0 regenerate -w wg999 -t hub

    # Verify generated configuration
    $0 verify -w wg999

    # Clean up everything
    $0 clean -w wg999

EOF
    exit 1
}

if ! checkCommand "curl"; then
    echo "The command curl not found. Please install curl"
    usage
    exit 1
fi

if ! checkCommand "ip"; then
    echo "The command ip not found. Please install iproute2"
    usage
    exit 1
fi

if ! checkCommand "wg"; then
    echo "The command wg not found. Please install wireguard-tools"
    usage
    exit 1
fi



if [ "$#" == "0" ]; then
    usage
fi



if [ "$1" == "clean" ]; then
    shift 1
    while getopts ":hw:" o; do
        case "${o}" in
            w) INTERFACE=${OPTARG}
            ;;
            h) usage
            ;;
            :) echo "Error: Option -${OPTARG} requires an argument"
               usage
               exit 1
            ;;
            ?) echo "Error: Invalid option: -${OPTARG}"
               usage
               exit 1
            ;;
            *) echo "Error: Unknown option"
               usage
               exit 1
            ;;
        esac
    done
    shift $((OPTIND-1))
    if [ $# -ne 0 ]; then
        echo "Error: Unexpected arguments: $*"
        usage
        exit 1
    fi
    echo -n "Cleaning up the interface $INTERFACE. Are you sure[y/n]? "
    read -r response
    if [[ "$response" == "y" ]]; then
        rm -f *."${INTERFACE}".script config.peer.* config.hub.*
        rm -rf "$DRYRUN_DIR"
        runCmd sudo ip link delete dev "$INTERFACE"
    fi
elif [ "$1" == "prepare" ]; then
    shift 1
    PREPARE_COUNT=1
    FORCE_OVERWRITE=0
    while getopts ":hw:c:b:p:d:m:i:f" o; do
        case "${o}" in
            w) INTERFACE=${OPTARG}
            ;;
            c) PREPARE_COUNT=${OPTARG}
            ;;
            b) BASEIP=${OPTARG}
               MANAGERIP=${BASEIP}.1
            ;;
            p) LISTENPORT=${OPTARG}
            ;;
            d) DNS_SERVER=${OPTARG}
            ;;
            m) MTU_VALUE=${OPTARG}
            ;;
            i) publicipfromcommandline=${OPTARG}
            ;;
            f) FORCE_OVERWRITE=1
            ;;
            h) usage
            ;;
            :) echo "Error: Option -${OPTARG} requires an argument"
               usage
               exit 1
            ;;
            ?) echo "Error: Invalid option: -${OPTARG}"
               usage
               exit 1
            ;;
            *) echo "Error: Unknown option"
               usage
               exit 1
            ;;
        esac
    done
    shift $((OPTIND-1))
    if [ $# -ne 0 ]; then
        echo "Error: Unexpected arguments: $*"
        usage
        exit 1
    fi
    
    # Validate count
    if ! [[ "$PREPARE_COUNT" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid count: $PREPARE_COUNT (must be a number)"
        exit 1
    fi
    if [ "$PREPARE_COUNT" -lt 1 ]; then 
        PREPARE_COUNT=1
    fi
    if [ "$PREPARE_COUNT" -gt 10 ]; then 
        PREPARE_COUNT=10
    fi
    
    # Get public IP if not provided
    if [ -z "$publicipfromcommandline" ]; then
        publicipfromcommandline=$(getPublicIp)
        if [ -z "$publicipfromcommandline" ]; then
            echo "Error: Cannot auto-detect public IP. Use -i option to specify."
            exit 1
        fi
    fi
    
    OUTDIR=$(getOutputDir)
    ensureOutputDir
    
    # Function to write config with diff/confirm
    function writeConfigWithConfirmOrForce() {
        local config_file="$1"
        local temp_file="$2"
        local force="$3"
        
        if [ -f "$config_file" ] && [ "$force" -eq 0 ]; then
            echo ""
            echo "Config file $config_file already exists."
            echo "--- Diff (old -> new) ---"
            diff -u "$config_file" "$temp_file" || true
            echo "-------------------------"
            echo -n "Overwrite? [y/N]: "
            read -r response
            if [[ "$response" == "y" || "$response" == "Y" ]]; then
                mv "$temp_file" "$config_file"
                echo "Overwritten: $config_file"
                return 0
            else
                rm "$temp_file"
                echo "Skipped: $config_file"
                return 1
            fi
        else
            mv "$temp_file" "$config_file"
            if [ "$force" -eq 1 ] && [ -f "$config_file" ]; then
                echo "Force overwritten: $config_file"
            else
                echo "Created: $config_file"
            fi
            return 0
        fi
    }
    
    # Generate hub keys
    HUB_KEY_PREFIX="$OUTDIR/${MANAGERIP}"
    umask 077
    if [ ! -f "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script" ]; then
        wg genkey > "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script"
        echo "Generated hub private key: ${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script"
    else
        echo "Using existing hub private key"
    fi
    hub_pubkey=$(wg pubkey < "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script")
    
    # Generate peer configs and keys
    LAST_IP=1
    for existing_peer in "$OUTDIR"/*.privatekey."${INTERFACE}".script; do
        if [ -f "$existing_peer" ]; then
            peer_ip=$(basename "$existing_peer" | sed -n "s/\(.*\)\.privatekey\.${INTERFACE}\.script/\1/p")
            if [ "$peer_ip" = "$MANAGERIP" ]; then
                continue
            fi
            if [ -n "$peer_ip" ]; then
                peer_last_octet=$(echo "$peer_ip" | cut -d'.' -f4)
                if [ -n "$peer_last_octet" ] && [ "$peer_last_octet" -gt "$LAST_IP" ]; then
                    LAST_IP=$peer_last_octet
                fi
            fi
        fi
    done
    
    for ii in $(seq 1 $PREPARE_COUNT); do
        LAST_IP=$((LAST_IP + 1))
        EDGEIP="${BASEIP}.${LAST_IP}"
        
        PEER_KEY_PREFIX="$OUTDIR/${EDGEIP}"
        
        # Check if peer already exists
        if [ -f "${PEER_KEY_PREFIX}.privatekey.${INTERFACE}.script" ] && [ "$FORCE_OVERWRITE" -eq 0 ]; then
            echo "Peer $EDGEIP already exists, skipping..."
            continue
        fi
        
        # Generate peer keys
        wg genkey > "${PEER_KEY_PREFIX}.privatekey.${INTERFACE}.script"
        peerprivatekey=$(cat "${PEER_KEY_PREFIX}.privatekey.${INTERFACE}.script")
        peerpublickey=$(wg pubkey <<< "$peerprivatekey")
        presharedkey=$(wg genpsk)
        
        # Generate peer config
        TEMP_CONFIG=$(mktemp)
        echo "[Interface]" > "$TEMP_CONFIG"
        echo "ListenPort = $LISTENPORT" >> "$TEMP_CONFIG"
        echo "PrivateKey = $peerprivatekey" >> "$TEMP_CONFIG"
        echo "Address = $EDGEIP" >> "$TEMP_CONFIG"
        echo "DNS = $DNS_SERVER" >> "$TEMP_CONFIG"
        echo "MTU = $MTU_VALUE" >> "$TEMP_CONFIG"
        echo "" >> "$TEMP_CONFIG"
        echo "[Peer]" >> "$TEMP_CONFIG"
        echo "PublicKey = $hub_pubkey" >> "$TEMP_CONFIG"
        echo "PresharedKey = $presharedkey" >> "$TEMP_CONFIG"
        echo "AllowedIPs = ${MANAGERIP}/${MASK},${EXTRA_ALLOWED_IP}" >> "$TEMP_CONFIG"
        echo "Endpoint = ${publicipfromcommandline}:${LISTENPORT}" >> "$TEMP_CONFIG"
        echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT" >> "$TEMP_CONFIG"
        
        CONFIG_FILE="$OUTDIR/config.peer.${EDGEIP}"
        if writeConfigWithConfirmOrForce "$CONFIG_FILE" "$TEMP_CONFIG" "$FORCE_OVERWRITE"; then
            # Generate QR code if available
            if checkCommand "qrencode"; then
                QR_FILE="$CONFIG_FILE.png"
                if [ $FORCE_OVERWRITE -eq 1 ] || [ ! -f "$QR_FILE" ]; then
                    qrencode -r "$CONFIG_FILE" -o "$QR_FILE"
                    echo "QR code: $QR_FILE"
                fi
            fi
        fi
    done
    
    # Generate hub config
    TEMP_HUB=$(mktemp)
    echo "[Interface]" > "$TEMP_HUB"
    echo "ListenPort = $LISTENPORT" >> "$TEMP_HUB"
    echo "PrivateKey = $(cat "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script")" >> "$TEMP_HUB"
    echo "Address = ${MANAGERIP}/${MASK}" >> "$TEMP_HUB"
    echo "DNS = $DNS_SERVER" >> "$TEMP_HUB"
    echo "MTU = $MTU_VALUE" >> "$TEMP_HUB"
    echo "" >> "$TEMP_HUB"
    
    # Add all peers to hub config
    for peer_config in "$OUTDIR"/config.peer.*[0-9]; do
        if [ ! -f "$peer_config" ] || [[ "$peer_config" == *.png ]]; then
            continue
        fi
        peer_ip=$(basename "$peer_config" | sed 's/config.peer.//')
        if [ "$peer_ip" = "$MANAGERIP" ]; then
            continue
        fi
        
        peer_privatekey=$(grep "^PrivateKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        if [ -z "$peer_privatekey" ]; then
            continue
        fi
        
        peer_pubkey=$(wg pubkey <<< "$peer_privatekey")
        peer_psk=$(grep "^PresharedKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        if [ -z "$peer_psk" ]; then
            continue
        fi
        
        echo "[Peer]" >> "$TEMP_HUB"
        echo "PublicKey = $peer_pubkey" >> "$TEMP_HUB"
        echo "PresharedKey = $peer_psk" >> "$TEMP_HUB"
        echo "AllowedIPs = ${peer_ip}/${MASK}" >> "$TEMP_HUB"
        echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT" >> "$TEMP_HUB"
        echo "" >> "$TEMP_HUB"
    done
    
    HUB_CONFIG_FILE="$OUTDIR/config.hub.${MANAGERIP}"
    writeConfigWithConfirmOrForce "$HUB_CONFIG_FILE" "$TEMP_HUB" "$FORCE_OVERWRITE"
    
    echo ""
    echo "=========================================="
    echo "Prepared files for interface: $INTERFACE"
    echo "=========================================="
    echo "Hub config: $HUB_CONFIG_FILE"
    echo "Peer configs: $OUTDIR/config.peer.*"
    echo ""
    echo "To use with wg-quick:"
    echo "  sudo wg-quick up ./config.hub.${MANAGERIP}"
    echo "  sudo wg-quick down ./config.hub.${MANAGERIP}"
    echo "=========================================="
    exit 0

elif [ "$1" == "verify" ]; then
    shift 1
    while getopts ":hw:b:" o; do
        case "${o}" in
            w) INTERFACE=${OPTARG}
            ;;
            b) BASEIP=${OPTARG}
               MANAGERIP=${BASEIP}.1
            ;;
            h) usage
            ;;
            :) echo "Error: Option -${OPTARG} requires an argument"
               usage
               exit 1
            ;;
            ?) echo "Error: Invalid option: -${OPTARG}"
               usage
               exit 1
            ;;
            *) echo "Error: Unknown option"
               usage
               exit 1
            ;;
        esac
    done
    shift $((OPTIND-1))
    if [ $# -ne 0 ]; then
        echo "Error: Unexpected arguments: $*"
        usage
        exit 1
    fi
    
    OUTDIR=$(getOutputDir)
    
    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
    
    ERRORS=0
    WARNINGS=0
    
    function print_ok() {
        echo -e "${GREEN}[OK]${NC} $1"
    }
    
    function print_error() {
        echo -e "${RED}[ERROR]${NC} $1"
        ((ERRORS++))
    }
    
    function print_warning() {
        echo -e "${YELLOW}[WARNING]${NC} $1"
        ((WARNINGS++))
    }
    
    function print_info() {
        echo "[INFO] $1"
    }
    
    echo "=========================================="
    echo "Verifying WireGuard configuration: $INTERFACE"
    echo "Directory: $OUTDIR"
    echo "=========================================="
    echo ""
    
    # Check directory exists
    if [ ! -d "$OUTDIR" ]; then
        print_error "Directory $OUTDIR does not exist"
        exit 1
    fi
    print_ok "Directory exists: $OUTDIR"
    
    # Check hub private key file
    HUB_KEY_FILE="$OUTDIR/${MANAGERIP}.privatekey.${INTERFACE}.script"
    if [ ! -f "$HUB_KEY_FILE" ]; then
        print_error "Hub private key file not found: $HUB_KEY_FILE"
    else
        print_ok "Hub private key file exists"
        HUB_PRIVKEY=$(cat "$HUB_KEY_FILE" 2>/dev/null)
        if [ -z "$HUB_PRIVKEY" ]; then
            print_error "Hub private key file is empty"
        else
            # Validate key format (base64, ~44 chars)
            if ! echo "$HUB_PRIVKEY" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
                print_warning "Hub private key format looks invalid"
            else
                print_ok "Hub private key format is valid"
            fi
            # Derive public key
            HUB_PUBKEY=$(wg pubkey <<< "$HUB_PRIVKEY" 2>/dev/null)
            if [ -z "$HUB_PUBKEY" ]; then
                print_error "Failed to derive hub public key from private key"
            else
                print_ok "Hub public key derived: ${HUB_PUBKEY:0:20}..."
            fi
        fi
    fi
    
    # Check hub config
    HUB_CONFIG="$OUTDIR/config.hub.${MANAGERIP}"
    if [ ! -f "$HUB_CONFIG" ]; then
        print_error "Hub config file not found: $HUB_CONFIG"
    else
        print_ok "Hub config file exists"
        
        # Parse hub config
        HUB_CFG_PRIVKEY=$(grep "^PrivateKey = " "$HUB_CONFIG" 2>/dev/null | cut -d' ' -f3)
        HUB_CFG_LISTENPORT=$(grep "^ListenPort = " "$HUB_CONFIG" 2>/dev/null | cut -d' ' -f3)
        HUB_CFG_ADDRESS=$(grep "^Address = " "$HUB_CONFIG" 2>/dev/null | cut -d' ' -f3)
        
        if [ -z "$HUB_CFG_PRIVKEY" ]; then
            print_error "Hub config missing PrivateKey"
        else
            if [ "$HUB_CFG_PRIVKEY" != "$HUB_PRIVKEY" ]; then
                print_error "Hub config PrivateKey does not match key file"
            else
                print_ok "Hub config PrivateKey matches key file"
            fi
        fi
        
        if [ -z "$HUB_CFG_LISTENPORT" ]; then
            print_warning "Hub config missing ListenPort"
        else
            print_ok "Hub ListenPort: $HUB_CFG_LISTENPORT"
        fi
        
        if [ -z "$HUB_CFG_ADDRESS" ]; then
            print_error "Hub config missing Address"
        else
            print_ok "Hub Address: $HUB_CFG_ADDRESS"
            # Check if address matches expected format
            if [[ "$HUB_CFG_ADDRESS" != "${MANAGERIP}/"* ]]; then
                print_warning "Hub Address $HUB_CFG_ADDRESS does not match expected base $MANAGERIP"
            fi
        fi
        
        # Count peers in hub config
        HUB_PEER_COUNT=$(grep -c "^\\[Peer\\]$" "$HUB_CONFIG" 2>/dev/null || echo 0)
        print_info "Hub config has $HUB_PEER_COUNT peer(s)"
    fi
    
    # Check peer configs
    PEER_COUNT=0
    declare -A PEER_PUBKEYS
    declare -A PEER_PSKS
    
    for peer_config in "$OUTDIR"/config.peer.*[0-9]; do
        if [ ! -f "$peer_config" ] || [[ "$peer_config" == *.png ]]; then
            continue
        fi
        
        PEER_COUNT=$((PEER_COUNT + 1))
        PEER_IP=$(basename "$peer_config" | sed 's/config.peer.//')
        print_info "Checking peer: $PEER_IP"
        
        # Parse peer config
        PEER_PRIVKEY=$(grep "^PrivateKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        PEER_PUBKEY=$(grep "^PublicKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        PEER_PSK=$(grep "^PresharedKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        PEER_ENDPOINT=$(grep "^Endpoint = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        PEER_ALLOWED=$(grep "^AllowedIPs = " "$peer_config" 2>/dev/null | cut -d' ' -f3-)
        PEER_ADDRESS=$(grep "^Address = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
        
        if [ -z "$PEER_PRIVKEY" ]; then
            print_error "  Peer $PEER_IP: missing PrivateKey"
        else
            # Check private key file exists
            PEER_KEY_FILE="$OUTDIR/${PEER_IP}.privatekey.${INTERFACE}.script"
            if [ ! -f "$PEER_KEY_FILE" ]; then
                print_warning "  Peer $PEER_IP: private key file not found: $PEER_KEY_FILE"
            else
                FILE_PRIVKEY=$(cat "$PEER_KEY_FILE" 2>/dev/null)
                if [ "$FILE_PRIVKEY" != "$PEER_PRIVKEY" ]; then
                    print_error "  Peer $PEER_IP: config PrivateKey does not match key file"
                else
                    print_ok "  Peer $PEER_IP: private key matches file"
                fi
            fi
            
            # Derive public key
            DERIVED_PUBKEY=$(wg pubkey <<< "$PEER_PRIVKEY" 2>/dev/null)
            if [ -z "$DERIVED_PUBKEY" ]; then
                print_error "  Peer $PEER_IP: failed to derive public key"
            else
                PEER_PUBKEYS["$PEER_IP"]="$DERIVED_PUBKEY"
                print_ok "  Peer $PEER_IP: derived public key ${DERIVED_PUBKEY:0:20}..."
            fi
        fi
        
        if [ -z "$PEER_PUBKEY" ]; then
            print_error "  Peer $PEER_IP: missing PublicKey (hub's public key)"
        else
            # Check if peer's PublicKey matches hub's derived public key
            if [ -n "$HUB_PUBKEY" ] && [ "$PEER_PUBKEY" != "$HUB_PUBKEY" ]; then
                print_error "  Peer $PEER_IP: [Peer] PublicKey does not match hub's public key"
                print_info "    Expected: $HUB_PUBKEY"
                print_info "    Got:      $PEER_PUBKEY"
            else
                print_ok "  Peer $PEER_IP: [Peer] PublicKey matches hub"
            fi
        fi
        
        if [ -z "$PEER_PSK" ]; then
            print_warning "  Peer $PEER_IP: missing PresharedKey"
        else
            PEER_PSKS["$PEER_IP"]="$PEER_PSK"
            print_ok "  Peer $PEER_IP: has PresharedKey"
        fi
        
        if [ -z "$PEER_ENDPOINT" ]; then
            print_warning "  Peer $PEER_IP: missing Endpoint"
        else
            print_ok "  Peer $PEER_IP: Endpoint = $PEER_ENDPOINT"
        fi
        
        if [ -z "$PEER_ALLOWED" ]; then
            print_warning "  Peer $PEER_IP: missing AllowedIPs"
        else
            # Check if AllowedIPs includes hub IP
            if [[ "$PEER_ALLOWED" == *"${MANAGERIP}/"* ]] || [[ "$PEER_ALLOWED" == *"${MANAGERIP},"* ]]; then
                print_ok "  Peer $PEER_IP: AllowedIPs includes hub IP"
            else
                print_warning "  Peer $PEER_IP: AllowedIPs may not include hub IP: $PEER_ALLOWED"
            fi
        fi
        
        if [ -z "$PEER_ADDRESS" ]; then
            print_error "  Peer $PEER_IP: missing Address"
        else
            if [ "$PEER_ADDRESS" != "$PEER_IP" ]; then
                print_error "  Peer $PEER_IP: Address $PEER_ADDRESS does not match filename"
            else
                print_ok "  Peer $PEER_IP: Address matches filename"
            fi
        fi
        echo ""
    done
    
    # Cross-validate hub config peers
    if [ -f "$HUB_CONFIG" ] && [ ${#PEER_PUBKEYS[@]} -gt 0 ]; then
        print_info "Cross-validating hub config with peer configs..."
        
        # Parse hub config into associative arrays by public key
        declare -A HUB_PEER_PSK
        declare -A HUB_PEER_ALLOWED
        
        current_pubkey=""
        while IFS= read -r line; do
            # Start of new peer section
            if [[ "$line" == "[Peer]" ]]; then
                current_pubkey=""
            fi
            # Extract PublicKey
            if [[ "$line" == "PublicKey = "* ]]; then
                current_pubkey="${line#PublicKey = }"
            fi
            # Extract PresharedKey (belongs to current peer)
            if [[ "$line" == "PresharedKey = "* ]] && [ -n "$current_pubkey" ]; then
                HUB_PEER_PSK["$current_pubkey"]="${line#PresharedKey = }"
            fi
            # Extract AllowedIPs (belongs to current peer)
            if [[ "$line" == "AllowedIPs = "* ]] && [ -n "$current_pubkey" ]; then
                HUB_PEER_ALLOWED["$current_pubkey"]="${line#AllowedIPs = }"
            fi
        done < "$HUB_CONFIG"
        
        for peer_ip in "${!PEER_PUBKEYS[@]}"; do
            peer_pubkey="${PEER_PUBKEYS[$peer_ip]}"
            peer_psk="${PEER_PSKS[$peer_ip]:-}"
            
            # Check if this peer exists in hub config
            if [ -n "${HUB_PEER_ALLOWED[$peer_pubkey]}" ]; then
                print_ok "Peer $peer_ip public key found in hub config"
                
                # Check preshared key matches
                if [ -n "$peer_psk" ]; then
                    hub_psk="${HUB_PEER_PSK[$peer_pubkey]:-}"
                    if [ "$hub_psk" == "$peer_psk" ]; then
                        print_ok "Peer $peer_ip PresharedKey matches in hub config"
                    else
                        print_error "Peer $peer_ip PresharedKey mismatch between peer and hub config"
                        print_info "  Peer PSK: ${peer_psk:0:20}..."
                        print_info "  Hub PSK:  ${hub_psk:0:20}..."
                    fi
                fi
                
                # Check AllowedIPs
                hub_allowed="${HUB_PEER_ALLOWED[$peer_pubkey]}"
                expected_allowed="${peer_ip}/${MASK}"
                if [ "$hub_allowed" == "$expected_allowed" ]; then
                    print_ok "Peer $peer_ip AllowedIPs correct in hub config: $hub_allowed"
                else
                    print_error "Peer $peer_ip AllowedIPs mismatch: expected $expected_allowed, got $hub_allowed"
                fi
            else
                print_error "Peer $peer_ip public key NOT found in hub config"
            fi
        done
    fi
    
    # Summary
    echo ""
    echo "=========================================="
    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}Verification PASSED${NC} - All checks passed"
        exit 0
    elif [ $ERRORS -eq 0 ]; then
        echo -e "${YELLOW}Verification PASSED with warnings${NC} - $WARNINGS warning(s)"
        exit 0
    else
        echo -e "${RED}Verification FAILED${NC} - $ERRORS error(s), $WARNINGS warning(s)"
        exit 1
    fi
    echo "=========================================="
    exit 0

elif [ "$1" == "regenerate" ]; then
    shift 1
    REGENERATE_TARGET="all"  # Default: regenerate both hub and peers
    while getopts ":hw:b:p:d:m:i:t:" o; do
        case "${o}" in
            w) INTERFACE=${OPTARG}
            ;;
            b) BASEIP=${OPTARG}
               MANAGERIP=${BASEIP}.1
            ;;
            p) LISTENPORT=${OPTARG}
            ;;
            d) DNS_SERVER=${OPTARG}
            ;;
            m) MTU_VALUE=${OPTARG}
            ;;
            i) ENDPOINT_IP=${OPTARG}
            ;;
            t) REGENERATE_TARGET=${OPTARG}
               if [[ "$REGENERATE_TARGET" != "hub" && "$REGENERATE_TARGET" != "peer" && "$REGENERATE_TARGET" != "all" ]]; then
                   echo "Error: -t must be one of: hub, peer, all"
                   exit 1
               fi
            ;;
            h) usage
            ;;
            :) echo "Error: Option -${OPTARG} requires an argument"
               usage
               exit 1
            ;;
            ?) echo "Error: Invalid option: -${OPTARG}"
               usage
               exit 1
            ;;
            *) echo "Error: Unknown option"
               usage
               exit 1
            ;;
        esac
    done
    shift $((OPTIND-1))
    if [ $# -ne 0 ]; then
        echo "Error: Unexpected arguments: $*"
        usage
        exit 1
    fi
    # Regenerate mode - recreate configs from existing keys
    OUTDIR=$(getOutputDir)
    if [ ! -d "$OUTDIR" ]; then
        echo "Error: Directory $OUTDIR does not exist"
        exit 1
    fi
    
    # Find hub public key by MANAGERIP
    # Derive hub public key from private key
    HUB_PRIVKEY_FILE="$OUTDIR/${MANAGERIP}.privatekey.${INTERFACE}.script"
    if [ -f "$HUB_PRIVKEY_FILE" ]; then
        HUB_PUBKEY=$(wg pubkey < "$HUB_PRIVKEY_FILE")
    else
        echo "Error: No hub private key found at $HUB_PRIVKEY_FILE"
        exit 1
    fi
    
    echo "Regenerating config files from existing keys..."
    
    # Function to show diff and ask for confirmation
    # Returns 0 if config was written/overwritten, 1 if skipped
    function writeConfigWithConfirm() {
        local config_file="$1"
        local temp_file="$2"
        
        if [ -f "$config_file" ]; then
            echo ""
            echo "Config file $config_file already exists."
            echo "--- Diff (old -> new) ---"
            diff -u "$config_file" "$temp_file" || true
            echo "-------------------------"
            echo -n "Overwrite? [y/N]: "
            read -r response
            if [[ "$response" == "y" || "$response" == "Y" ]]; then
                mv "$temp_file" "$config_file"
                echo "Overwritten: $config_file"
                return 0
            else
                rm "$temp_file"
                echo "Skipped: $config_file"
                return 1
            fi
        else
            mv "$temp_file" "$config_file"
            echo "Created: $config_file"
            return 0
        fi
    }
    
    # Find all peer keys and regenerate configs (if target is peer or all)
    if [[ "$REGENERATE_TARGET" == "peer" || "$REGENERATE_TARGET" == "all" ]]; then
    for peer_privkey_file in "$OUTDIR"/*.privatekey."${INTERFACE}".script; do
        if [ ! -f "$peer_privkey_file" ]; then
            continue
        fi
        
        # Extract IP from filename
        peer_ip=$(basename "$peer_privkey_file" | sed -n "s/\(.*\)\.privatekey\.${INTERFACE}\.script/\1/p")
        if [ -z "$peer_ip" ]; then
            continue
        fi
        
        # Skip the hub (manager IP) - it's not a peer
        if [ "$peer_ip" = "$MANAGERIP" ]; then
            continue
        fi
        
        # Skip if peer IP doesn't match BASEIP
        if [[ ! "$peer_ip" =~ ^${BASEIP}\. ]]; then
            continue
        fi
        
        CONFIG_FILE="$OUTDIR/config.peer.${peer_ip}"
        
        # 1. Get PrivateKey: Config file -> Key file -> Error
        peer_privatekey=""
        if [ -f "$CONFIG_FILE" ]; then
            peer_privatekey=$(grep "^PrivateKey = " "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f3)
        fi
        if [ -z "$peer_privatekey" ] && [ -f "$peer_privkey_file" ]; then
            peer_privatekey=$(cat "$peer_privkey_file")
        fi
        if [ -z "$peer_privatekey" ]; then
            echo "Error: Cannot find PrivateKey for peer $peer_ip in config or key file"
            exit 1
        fi
        
        # 2. Get PublicKey: Config file -> Derive from private key -> Error
        peer_pubkey=""
        if [ -f "$CONFIG_FILE" ]; then
            peer_pubkey=$(grep "^PublicKey = " "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f3)
        fi
        if [ -z "$peer_pubkey" ]; then
            peer_pubkey=$(wg pubkey <<< "$peer_privatekey")
        fi
        if [ -z "$peer_pubkey" ]; then
            echo "Error: Cannot derive PublicKey for peer $peer_ip"
            exit 1
        fi
        
        # 3. Get PresharedKey: Config file -> (no key file backup, required in config) -> Error
        peer_psk=""
        if [ -f "$CONFIG_FILE" ]; then
            peer_psk=$(grep "^PresharedKey = " "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f3)
        fi
        if [ -z "$peer_psk" ]; then
            echo "Error: Cannot find PresharedKey for peer $peer_ip in config file"
            exit 1
        fi
        
        # 4. Get Endpoint: Config file -> Command line -> Error
        endpoint=""
        if [ -f "$CONFIG_FILE" ]; then
            endpoint=$(grep "^Endpoint = " "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f3)
        fi
        if [ -z "$endpoint" ] && [ -n "$ENDPOINT_IP" ]; then
            endpoint="${ENDPOINT_IP}:${LISTENPORT}"
        fi
        if [ -z "$endpoint" ]; then
            echo "Error: Cannot find Endpoint for peer $peer_ip in config file"
            echo "Use -i <endpoint_ip> to specify the hub's public IP address"
            exit 1
        fi
        
        # Create temp config file
        TEMP_CONFIG=$(mktemp)
        echo "[Interface]" > "$TEMP_CONFIG"
        echo "ListenPort = $LISTENPORT" >> "$TEMP_CONFIG"
        echo "PrivateKey = $peer_privatekey" >> "$TEMP_CONFIG"
        echo "Address = $peer_ip" >> "$TEMP_CONFIG"
        echo "DNS = $DNS_SERVER" >> "$TEMP_CONFIG"
        echo "MTU = $MTU_VALUE" >> "$TEMP_CONFIG"
        echo "" >> "$TEMP_CONFIG"
        echo "[Peer]" >> "$TEMP_CONFIG"
        echo "PublicKey = $HUB_PUBKEY" >> "$TEMP_CONFIG"
        echo "PresharedKey = $peer_psk" >> "$TEMP_CONFIG"
        # AllowedIPs routes traffic to the VPN subnet and extra IPs (like 0.0.0.0/0)
        echo "AllowedIPs = ${MANAGERIP}/${MASK},${EXTRA_ALLOWED_IP}" >> "$TEMP_CONFIG"
        echo "Endpoint = $endpoint" >> "$TEMP_CONFIG"
        echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT" >> "$TEMP_CONFIG"
        
        CONFIG_FILE="$OUTDIR/config.peer.${peer_ip}"
        QR_FILE="$CONFIG_FILE.png"
        CONFIG_WAS_WRITTEN=0
        
        if writeConfigWithConfirm "$CONFIG_FILE" "$TEMP_CONFIG"; then
            CONFIG_WAS_WRITTEN=1
        fi
        
        # Generate QR code if:
        # 1. Config was just written/overwritten, OR
        # 2. Config exists but QR code is missing
        if checkCommand "qrencode" && [ -f "$CONFIG_FILE" ]; then
            if [ $CONFIG_WAS_WRITTEN -eq 1 ] || [ ! -f "$QR_FILE" ]; then
                qrencode -r "$CONFIG_FILE" -o "$QR_FILE"
                if [ -f "$QR_FILE" ]; then
                    if [ $CONFIG_WAS_WRITTEN -eq 1 ]; then
                        echo "QR code: $QR_FILE"
                    else
                        echo "Created missing QR code: $QR_FILE"
                    fi
                fi
            fi
        fi
    done
    fi  # End peer regeneration
    
    # Regenerate hub config - find by MANAGERIP (if target is hub or all)
    if [[ "$REGENERATE_TARGET" == "hub" || "$REGENERATE_TARGET" == "all" ]]; then
        HUB_CONFIG_FILE="$OUTDIR/config.hub.${MANAGERIP}"
        HUB_KEY_FILE="$OUTDIR/${MANAGERIP}.privatekey.${INTERFACE}.script"
        
        # 1. Get Hub PrivateKey: Config file -> Key file -> Error
        HUB_PRIVKEY=""
        if [ -f "$HUB_CONFIG_FILE" ]; then
            HUB_PRIVKEY=$(grep "^PrivateKey = " "$HUB_CONFIG_FILE" 2>/dev/null | cut -d' ' -f3)
        fi
        if [ -z "$HUB_PRIVKEY" ] && [ -f "$HUB_KEY_FILE" ]; then
            HUB_PRIVKEY=$(cat "$HUB_KEY_FILE")
        fi
        if [ -z "$HUB_PRIVKEY" ]; then
            echo "Error: Cannot find Hub PrivateKey in config file or key file"
            exit 1
        fi
        
        # 2. Get Hub PublicKey: Derive from private key
        HUB_PUBKEY=$(wg pubkey <<< "$HUB_PRIVKEY")
        if [ -z "$HUB_PUBKEY" ]; then
            echo "Error: Cannot derive Hub PublicKey from private key"
            exit 1
        fi
        
        TEMP_HUB=$(mktemp)
        echo "[Interface]" > "$TEMP_HUB"
        echo "ListenPort = $LISTENPORT" >> "$TEMP_HUB"
        echo "PrivateKey = $HUB_PRIVKEY" >> "$TEMP_HUB"
        echo "Address = ${MANAGERIP}/${MASK}" >> "$TEMP_HUB"
        echo "DNS = $DNS_SERVER" >> "$TEMP_HUB"
        echo "MTU = $MTU_VALUE" >> "$TEMP_HUB"
        echo "" >> "$TEMP_HUB"
        
        # Add all peers matching BASEIP to hub config
        # For each peer: get private key from peer config, derive public key, get preshared key from peer config
        for peer_config in "$OUTDIR"/config.peer.*[0-9]; do
            if [ ! -f "$peer_config" ]; then
                continue
            fi
            # Skip PNG files
            if [[ "$peer_config" == *.png ]]; then
                continue
            fi
            # Extract IP from filename (config.peer.IP_ADDRESS)
            peer_ip=$(basename "$peer_config" | sed 's/config.peer.//')
            # Skip hub itself
            if [ "$peer_ip" = "$MANAGERIP" ]; then
                continue
            fi
            # Skip if peer IP does not match BASEIP
            if [[ ! "$peer_ip" =~ ^${BASEIP}\. ]]; then
                continue
            fi
            
            # Get peer's private key from config [Interface] section
            peer_privatekey=$(grep "^PrivateKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
            if [ -z "$peer_privatekey" ]; then
                echo "Error: Cannot find PrivateKey for peer $peer_ip in config file"
                exit 1
            fi
            
            # Derive peer's public key from private key
            peer_pubkey=$(wg pubkey <<< "$peer_privatekey")
            if [ -z "$peer_pubkey" ]; then
                echo "Error: Cannot derive PublicKey for peer $peer_ip"
                exit 1
            fi
            
            # Get preshared key from config [Peer] section
            peer_psk=$(grep "^PresharedKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
            if [ -z "$peer_psk" ]; then
                echo "Error: Cannot find PresharedKey for peer $peer_ip in config file"
                exit 1
            fi
            
            echo "[Peer]" >> "$TEMP_HUB"
            echo "PublicKey = $peer_pubkey" >> "$TEMP_HUB"
            echo "PresharedKey = $peer_psk" >> "$TEMP_HUB"
            echo "AllowedIPs = ${peer_ip}/${MASK}" >> "$TEMP_HUB"
            echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT" >> "$TEMP_HUB"
            echo "" >> "$TEMP_HUB"
        done
        
        HUB_CONFIG="$OUTDIR/config.hub.${MANAGERIP}"
        writeConfigWithConfirm "$HUB_CONFIG" "$TEMP_HUB"
    fi  # End hub regeneration
    
    echo "Regeneration complete."
    exit 0
else
    if [ "$1" == "generate" ]; then
        generateFlag=1
        shift 1
        while getopts ":hi:w:b:p:c:d:m:" o; do
            case "${o}" in
                i) publicipfromcommandline=${OPTARG}
                ;;
                c) INSTALL_SCRIPT_COUNT=${OPTARG}
                ;;
                p) LISTENPORT=${OPTARG}
                ;;
                w) INTERFACE=${OPTARG}
                ;;
                b) BASEIP=${OPTARG}
                   MANAGERIP=${BASEIP}.1
                   EDGEIP=${BASEIP}.2
                ;;
                d) DNS_SERVER=${OPTARG}
                ;;
                m) MTU_VALUE=${OPTARG}
                ;;
                h) usage
                ;;
                :) echo "Error: Option -${OPTARG} requires an argument"
                   usage
                   exit 1
                ;;
                ?) echo "Error: Invalid option: -${OPTARG}"
                   usage
                   exit 1
                ;;
                *) echo "Error: Unknown option"
                   usage
                   exit 1
                ;;
            esac
        done
        shift $((OPTIND-1))

        if [ $# -ne 0 ]; then
            echo "Error: Unexpected arguments: $*"
            usage
            exit 1
        fi

        if [ -z "$publicipfromcommandline" ]; then
            publicipfromcommandline=$(getPublicIp)
            if [ -z "$publicipfromcommandline" ]; then
                echo "provide the public ip address with -i options"
                usage
                exit 1
            fi
        fi
        if ! [[ "$INSTALL_SCRIPT_COUNT" =~ ^[0-9]+$ ]]; then
            echo "Error: Invalid count: $INSTALL_SCRIPT_COUNT (must be a number)"
            exit 1
        fi
        if [ "$INSTALL_SCRIPT_COUNT" -lt 0 ]; then 
            INSTALL_SCRIPT_COUNT=1
        fi
        if [ "$INSTALL_SCRIPT_COUNT" -gt 10 ]; then 
            INSTALL_SCRIPT_COUNT=10
        fi
    elif [ "$1" == "create" ]; then
        shift 1
        while getopts ":hs:r:w:l:p:b:i:e:d:m:" o; do
            case "${o}" in
                s) presharedkeyfromcommandline=${OPTARG}
                ;;
                r) privatekeyfromcommandline=${OPTARG}
                ;;
                l) publickeyfromcommandline=${OPTARG}
                ;;
                i) publicipfromcommandline=${OPTARG}
                ;;
                p) LISTENPORT=${OPTARG}
                ;;
                w) INTERFACE=${OPTARG}
                ;;
                b) BASEIP=${OPTARG}
                   MANAGERIP=${BASEIP}.1
                ;;
                e) EDGEIP=${OPTARG}
                ;;
                d) DNS_SERVER=${OPTARG}
                ;;
                m) MTU_VALUE=${OPTARG}
                ;;
                :) echo "Error: Option -${OPTARG} requires an argument"
                   usage
                   exit 1
                ;;
                ?) echo "Error: Invalid option: -${OPTARG}"
                   usage
                   exit 1
                ;;
                *) echo "Error: Unknown option"
                   usage
                   exit 1
                ;;
            esac
        done
        shift $((OPTIND-1))

        if [ $# -ne 0 ]; then
            echo "Error: Unexpected arguments: $*"
            usage
            exit 1
        fi
    else
        usage
        exit 1
    fi


    if [ -z "$DRYRUN" ] && interfaceStatus; then
        echo
        echo "Interface $INTERFACE exists. This script will use exiting settings !!!"
        privatekeyfromcommandline=$(getCurrentWireguardSetting "private-key")
        BASEIP=$(getBaseIPCurrentWireguardSetting)
        MANAGERIP=${BASEIP}.1
        EDGEIP=$(findFreeIP)
        LISTENPORT=$(getCurrentWireguardSetting "listen-port")

        echo "privatekeyfromcommandline = $privatekeyfromcommandline"
        echo "BASEIP = $BASEIP"
        echo "MANAGERIP = $MANAGERIP"
        echo "EDGEIP = $EDGEIP"
        echo "LISTENPORT = $LISTENPORT"
    fi

    OUTDIR=$(getOutputDir)
    ensureOutputDir
    
    # Hub key files use the hub's IP (MANAGERIP)
    HUB_KEY_PREFIX="$OUTDIR/${MANAGERIP}"
    
    umask 077
    # Generate or use existing hub private key only
    if [ -f "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script" ]; then
        echo "Using existing hub private key: ${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script"
    elif [ -z "$privatekeyfromcommandline" ]; then
        wg genkey > "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script"
    else
        echo "$privatekeyfromcommandline" > "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script"
    fi

    OUTDIR=$(getOutputDir)
    HUB_KEY_PREFIX="$OUTDIR/${MANAGERIP}"
    # Derive public key on-the-fly
    hub_pubkey=$(wg pubkey < "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script")
    echo "public:$hub_pubkey"
    if [ -z "$DRYRUN" ]; then
        echo "private:$(cat "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script")"
    else
        echo "[DRYRUN] Keys written to $OUTDIR/ directory"
    fi
    echo -n "publicip: $publicipfromcommandline:$LISTENPORT"
    echo
    if [ -z "$DRYRUN" ] && ! interfaceStatus; then
        runCmd sudo ip link add dev "$INTERFACE" type wireguard
    fi

    if [ -z "$generateFlag" ]; then
        if ! runCmd sudo ip addr add dev "$INTERFACE" "$EDGEIP"/32 2>/dev/null; then
            echo "Warning: Failed to add IP address $EDGEIP/32 (may already exist)"
        fi
        if ! runCmd sudo ip addr add dev "$INTERFACE" "$EDGEIP" peer "${MANAGERIP}" 2>/dev/null; then
            echo "Warning: Failed to add peer IP (may already exist)"
        fi

        if [ -z "$publickeyfromcommandline" ]; then
            echo "Error: Peer public key has to be provided"
            usage
            exit 1
        fi
        peerpublickey=$publickeyfromcommandline

        if [ -z "$publicipfromcommandline" ]; then
            echo "Error: Endpoint public IP is required"
            usage
            exit 1
        fi
        peerpublicip=$publicipfromcommandline

        # For create mode, preshared key must be provided via command line or read interactively
        if [ -n "$presharedkeyfromcommandline" ]; then
            PSK_VAL="$presharedkeyfromcommandline"
        else
            # Interactive mode - key was read earlier
            PSK_VAL="${preshared:-$(wg genpsk)}"
        fi
        # Write to temp file for wg set
        PSK_TEMP=$(mktemp)
        echo "$PSK_VAL" > "$PSK_TEMP"
        if ! runCmd sudo wg set "$INTERFACE" listen-port "$LISTENPORT" private-key "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script" peer "$peerpublickey" allowed-ips "${MANAGERIP}"/${MASK},${EXTRA_ALLOWED_IP} preshared-key "$PSK_TEMP" endpoint "$peerpublicip":"$LISTENPORT" persistent-keepalive "$KEEPALIVE_TIMEOUT"; then
            rm -f "$PSK_TEMP"
            echo "Error: Failed to configure WireGuard interface"
            exit 1
        fi
        rm -f "$PSK_TEMP"
    else
        if [ -z "$DRYRUN" ]; then
            runCmd sudo ip addr add dev "$INTERFACE" "${MANAGERIP}"/${MASK}
        fi
        #runCmd sudo ip addr add dev $INTERFACE ${MANAGERIP} peer ${EDGEIP}

        peerpublicip=$publicipfromcommandline
        if [ -z "$peerpublicip" ]; then
            echo "Error: Endpoint public IP is required. Use -i option or ensure auto-detection works."
            exit 1
        fi
        publickey=$(wg pubkey < "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script")
        
        # Find the highest existing peer IP to avoid overwriting
        LAST_IP=1
        for existing_peer in "$OUTDIR"/*.privatekey."${INTERFACE}".script; do
            if [ -f "$existing_peer" ]; then
                # Extract IP from filename
                peer_ip=$(basename "$existing_peer" | sed -n "s/\(.*\)\.privatekey\.${INTERFACE}\.script/\1/p")
                # Skip hub's IP
                if [ "$peer_ip" = "$MANAGERIP" ]; then
                    continue
                fi
                # Extract last octet
                if [ -n "$peer_ip" ]; then
                    peer_last_octet=$(echo "$peer_ip" | cut -d'.' -f4)
                    if [ -n "$peer_last_octet" ] && [ "$peer_last_octet" -gt "$LAST_IP" ]; then
                        LAST_IP=$peer_last_octet
                    fi
                fi
            fi
        done
        
        EXISTING_PEER_COUNT=$((LAST_IP - 1))
        if [ $EXISTING_PEER_COUNT -gt 0 ]; then
            echo "Found $EXISTING_PEER_COUNT existing peer(s). Generating additional peers..."
        fi
        
        for ii in $(seq 1 $INSTALL_SCRIPT_COUNT); do
            if [ -z "$DRYRUN" ]; then
                EDGEIP=$(findFreeIP)
            else
                # In DRYRUN, increment from last assigned IP
                LAST_IP=$((LAST_IP + 1))
                EDGEIP="${BASEIP}.${LAST_IP}"
            fi
            
            # Use IP address in filename
            PEER_KEY_PREFIX="$OUTDIR/${EDGEIP}"
            
            # Check if this peer's private key already exists
            if [ -f "${PEER_KEY_PREFIX}.privatekey.${INTERFACE}.script" ]; then
                echo "Peer $EDGEIP keys already exist, skipping..."
                continue
            fi
            
            # Generate keys - only store private key file
            umask 077
            wg genkey > "${PEER_KEY_PREFIX}.privatekey.${INTERFACE}.script"
            peerprivatekey=$(cat "${PEER_KEY_PREFIX}.privatekey.${INTERFACE}.script")
            peerpublickey=$(wg pubkey <<< "$peerprivatekey")
            presharedkey=$(wg genpsk)
            echo
            echo "============== Execute the following set of commands ======================================================="
            echo "  ip link add dev $INTERFACE type wireguard     &&    ip addr add dev $INTERFACE ${EDGEIP}/${MASK}"
            #echo "  ip addr add dev $INTERFACE ${EDGEIP} peer ${MANAGERIP}"
            echo "  echo '$peerprivatekey' > ${EDGEIP}.privatekey.${INTERFACE}.script"
            echo "  sudo wg set $INTERFACE listen-port $LISTENPORT private-key ${EDGEIP}.privatekey.${INTERFACE}.script \\"
            echo "       peer $publickey allowed-ips ${MANAGERIP}/${MASK},${EXTRA_ALLOWED_IP} \\"
            echo "       preshared-key <PRESHARED_KEY> endpoint $peerpublicip:$LISTENPORT persistent-keepalive $KEEPALIVE_TIMEOUT"
            echo "  ip link set up dev $INTERFACE"
            echo "============== Or if this script is available, then run the script as below(copy/paste)====================="
            echo "  ./setupwg.sh create -w ${INTERFACE} -b ${BASEIP} -p ${LISTENPORT} -s $presharedkey \\"
            echo "       -r $peerprivatekey -l $publickey \\"
            echo "       -i $peerpublicip -e $EDGEIP"
            echo "============================================================================================================"
            CONFIG_FILE="$OUTDIR/config.peer.${EDGEIP}"
            echo " "
            echo "[Interface]"                                        | tee    "$CONFIG_FILE"
            echo "ListenPort = $LISTENPORT"                           | tee -a "$CONFIG_FILE"
            echo "PrivateKey = $peerprivatekey"                       | tee -a "$CONFIG_FILE"
            echo "Address = $EDGEIP"                                  | tee -a "$CONFIG_FILE"
            echo "DNS = $DNS_SERVER"                                  | tee -a "$CONFIG_FILE"
            echo "MTU = $MTU_VALUE"                                   | tee -a "$CONFIG_FILE"
            echo " "                                                  | tee -a "$CONFIG_FILE"
            echo "[Peer]"                                             | tee -a "$CONFIG_FILE"
            echo "PublicKey = $publickey"                             | tee -a "$CONFIG_FILE"
            echo "PresharedKey = $presharedkey"                       | tee -a "$CONFIG_FILE"
            # AllowedIPs routes traffic to the VPN subnet and extra IPs (like 0.0.0.0/0)
            echo "AllowedIPs = ${MANAGERIP}/${MASK},${EXTRA_ALLOWED_IP}" | tee -a "$CONFIG_FILE"
            echo "Endpoint = ${peerpublicip}:${LISTENPORT}"           | tee -a "$CONFIG_FILE"
            echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT"           | tee -a "$CONFIG_FILE"
            echo " "
            echo "============================================================================================================"

            if checkCommand "qrencode"; then
                qrencode -r  "$CONFIG_FILE" -o  "$CONFIG_FILE.png"
            else
                echo "Install qrencode to produce qrcodes"
            fi

            if [ -z "$DRYRUN" ]; then
                # Write preshared key to temp file for wg set
                PSK_TEMP=$(mktemp)
                echo "$presharedkey" > "$PSK_TEMP"
                if ! runCmd sudo wg set "$INTERFACE" listen-port "$LISTENPORT" private-key "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script" peer "$peerpublickey" allowed-ips "${EDGEIP}"/${MASK},${EXTRA_ALLOWED_IP} preshared-key "$PSK_TEMP" persistent-keepalive "$KEEPALIVE_TIMEOUT"; then
                    rm -f "$PSK_TEMP"
                    echo "Error: Failed to add peer $EDGEIP to WireGuard interface"
                    exit 1
                fi
                rm -f "$PSK_TEMP"
            fi
            
            # Save peer info for hub config
            if [ -z "$PEER_INFOS" ]; then
                PEER_INFOS="${EDGEIP}:${peerpublickey}:${presharedkey}"
            else
                PEER_INFOS="${PEER_INFOS}|${EDGEIP}:${peerpublickey}:${presharedkey}"
            fi
        done
        
        # Generate hub configuration file with hub's IP
        HUB_CONFIG_FILE="$OUTDIR/config.hub.${MANAGERIP}"
        echo "[Interface]"                                        | tee    "$HUB_CONFIG_FILE"
        echo "ListenPort = $LISTENPORT"                           | tee -a "$HUB_CONFIG_FILE"
        echo "PrivateKey = $(cat "${HUB_KEY_PREFIX}.privatekey.${INTERFACE}.script")" | tee -a "$HUB_CONFIG_FILE"
        echo "Address = ${MANAGERIP}/${MASK}"                     | tee -a "$HUB_CONFIG_FILE"
        echo "DNS = $DNS_SERVER"                                  | tee -a "$HUB_CONFIG_FILE"
        echo "MTU = $MTU_VALUE"                                   | tee -a "$HUB_CONFIG_FILE"
        echo " "                                                  | tee -a "$HUB_CONFIG_FILE"
        
        # Add [Peer] section for ALL peers (existing + new)
        # Read from peer config files (get private key, derive public key, get preshared key)
        for peer_config in "$OUTDIR"/config.peer.*[0-9]; do
            if [ ! -f "$peer_config" ] || [[ "$peer_config" == *.png ]]; then
                continue
            fi
            # Extract IP from filename (config.peer.IP_ADDRESS)
            peer_ip=$(basename "$peer_config" | sed 's/config.peer.//')
            # Skip if this is the hub's IP
            if [ "$peer_ip" = "$MANAGERIP" ]; then
                continue
            fi
            
            # Get peer's private key from config [Interface] section
            peer_privatekey=$(grep "^PrivateKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
            if [ -z "$peer_privatekey" ]; then
                continue
            fi
            
            # Derive public key from private key
            peer_pubkey=$(wg pubkey <<< "$peer_privatekey")
            
            # Get preshared key from config [Peer] section
            peer_psk=$(grep "^PresharedKey = " "$peer_config" 2>/dev/null | cut -d' ' -f3)
            if [ -z "$peer_psk" ]; then
                continue
            fi
            
            echo "[Peer]"                                             | tee -a "$HUB_CONFIG_FILE"
            echo "PublicKey = $peer_pubkey"                           | tee -a "$HUB_CONFIG_FILE"
            echo "PresharedKey = $peer_psk"                          | tee -a "$HUB_CONFIG_FILE"
            echo "AllowedIPs = ${peer_ip}/${MASK}"                   | tee -a "$HUB_CONFIG_FILE"
            echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT"          | tee -a "$HUB_CONFIG_FILE"
            echo " "                                                  | tee -a "$HUB_CONFIG_FILE"
        done
        echo "Hub configuration written to: $HUB_CONFIG_FILE"
    fi

    if [ -z "$DRYRUN" ]; then
        if ! runCmd sudo ip link set up dev "$INTERFACE"; then
            echo "Error: Failed to bring up interface $INTERFACE"
            exit 1
        fi
        if ! runCmd sudo ip route add "${BASEIP}".0/24 dev "$INTERFACE" 2>/dev/null; then
            echo "Warning: Route ${BASEIP}.0/24 may already exist or failed to add"
        fi
    fi
fi
