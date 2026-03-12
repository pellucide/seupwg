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
    echo "$0 generate [-i publicip] [-w wireguardinterface] [-c count] [-p port] [-b baseip] -> Setup local interface and generate 'count' install scripts for peers"
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
        rm -f privatekey."${INTERFACE}".script publickey."${INTERFACE}".script presharedkey*."${INTERFACE}".script publickeypeer."${INTERFACE}".script privatekeypeer."${INTERFACE}".script
        rm -rf "$DRYRUN_DIR"
        runCmd sudo ip link delete dev "$INTERFACE"
    fi
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
        if [ -z "$DRYRUN" ]; then
            EDGEIP=$(findFreeIP)
        else
            # In DRYRUN, use simple incrementing IPs
            EDGEIP="${BASEIP}.$((ii + 1))"
        fi
        LISTENPORT=$(getCurrentWireguardSetting "listen-port")

        echo "privatekeyfromcommandline = $privatekeyfromcommandline"
        echo "BASEIP = $BASEIP"
        echo "MANAGERIP = $MANAGERIP"
        echo "EDGEIP = $EDGEIP"
        echo "LISTENPORT = $LISTENPORT"
    fi

    ensureDryRunDir
    OUTDIR=$(getOutputDir)
    
    umask 077
    if [ -z "$privatekeyfromcommandline" ]; then
        if [ -z "$DRYRUN" ]; then
            wg genkey | tee "$OUTDIR/privatekey.${INTERFACE}.script" | wg pubkey > "$OUTDIR/publickey.${INTERFACE}.script"
        else
            # In dryrun, generate keys but don't read from existing files
            wg genkey | tee "$OUTDIR/privatekey.${INTERFACE}.script" | wg pubkey > "$OUTDIR/publickey.${INTERFACE}.script"
        fi
    else
        echo "$privatekeyfromcommandline" > "$OUTDIR/privatekey.${INTERFACE}.script"
        wg pubkey < "$OUTDIR/privatekey.${INTERFACE}.script" > "$OUTDIR/publickey.${INTERFACE}.script"
    fi

    if [ -z "$presharedkeyfromcommandline" ]; then
        if [ -z "$generateFlag" ] && [ -z "$DRYRUN" ]; then
            echo -n "If you have a preshared-key, enter it here:"
            read -r preshared
        fi
        if [ -z "$preshared" ]; then
            wg genpsk > "$OUTDIR/presharedkey.${INTERFACE}.script"
        else
            echo "$preshared" > "$OUTDIR/presharedkey.${INTERFACE}.script"
        fi
    else
        echo "$presharedkeyfromcommandline" > "$OUTDIR/presharedkey.${INTERFACE}.script"
    fi
    OUTDIR=$(getOutputDir)
    echo "public:$(cat "$OUTDIR/publickey.${INTERFACE}.script")"
    if [ -z "$DRYRUN" ]; then
        echo "private:$(cat "$OUTDIR/privatekey.${INTERFACE}.script")"
        echo "preshared:$(cat "$OUTDIR/presharedkey.${INTERFACE}.script")"
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

        if ! runCmd sudo wg set "$INTERFACE" listen-port "$LISTENPORT" private-key "$OUTDIR/privatekey.${INTERFACE}.script" peer "$peerpublickey" allowed-ips "${MANAGERIP}"/${MASK},${EXTRA_ALLOWED_IP} preshared-key "$OUTDIR/presharedkey.${INTERFACE}.script" endpoint "$peerpublicip":"$LISTENPORT" persistent-keepalive "$KEEPALIVE_TIMEOUT"; then
            echo "Error: Failed to configure WireGuard interface"
            exit 1
        fi
    else
        if [ -z "$DRYRUN" ]; then
            runCmd sudo ip addr add dev "$INTERFACE" "${MANAGERIP}"/${MASK}
        fi
        #runCmd sudo ip addr add dev $INTERFACE ${MANAGERIP} peer ${EDGEIP}

        peerpublicip=$publicipfromcommandline
        publickey=$(cat "$OUTDIR/publickey.${INTERFACE}.script")
        for ii in $(seq 1 $INSTALL_SCRIPT_COUNT); do
            wg genpsk > "$OUTDIR/presharedkey${ii}.${INTERFACE}.script"
            presharedkey=$(cat "$OUTDIR/presharedkey${ii}.${INTERFACE}.script")
            #EDGEIP=${BASEIP}.$((ii+1))
        if [ -z "$DRYRUN" ]; then
            EDGEIP=$(findFreeIP)
        else
            # In DRYRUN, use simple incrementing IPs
            EDGEIP="${BASEIP}.$((ii + 1))"
        fi
            umask 077
            wg genkey | tee "$OUTDIR/privatekeypeer.${INTERFACE}.script" | wg pubkey > "$OUTDIR/publickeypeer.${INTERFACE}.script"
            peerpublickey=$(cat "$OUTDIR/publickeypeer.${INTERFACE}.script")
            peerprivatekey=$(cat "$OUTDIR/privatekeypeer.${INTERFACE}.script")
            echo
            echo "============== Execute the following set of commands ======================================================="
            echo "  ip link add dev $INTERFACE type wireguard     &&    ip addr add dev $INTERFACE ${EDGEIP}/${MASK}"
            #echo "  ip addr add dev $INTERFACE ${EDGEIP} peer ${MANAGERIP}"
            echo "  echo '$peerprivatekey' > privatekey.${INTERFACE}.script"
            echo "  echo '$presharedkey' > presharedkey.${INTERFACE}.script"
            echo "  sudo wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script \\"
            echo "       peer $publickey allowed-ips ${MANAGERIP}/${MASK},${EXTRA_ALLOWED_IP} \\"
            echo "       preshared-key presharedkey.${INTERFACE}.script endpoint $peerpublicip:$LISTENPORT persistent-keepalive $KEEPALIVE_TIMEOUT"
            echo "  ip link set up dev $INTERFACE"
            echo "============== Or if this script is available, then run the script as below(copy/paste)====================="
            echo "  ./setupwg.sh create -w ${INTERFACE} -b ${BASEIP} -p ${LISTENPORT} -s $presharedkey \\"
            echo "       -r $peerprivatekey -l $publickey \\"
            echo "       -i $peerpublicip -e $EDGEIP"
            echo "============================================================================================================"
            CONFIG_FILE="$OUTDIR/config.peer.$EDGEIP"
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
            echo "AllowedIPs = ${EDGEIP}/${MASK},${EXTRA_ALLOWED_IP}" | tee -a "$CONFIG_FILE"
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
                if ! runCmd sudo wg set "$INTERFACE" listen-port "$LISTENPORT" private-key privatekey."${INTERFACE}".script peer "$peerpublickey" allowed-ips "${EDGEIP}"/${MASK},${EXTRA_ALLOWED_IP} preshared-key presharedkey"${ii}"."${INTERFACE}".script persistent-keepalive "$KEEPALIVE_TIMEOUT"; then
                    echo "Error: Failed to add peer $ii to WireGuard interface"
                    exit 1
                fi
            fi
        done
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
