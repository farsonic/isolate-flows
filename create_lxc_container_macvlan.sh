#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 [-i interface] [-m uplink_mac] [-v vlan_id] [-s subnet] [-c container_count] {start|stop}"
    exit 1
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "Invalid subnet format: $ip. Please use CIDR notation (e.g., 192.168.10.0/24)."
        exit 1
    fi
}

# Function to validate VLAN ID
validate_vlan() {
    local vlan=$1
    if [[ ! $vlan =~ ^[0-9]+$ ]] || [ $vlan -lt 1 ] || [ $vlan -gt 4094 ]; then
        echo "Invalid VLAN ID: $vlan. VLAN ID must be between 1 and 4094."
        exit 1
    fi
}

# Function to validate container count
validate_container_count() {
    local count=$1
    if [[ ! $count =~ ^[0-9]+$ ]] || [ $count -lt 1 ]; then
        echo "Invalid container count: $count. Container count must be a positive integer."
        exit 1
    fi
}

# Parse command line arguments
while getopts "i:m:v:s:c:" opt; do
    case ${opt} in
        i ) INTERFACE=$OPTARG ;;
        m ) UPLINK_MAC=$OPTARG ;;
        v ) VLAN_ID=$OPTARG ;;
        s ) SUBNET=$OPTARG ;;
        c ) CONTAINER_COUNT=$OPTARG ;;
        * ) usage ;;
    esac
done
shift $((OPTIND -1))

# Ensure we have a valid action (start/stop)
if [ "$#" -lt 1 ]; then
    usage
fi

ACTION=$1

# Validate inputs
if [ -n "$SUBNET" ]; then
    validate_ip "$SUBNET"
fi

if [ -n "$VLAN_ID" ]; then
    validate_vlan "$VLAN_ID"
fi

if [ -n "$CONTAINER_COUNT" ]; then
    validate_container_count "$CONTAINER_COUNT"
fi

# Ensure required packages are installed
REQUIRED_PACKAGES=(
    lxc
    lxc-utils
    bridge-utils
    openvswitch-switch
    iproute2
)

echo "Checking required packages..."
sudo apt update
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
        echo "Installing missing package: $pkg"
        sudo apt install -y "$pkg"
    fi
done

# Detect the physical interface by MAC address if UPLINK_MAC is set
if [ -n "$UPLINK_MAC" ] && [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -v mac="$UPLINK_MAC" '$0 ~ mac && !($2 ~ /@/) {print $2; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "No physical interface found with MAC address $UPLINK_MAC. Exiting."
        exit 1
    fi
    echo "Using physical interface $INTERFACE for MAC $UPLINK_MAC"
fi

VLAN_INTERFACE="vlan.${VLAN_ID}"
GATEWAY_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.1/')
BASE_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.200/')

# Define variables
CONTAINER_PREFIX="lxc_macvlan_"

case "$ACTION" in
    start)
        echo "Starting LXC container setup..."

        for ((i=1; i<=CONTAINER_COUNT; i++)); do
            LXC_NAME="${CONTAINER_PREFIX}${i}"
            CONTAINER_IP=$(echo $SUBNET | sed "s/\.0\/.*$/.$((199 + i))/")

            echo "Creating LXC container: $LXC_NAME with IP: $CONTAINER_IP"
            if ! sudo lxc-ls | grep -q "^$LXC_NAME$"; then
                sudo lxc-create -n "$LXC_NAME" -t download -- -d ubuntu -r focal -a amd64
            else
                echo "LXC container $LXC_NAME already exists. Skipping creation."
            fi

            echo "Configuring MACVLAN interface for $LXC_NAME"
            echo -e "lxc.net.0.type = macvlan\nlxc.net.0.link = $VLAN_INTERFACE\nlxc.net.0.flags = up\nlxc.net.0.hwaddr = $(printf '00:16:3e:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))" | sudo tee -a /var/lib/lxc/$LXC_NAME/config

            echo "Starting LXC container: $LXC_NAME"
            sudo lxc-start -n "$LXC_NAME" -d
            sleep 3

            echo "Assigning IP $CONTAINER_IP to $LXC_NAME"
	    sleep 10
	    sudo lxc-attach -n "$LXC_NAME" -- bash -c "
    		ip addr add $CONTAINER_IP/24 dev eth0
    		ip link set eth0 up
    		ip route add default via $GATEWAY_IP
	    "
        done
        echo "LXC container setup completed successfully."
        ;;
    stop)
        echo "Stopping and cleaning up LXC containers..."
        for LXC in $(sudo lxc-ls | grep "^$CONTAINER_PREFIX"); do
            echo "Stopping and removing container: $LXC"
            sudo lxc-stop -n "$LXC"
            sudo lxc-destroy -n "$LXC"
        done
        echo "Cleanup completed successfully."
        ;;
    *)
        usage
        ;;
esac
