#!/bin/bash
INTERFACE="wg1"
BASEIP="192.168.88"
MANAGERIP=${BASEIP}.1
EDGEIP=${BASEIP}.2
MASK="32"
LISTENPORT=33321
EXTRA_ALLOWED_IP=",0.0.0.0/0"
INSTALL_SCRIPT_COUNT=1

function runCmd() {
    echo "executing.. $@" >&2
    "$@"
}

die() {
    echo "$PROGRAM: $*" >&2
    exit 1
}

function getInterface() {
    #redirect both stderr and stdout to /dev/null
    sudo wg show $INTERFACE &> /dev/null
}


function usage() {
    echo "Usage:"
    echo "$0 -> this help"
    echo "$0 clean [ -w wireguardinterface ] -> Cleanup interfaces"
    echo "$0 create [-s presharedkey] [ -w wireguardinterface ] [ -r privatekey ] [ -l peerpublickey ] [ -i publicip ] [ -e edgeip ] [ -p port ] [ -b baseip ] -> Create interfaces"
    echo "$0 generate < -i publicip > [ -w wireguardinterface ] [ -c count ] [ -p port ] [ -b baseip ] -> Setup local interface and generate 'count' install scripts for peers"
    exit 1
}

if [ "$#" == "0" ]; then
    usage
fi

if [ "$1" == "clean" ]; then
    shift 1
    while getopts ":hw:" o; do
        case "${o}" in
            w) INTERFACE=${OPTARG}
            ;;
            *|h) usage
            ;;
        esac
    done
    shift $((OPTIND-1))
    echo -n "Cleaning up the interface $INTERFACE. Are you sure[y/n]? "
    read response
    if [[ "$response" == "y" ]]; then
        rm -f privatekey.${INTERFACE}.script publickey.${INTERFACE}.script presharedkey*.${INTERFACE}.script publickeypeer.${INTERFACE}.script privatekeypeer.${INTERFACE}.script
        runCmd sudo ip link delete dev $INTERFACE
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
                *|h) usage
                ;;
            esac
        done
        shift $((OPTIND-1))

        if [ -z "$publicipfromcommandline" ]; then
            echo "provide the public ip address with -i options"
            usage
        fi
        if [ "$INSTALL_SCRIPT_COUNT" -lt 0 ]; then 
            INSTALL_SCRIPT_COUNT=1
        fi
        if [ "$INSTALL_SCRIPT_COUNT" -gt 10 ]; then 
            INSTALL_SCRIPT_COUNT=10
        fi
    elif [ "$1" == "create" ]; then
        shift 1
        while getopts ":hs:r:w:l:p:i:e:" o; do
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
		   EDGEIP=${BASEIP}.2
                ;;
                e) EDGEIP=${OPTARG}
                ;;
                *|h) usage
                ;;
            esac
        done
        shift $((OPTIND-1))
    fi

    getInterface
    if [[ "$?" == "0" ]]; then
        echo
        echo "Interface $INTERFACE exists. This script will stop  !!!"
        exit 1
    fi

    umask 077
    if [ -z "$privatekeyfromcommandline" ]; then
        wg genkey | tee privatekey.${INTERFACE}.script | wg pubkey > publickey.${INTERFACE}.script
    else
        echo $privatekeyfromcommandline > privatekey.${INTERFACE}.script
        wg pubkey < privatekey.${INTERFACE}.script > publickey.${INTERFACE}.script
    fi

    if [ -z "$presharedkeyfromcommandline" ]; then
        if [ -z "$generateFlag" ]; then
            echo -n "If you have a preshared-key, enter it here:"
            read preshared
        fi
        if [ -z $preshared ]; then
            wg genpsk > presharedkey.${INTERFACE}.script
        else
            echo $preshared > presharedkey.${INTERFACE}.script
        fi
    else
        echo $presharedkeyfromcommandline > presharedkey.${INTERFACE}.script
    fi
    echo -n "public:" && cat publickey.${INTERFACE}.script
    echo -n "private:" && cat privatekey.${INTERFACE}.script
    echo -n "preshared:" && cat presharedkey.${INTERFACE}.script
    runCmd sudo ip link add dev $INTERFACE type wireguard

    if [ -z "$generateFlag" ]; then
        if [ -z "$privatekeyfromcommandline" ]; then
            #Ask the user if this is running on edge node
            defaultAnswer="y"
            echo -n "Are you on the edgenode?[Y/n]?"
            read edgeNode
            [ -z $edgeNode ] && edgeNode=$defaultAnswer
        else
            edgeNode="y"
        fi
    else
        edgeNode="n"
    fi

    if [ $edgeNode == "y" ]; then
        runCmd sudo ip addr add dev $INTERFACE ${EDGEIP}/32
        runCmd sudo ip addr add dev $INTERFACE ${EDGEIP} peer ${MANAGERIP}

        if [ -z "$publickeyfromcommandline" ]; then
            echo -n "Enter the public key of manager:"
            read peerpublickey
            #wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script peer $peerpublickey allowed-ips ${MANAGERIP}/${MASK}${EXTRA_ALLOWED_IP} preshared-key presharedkey.${INTERFACE}.script persistent-keepalive 20
        else 
            peerpublickey=$publickeyfromcommandline
        fi

        if [ -z "$publicipfromcommandline" ]; then
            echo -n "Enter the public IP of manager:"
            read peerpublicip
        else
            peerpublicip=$publicipfromcommandline
        fi

        runCmd sudo wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script peer $peerpublickey allowed-ips ${MANAGERIP}/${MASK}${EXTRA_ALLOWED_IP}  preshared-key presharedkey.${INTERFACE}.script  endpoint $peerpublicip:$LISTENPORT persistent-keepalive 20
    else
        runCmd sudo ip addr add dev $INTERFACE ${MANAGERIP}/${MASK}
        #runCmd sudo ip addr add dev $INTERFACE ${MANAGERIP} peer ${EDGEIP}
        WG_COMMAND="sudo wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script"

        if [ -z "$generateFlag" ]; then
            echo -n "Enter the public key of edge:"
            read peerpublickey
        else
            peerpublicip=$publicipfromcommandline
            publickey=`cat publickey.${INTERFACE}.script`
            echo =========================================================
            echo "public     : $publickey"
            echo "publicipfromcommandline: $publicipfromcommandline"
            echo =========================================================
            for ii in $(seq 1 $INSTALL_SCRIPT_COUNT); do
                wg genpsk > presharedkey${ii}.${INTERFACE}.script
                presharedkey=`cat presharedkey${ii}.${INTERFACE}.script`
                EDGEIP=${BASEIP}.$((ii+1))
                umask 033
                wg genkey | tee privatekeypeer.${INTERFACE}.script | wg pubkey > publickeypeer.${INTERFACE}.script
                peerpublickey=`cat publickeypeer.${INTERFACE}.script`
                peerprivatekey=`cat privatekeypeer.${INTERFACE}.script`
                echo
                echo =========================================================
                echo "peerpublic : $peerpublickey"
                echo "peerprivate: $peerprivatekey"
                echo "preshared  : $presharedkey"
                echo =========================================================
                echo "Commands to execute on the peer $ii"
                echo =============   Either the following set of commands =======================================================
                echo "ip link add dev $INTERFACE type wireguard"
                echo "ip addr add dev $INTERFACE ${EDGEIP}/${MASK}"
                #echo "ip addr add dev $INTERFACE ${EDGEIP} peer ${MANAGERIP}"
                echo "echo '$peerprivatekey' > privatekey.${INTERFACE}.script"
                echo "echo '$presharedkey' > presharedkey.${INTERFACE}.script"
                echo "sudo wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script peer $publickey allowed-ips ${MANAGERIP}/${MASK}${EXTRA_ALLOWED_IP} preshared-key presharedkey.${INTERFACE}.script endpoint $peerpublicip:$LISTENPORT persistent-keepalive 20"
                echo "ip link set up dev $INTERFACE"
                echo ==============  Or if this script is available, then run the script as below\(copy/paste\)=====================
                echo "./setupwg.sh create -w ${INTERFACE} -b ${BASEIP} -p ${LISTENPORT} -s $presharedkey -r $peerprivatekey -l $publickey -i $peerpublicip -e $EDGEIP"
                echo ==============================================================================================================
                WG_COMMAND="$WG_COMMAND peer $peerpublickey allowed-ips ${EDGEIP}/${MASK}${EXTRA_ALLOWED_IP} preshared-key presharedkey${ii}.${INTERFACE}.script persistent-keepalive 20"
            done
        fi

        runCmd $WG_COMMAND

        #echo -n "Enter the public IP of edge:"
        #read peerpublicip
        #wg set $INTERFACE listen-port $LISTENPORT private-key privatekey.${INTERFACE}.script peer $peerpublickey allowed-ips ${EDGEIP}/${MASK}${EXTRA_ALLOWED_IP} preshared-key presharedkey.${INTERFACE}.script  endpoint $peerpublicip:$LISTENPORT persistent-keepalive 20
    fi

    runCmd sudo ip link set up dev $INTERFACE
    runCmd sudo ip route add ${BASEIP}.0/24 dev ${INTERFACE}
fi
