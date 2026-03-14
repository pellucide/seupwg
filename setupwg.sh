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
        echo "."
    else
        echo "$DRYRUN_DIR"
    fi
}

function ensureDryRunDir() {
    if [ ! -z "$DRYRUN" ] && [ ! -d "$DRYRUN_DIR" ]; then
        mkdir -p "$DRYRUN_DIR"
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
    echo "Usage:"
    echo "$0 -> this help"
    echo "$0 clean [-w wireguardinterface] -> Delete the interface"
    echo "$0 create [-s presharedkey] [-w wireguardinterface] [-r privatekey] [-l peerpublickey] [-i publicip] [-e edgeip] [-p port] [-b baseip] -> Create interfaces"
    echo "$0 generate [-i publicip] [-w wireguardinterface] [-c count] [-p port] [-b baseip] [-d dns] [-m mtu] -> Setup local interface and generate 'count' install scripts for peers"
    echo "$0 regenerate [-w wireguardinterface] [-p port] [-b baseip] [-d dns] [-m mtu] [-i endpoint_ip] [-t hub|peer|all] -> Recreate config files from existing keys with diff/confirm"
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


    if interfaceStatus; then
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

    ensureDryRunDir
    OUTDIR=$(getOutputDir)
    
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
