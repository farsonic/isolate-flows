#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 [-i interface] [-m uplink_mac] [-v vlan_id] [-s subnet] [-c vm_count] {start|stop}"
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

# Function to validate VM count
validate_vm_count() {
    local count=$1
    if [[ ! $count =~ ^[0-9]+$ ]] || [ $count -lt 1 ]; then
        echo "Invalid VM count: $count. VM count must be a positive integer."
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
        c ) VM_COUNT=$OPTARG ;;
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

if [ -n "$VM_COUNT" ]; then
    validate_vm_count "$VM_COUNT"
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
    VM_COUNT=${VM_COUNT:-$(read -p "Enter the number of VM instances to create: " val && echo $val)}
    SUBNET=${SUBNET:-$(read -p "Enter the subnet (e.g., 192.168.10.0/24): " val && echo $val)}
fi

VLAN_INTERFACE="vlan.${VLAN_ID}"
GATEWAY_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.1/')
BASE_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.10/')

# Define variables
BASE_IMAGE="/var/tmp/ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img"
IMAGE_URL="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img"
VM_DIR="/var/tmp"
VM_PREFIX="VM_MACVTAP_"

# Function to generate cloud-init configuration
generate_cloud_init() {
    local VM_NAME="$1"
    local VM_IP="$2"
    local CLOUD_INIT_DIR="$VM_DIR/$VM_NAME-cloud-init"
    local USER_DATA="$CLOUD_INIT_DIR/user-data"
    local META_DATA="$CLOUD_INIT_DIR/meta-data"
    local NETWORK_CONFIG="$CLOUD_INIT_DIR/network-config"

    mkdir -p "$CLOUD_INIT_DIR"

    # Create user-data
    cat <<EOL > "$USER_DATA"
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub)
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOL

    # Create meta-data
    cat <<EOL > "$META_DATA"
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOL

    # Create network-config
    cat <<EOL > "$NETWORK_CONFIG"
version: 2
ethernets:
  enp0s2:
    dhcp4: no
    addresses:
      - $VM_IP/24
    gateway4: $GATEWAY_IP
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOL

    # Create ISO for cloud-init
    genisoimage -output "$VM_DIR/$VM_NAME-cloud-init.iso" -volid cidata -joliet -rock "$USER_DATA" "$META_DATA" "$NETWORK_CONFIG"
}

create_vm_xml() {
    local VM_NAME="$1"
    local VM_IMAGE="$VM_DIR/$VM_NAME.img"
    local XML_FILE="$VM_DIR/$VM_NAME.xml"

    cat <<EOL > "$XML_FILE"
<domain type='kvm'>
  <name>$VM_NAME</name>
  <memory unit='KiB'>4194304</memory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-2.9'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$VM_IMAGE'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <source file='$VM_DIR/$VM_NAME-cloud-init.iso'/>
      <target dev='hda' bus='ide'/>
    </disk>
    <interface type="direct">
      <source dev="$VLAN_INTERFACE" mode="private"/>
      <model type="virtio"/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <source mode='bind' path='/var/lib/libvirt/qemu/channel/target/domain-$VM_NAME/org.qemu.guest_agent.0'/>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
  </devices>
</domain>
EOL
}

case "$ACTION" in
    start)
        echo "Starting VM setup..."

        # Ensure required packages are installed
        REQUIRED_PACKAGES=(
            qemu-kvm
            libvirt-daemon-system
            libvirt-clients
            virt-manager
            bridge-utils
            openvswitch-switch
            guestfs-tools
            genisoimage
        )

        echo "Checking required packages..."
        sudo apt update
        for pkg in "${REQUIRED_PACKAGES[@]}"; do
            if ! dpkg -l | grep -qw "$pkg"; then
                echo "Installing missing package: $pkg"
                sudo apt install -y "$pkg"
            fi
        done

        if [ ! -f "$BASE_IMAGE" ]; then
            echo "Base image not found. Downloading..."
            sudo wget -P /var/tmp/ "$IMAGE_URL"
        fi

        echo "Configuring interface: $INTERFACE"
        ip link set up dev "$INTERFACE"

        if ! ip link show "$VLAN_INTERFACE" &>/dev/null; then
            echo "Creating VLAN interface: vlan.${VLAN_ID}"
            ip link add link "$INTERFACE" name "$VLAN_INTERFACE" type vlan id "$VLAN_ID"
        fi

        sudo netplan apply || echo "Netplan apply failed, but continuing."

        for ((i=1; i<=VM_COUNT; i++)); do
            VM_NAME="${VM_PREFIX}${i}"
            VM_IMAGE="$VM_DIR/$VM_NAME.img"
            VM_IP=$(echo $SUBNET | sed "s/\.0\/.*$/.$((9 + i))/")

            echo "Creating VM: $VM_NAME with IP: $VM_IP"
            sudo cp "$BASE_IMAGE" "$VM_IMAGE"
            generate_cloud_init "$VM_NAME" "$VM_IP"
            create_vm_xml "$VM_NAME"

            virsh define "$VM_DIR/$VM_NAME.xml"
            virsh start "$VM_NAME"
        done

        echo "VM setup completed successfully."
        ;;
    stop)
        echo "Stopping and cleaning up VMs..."

        # Stop and undefine VMs
        for VM in $(virsh list --all --name | grep "^$VM_PREFIX"); do
            echo "Shutting down and undefining $VM"
            virsh destroy "$VM" || echo "$VM was not running."
            virsh undefine "$VM"
        done

        echo "Cleaning up MACVTAP interfaces..."

        # Identify and delete MACVTAP interfaces associated with the VLAN
        for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep "^macvtap"); do
            echo "Deleting MACVTAP interface: $iface"
            sudo ip link delete "$iface"
        done

        echo "Cleaning up files in /var/tmp/..."

        # Delete VM-related files in /var/tmp/
        for file in /var/tmp/$VM_PREFIX*; do
            if [ -f "$file" ]; then
                echo "Deleting file: $file"
                sudo rm -f "$file"
            fi
        done

        echo "VM teardown, MACVTAP cleanup, and file cleanup completed successfully."
        ;;
    *)
        usage
        ;;
esac
