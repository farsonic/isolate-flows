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

# Detect the physical interface by MAC address if UPLINK_MAC is set
if [ -n "$UPLINK_MAC" ] && [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -v mac="$UPLINK_MAC" '$0 ~ mac && !($2 ~ /@/) {print $2; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "No physical interface found with MAC address $UPLINK_MAC. Exiting."
        exit 1
    fi
    echo "Using physical interface $INTERFACE for MAC $UPLINK_MAC"
fi

if [ "$ACTION" == "start" ]; then
    # Prompt user for input only if starting
    INTERFACE=${INTERFACE:-$(read -p "Enter the uplink interface name: " val && echo $val)}
    VLAN_ID=${VLAN_ID:-$(read -p "Enter VLAN number: " val && echo $val)}
    CONTAINER_COUNT=${CONTAINER_COUNT:-$(read -p "Enter the number of Docker containers to create: " val && echo $val)}
    SUBNET=${SUBNET:-$(read -p "Enter the subnet (e.g., 192.168.10.0/24): " val && echo $val)}
fi

VLAN_INTERFACE="vlan.${VLAN_ID}"
GATEWAY_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.1/')
BASE_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.100/')

# Define variables
CONTAINER_PREFIX="docker_macvtap_"

case "$ACTION" in
    start)
        echo "Starting Docker container setup..."

        # Ensure required packages are installed
        REQUIRED_PACKAGES=(
            docker.io
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

        echo "Configuring interface: $INTERFACE"
        ip link set up dev "$INTERFACE"

        if ! ip link show "$VLAN_INTERFACE" &>/dev/null; then
            echo "Creating VLAN interface: vlan.${VLAN_ID}"
            ip link add link "$INTERFACE" name "$VLAN_INTERFACE" type vlan id "$VLAN_ID"
            ip link set dev "$VLAN_INTERFACE" up
        fi

        echo "Creating MACVTAP interfaces and linking to containers..."
        for ((i=1; i<=CONTAINER_COUNT; i++)); do
            MACVTAP_INTERFACE="macvtap${i}"
            CONTAINER_NAME="${CONTAINER_PREFIX}${i}"
            CONTAINER_IP=$(echo $SUBNET | sed "s/\.0\/.*$/.$((99 + i))/")

            if ! ip link show "$MACVTAP_INTERFACE" &>/dev/null; then
                echo "Creating MACVTAP interface: $MACVTAP_INTERFACE"
                ip link add link "$VLAN_INTERFACE" name "$MACVTAP_INTERFACE" type macvtap mode private
                ip link set dev "$MACVTAP_INTERFACE" up
            else
                echo "MACVTAP interface $MACVTAP_INTERFACE already exists. Skipping."
            fi

            echo "Starting Docker container: $CONTAINER_NAME with IP: $CONTAINER_IP"
            docker run -d --rm --name "$CONTAINER_NAME" \
                --network none \
                --privileged \
                --cap-add=NET_ADMIN \
                alpine sh -c "sleep infinity"

            # Get container PID and ensure namespace link exists
            PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME")
            if [ -n "$PID" ] && [ "$PID" -gt 0 ]; then
                sudo mkdir -p /var/run/netns
                sudo ln -sfT /proc/$PID/ns/net /var/run/netns/$CONTAINER_NAME

                # Move MACVTAP into container and rename it to eth0
                echo "Assigning MACVTAP interface $MACVTAP_INTERFACE to $CONTAINER_NAME as eth0"
                sudo ip link set "$MACVTAP_INTERFACE" netns "$PID"
                sudo nsenter --net=/proc/$PID/ns/net ip link set dev "$MACVTAP_INTERFACE" name eth0

                # Assign IP inside the container
                sudo nsenter --net=/proc/$PID/ns/net ip addr add "$CONTAINER_IP/24" dev eth0
                sudo nsenter --net=/proc/$PID/ns/net ip link set eth0 up
                sudo nsenter --net=/proc/$PID/ns/net ip route add default via "$GATEWAY_IP"

                echo "MACVTAP interface successfully assigned as eth0 in $CONTAINER_NAME with IP $CONTAINER_IP"
            else
                echo "Failed to retrieve PID for container $CONTAINER_NAME"
                exit 1
            fi
        done
        echo "Docker container setup completed successfully."
        ;;
    stop)
        echo "Stopping and cleaning up Docker containers..."
        for CONTAINER in $(docker ps -a --format "{{.Names}}" | grep "^$CONTAINER_PREFIX"); do
            echo "Stopping and removing container: $CONTAINER"
            docker stop "$CONTAINER"
        done
        echo "Cleanup completed successfully."
        ;;
    *)
        usage
        ;;
esac
