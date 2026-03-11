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
DRYRUN=
VERBOSE=true

function runCmd() {
    if [ ! -z "$VERBOSE" ]; then
        echo "executing.. $*" >&2
    fi

    if [ -z "$DRYRUN" ]; then
        "$@"
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
            *) usage
            ;;
        esac
    done
    shift $((OPTIND-1))
    echo -n "Cleaning up the interface $INTERFACE. Are you sure[y/n]? "
    read -r response
    if [[ "$response" == "y" ]]; then
        rm -f privatekey."${INTERFACE}".script publickey."${INTERFACE}".script presharedkey*."${INTERFACE}".script publickeypeer."${INTERFACE}".script privatekeypeer."${INTERFACE}".script
        runCmd sudo ip link delete dev "$INTERFACE"
    fi
else
    if [ "$1" == "generate" ]; then
        generateFlag=1
        shift 1
        while getopts ":hi:w:b:p:c:" o; do
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
                h) usage
                ;;
                *) usage
                ;;
            esac
        done
        shift $((OPTIND-1))

        if [ -z "$publicipfromcommandline" ]; then
            publicipfromcommandline=$(getPublicIp)
            if [ -z "$publicipfromcommandline" ]; then
                echo "provide the public ip address with -i options"
                usage
                exit 1
            fi
        fi
        if [ "$INSTALL_SCRIPT_COUNT" -lt 0 ]; then 
            INSTALL_SCRIPT_COUNT=1
        fi
        if [ "$INSTALL_SCRIPT_COUNT" -gt 10 ]; then 
            INSTALL_SCRIPT_COUNT=10
        fi
    elif [ "$1" == "create" ]; then
        shift 1
        while getopts ":hs:r:w:l:p:b:i:e:" o; do
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
                *) usage
                ;;
            esac
        done
        shift $((OPTIND-1))
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

    umask 077
    if [ -z "$privatekeyfromcommandline" ]; then
        wg genkey | tee privatekey."${INTERFACE}".script | wg pubkey > publickey."${INTERFACE}".script
    else
        echo "$privatekeyfromcommandline" > privatekey."${INTERFACE}".script
        wg pubkey < privatekey."${INTERFACE}".script > publickey."${INTERFACE}".script
    fi

    if [ -z "$presharedkeyfromcommandline" ]; then
        if [ -z "$generateFlag" ]; then
            echo -n "If you have a preshared-key, enter it here:"
            read -r preshared
        fi
        if [ -z "$preshared" ]; then
            wg genpsk > presharedkey."${INTERFACE}".script
        else
            echo "$preshared" > presharedkey."${INTERFACE}".script
        fi
    else
        echo "$presharedkeyfromcommandline" > presharedkey."${INTERFACE}".script
    fi
    echo -n "public:" && cat publickey."${INTERFACE}".script
    echo -n "private:" && cat privatekey."${INTERFACE}".script
    echo -n "preshared:" && cat presharedkey."${INTERFACE}".script
    echo -n "publicip: $publicipfromcommandline:$LISTENPORT"
    echo
    if ! interfaceStatus; then
        runCmd sudo ip link add dev "$INTERFACE" type wireguard
    fi


    if [ -z "$generateFlag" ]; then
        runCmd sudo ip addr add dev "$INTERFACE" "$EDGEIP"/32
        runCmd sudo ip addr add dev "$INTERFACE" "$EDGEIP" peer "${MANAGERIP}"

        if [ -z "$publickeyfromcommandline" ]; then
            echo -n "Peer public key has to be provided:"
            usage
            exit 1
        fi
        peerpublickey=$publickeyfromcommandline

        if [ -z "$publicipfromcommandline" ]; then
            echo "Error: Endpoint public IP is required."
            usage
            exit 1
        fi
        peerpublicip=$publicipfromcommandline

        runCmd sudo wg set "$INTERFACE" listen-port "$LISTENPORT" private-key privatekey."${INTERFACE}".script peer "$peerpublickey" allowed-ips "${MANAGERIP}"/${MASK},${EXTRA_ALLOWED_IP}  preshared-key presharedkey."${INTERFACE}".script  endpoint "$peerpublicip":"$LISTENPORT" persistent-keepalive $KEEPALIVE_TIMEOUT
    else
        runCmd sudo ip addr add dev "$INTERFACE" "${MANAGERIP}"/${MASK}
        #runCmd sudo ip addr add dev $INTERFACE ${MANAGERIP} peer ${EDGEIP}

        peerpublicip=$publicipfromcommandline
        publickey=$(cat publickey."${INTERFACE}".script)
        for ii in $(seq 1 $INSTALL_SCRIPT_COUNT); do
            wg genpsk > presharedkey"${ii}"."${INTERFACE}".script
            presharedkey=$(cat presharedkey"${ii}"."${INTERFACE}".script)
            #EDGEIP=${BASEIP}.$((ii+1))
	    EDGEIP=$(findFreeIP)
            umask 077
            wg genkey | tee privatekeypeer."${INTERFACE}".script | wg pubkey > publickeypeer."${INTERFACE}".script
            peerpublickey=$(cat publickeypeer."${INTERFACE}".script)
            peerprivatekey=$(cat privatekeypeer."${INTERFACE}".script)
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
	    echo " "
	    echo "[Interface]"                                        | tee    "config.peer.$EDGEIP"
	    echo "ListenPort = $LISTENPORT"                           | tee -a "config.peer.$EDGEIP"
	    echo "PrivateKey = $peerprivatekey"                       | tee -a "config.peer.$EDGEIP"
	    echo "Address = $EDGEIP"                                  | tee -a "config.peer.$EDGEIP"
	    echo "DNS = 1.1.1.1"                                      | tee -a "config.peer.$EDGEIP"
	    echo "MTU = 1350"                                         | tee -a "config.peer.$EDGEIP"
	    echo " "                                                  | tee -a "config.peer.$EDGEIP"
	    echo "[Peer]"                                             | tee -a "config.peer.$EDGEIP"
	    echo "PublicKey = $publickey"                             | tee -a "config.peer.$EDGEIP"
	    echo "PresharedKey = $presharedkey"                       | tee -a "config.peer.$EDGEIP"
	    echo "AllowedIPs = ${EDGEIP}/${MASK},${EXTRA_ALLOWED_IP}" | tee -a "config.peer.$EDGEIP"
	    echo "Endpoint = ${peerpublicip}:${LISTENPORT}"           | tee -a "config.peer.$EDGEIP"
	    echo "PersistentKeepalive = $KEEPALIVE_TIMEOUT"           | tee -a "config.peer.$EDGEIP"
	    echo " "
            echo "============================================================================================================"

            if checkCommand "qrencode"; then
                qrencode -r  "config.peer.$EDGEIP" -o  "config.peer.$EDGEIP.png"
            else
                echo "Install qrencode to produce qrcodes"
            fi

            runCmd sudo wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script peer $peerpublickey allowed-ips ${EDGEIP}/${MASK},${EXTRA_ALLOWED_IP} preshared-key presharedkey${ii}.${INTERFACE}.script persistent-keepalive $KEEPALIVE_TIMEOUT
        done
    fi

    runCmd sudo ip link set up dev "$INTERFACE"
    runCmd sudo ip route add "${BASEIP}".0/24 dev "$INTERFACE"
fi
