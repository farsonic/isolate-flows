#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 -i <interface> -m <uplink_mac> -v <vlan_id> -s <subnet> -c <vm_count> {start|stop}"
    exit 1
}

# Function to validate IP subnet
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "Invalid subnet format: $ip. Use CIDR notation (e.g., 192.168.10.0/24)."
        exit 1
    fi
}

# Function to validate VLAN ID
validate_vlan() {
    local vlan=$1
    if [[ ! $vlan =~ ^[0-9]+$ ]] || [ $vlan -lt 1 ] || [ $vlan -gt 4094 ]; then
        echo "Invalid VLAN ID: $vlan. Must be between 1 and 4094."
        exit 1
    fi
}

# Function to validate VM count
validate_vm_count() {
    local count=$1
    if [[ ! $count =~ ^[0-9]+$ ]] || [ $count -lt 1 ]; then
        echo "Invalid VM count: $count. Must be a positive integer."
        exit 1
    fi
}

# Function to calculate IP address (start at .150)
calculate_ip() {
    local base_ip=$1
    local index=$2
    IFS='/' read -r ip_addr cidr <<< "$base_ip"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip_addr"
    echo "$o1.$o2.$o3.$((150 + index))"
}

# Cleanup function
cleanup() {
    echo "Cleaning up on failure..."
    for VM in $(lxc list --format=json | jq -r '.[].name' | grep '^lxc-macvlan-vm-'); do
        lxc stop "$VM" --force || true
        lxc delete "$VM" || true
    done
    [ -n "$VLAN_INTERFACE" ] && ip link show "$VLAN_INTERFACE" &>/dev/null && ip link del "$VLAN_INTERFACE" || true
    exit 1
}

# Parse arguments
while getopts "i:m:v:s:c:" opt; do
    case ${opt} in
        i ) INTERFACE=$OPTARG ;;
        m ) UPLINK_MAC=$OPTARG ;;
        v ) VLAN_ID=$OPTARG ;;
        s ) SUBNET=$OPTARG ;;
        c ) VM_COUNT=$OPTARG ;;
        * ) usage ;;
    esac
done
shift $((OPTIND -1))

# Ensure required parameters are set
[ -z "$INTERFACE" ] || [ -z "$VLAN_ID" ] || [ -z "$SUBNET" ] || [ -z "$VM_COUNT" ] && usage

# Validate inputs
validate_ip "$SUBNET"
validate_vlan "$VLAN_ID"
validate_vm_count "$VM_COUNT"

# Trap errors
trap cleanup ERR

if [ "$1" == "start" ]; then
    echo "Starting LXC VMs on VLAN $VLAN_ID with subnet $SUBNET"

    VLAN_INTERFACE="vlan.${VLAN_ID}"
    if ! ip link show "$VLAN_INTERFACE" &>/dev/null; then
        echo "Creating VLAN interface: $VLAN_INTERFACE"
        ip link add link "$INTERFACE" name "$VLAN_INTERFACE" type vlan id "$VLAN_ID"
        ip link set dev "$VLAN_INTERFACE" up
    fi

    NETWORK_NAME="macvlan${VLAN_ID}"
    if ! lxc network list | grep -q "$NETWORK_NAME"; then
        lxc network create "$NETWORK_NAME" --type=macvlan parent="$VLAN_INTERFACE"
    fi

    for ((i=1; i<=VM_COUNT; i++)); do
        VM_NAME="lxc-macvlan-vm-${i}"
        VM_IP=$(calculate_ip "$SUBNET" $i)

        echo "Creating LXC VM: $VM_NAME with IP: $VM_IP"
        lxc init ubuntu:22.04 "$VM_NAME" --vm -c security.secureboot=false -s default
        lxc network attach "$NETWORK_NAME" "$VM_NAME" enp5s0
        lxc start "$VM_NAME"

        echo "Waiting for $VM_NAME to be fully operational..."
        while ! lxc exec "$VM_NAME" -- systemctl is-active --quiet lxd-agent; do
            sleep 2
        done

        echo "$VM_NAME is now running. Assigning static IP: $VM_IP"
	sleep 5
        lxc exec "$VM_NAME" -- ip addr add "$VM_IP/24" dev enp5s0
        lxc exec "$VM_NAME" -- ip link set enp5s0 up
    done

    echo "LXC VM setup completed."

elif [ "$1" == "stop" ]; then
    echo "Stopping and deleting all LXC VMs..."
    for VM in $(lxc list --format=json | jq -r '.[].name' | grep '^lxc-macvlan-vm-'); do
        lxc stop "$VM" --force || true
        lxc delete "$VM" || true
    done
    echo "LXC VMs stopped and deleted."
else
    usage
fi
