#!/bin/bash

set -e

# Parse command line arguments
while getopts "i:m:v:s:c:" opt; do
  case ${opt} in
    i ) INTERFACE=$OPTARG ;;
    m ) UPLINK_MAC=$OPTARG ;;
    v ) VLAN_ID=$OPTARG ;;
    s ) SUBNET=$OPTARG ;;
    c ) VM_COUNT=$OPTARG ;;
    * ) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND -1))

# Detect the physical interface by MAC address if UPLINK_MAC is set
if [ -n "$UPLINK_MAC" ] && [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -v mac="$UPLINK_MAC" '$0 ~ mac && !($2 ~ /@/) {print $2; exit}')
    if [ -z "$INTERFACE" ]; then
        echo "No physical interface found with MAC address $UPLINK_MAC. Exiting."
        exit 1
    fi
    echo "Using physical interface $INTERFACE for MAC $UPLINK_MAC"
fi

# Prompt user for input if environment variables or arguments are not set
INTERFACE=${INTERFACE:-$(read -p "Enter the uplink interface name: " val && echo $val)}
VLAN_ID=${VLAN_ID:-$(read -p "Enter VLAN number: " val && echo $val)}
VM_COUNT=${VM_COUNT:-$(read -p "Enter the number of VM instances to create: " val && echo $val)}
SUBNET=${SUBNET:-$(read -p "Enter the subnet (e.g., 192.168.10.0/24): " val && echo $val)}

VLAN_INTERFACE="vlan.${VLAN_ID}"
GATEWAY_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.1/')
BASE_IP=$(echo $SUBNET | sed 's/\.0\/.*$/.10/')

# Define variables
BASE_IMAGE="/var/tmp/ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img"
IMAGE_URL="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img"
VM_DIR="/var/tmp"
VM_PREFIX="MACVLAN_"

create_vm_conf() {
    local VM_NAME="$1"
    local VM_IP="$2"
    local CONF_FILE="$VM_DIR/$VM_NAME.conf"
    
    cat <<EOL > "$CONF_FILE"
network:
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
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
    </disk>
    <interface type="direct">
      <source dev="$VLAN_INTERFACE" mode="private"/>
      <target dev="macvtap0"/>
      <model type="virtio"/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
EOL
}

case "$1" in
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
        )
        
        echo "Checking required packages..."
        sudo apt update
        for pkg in "${REQUIRED_PACKAGES[@]}"; do
            if ! dpkg -l | grep -qw "$pkg"; then
                echo "Installing missing package: $pkg"
                sudo apt install -y "$pkg"
            else
                echo "Package $pkg is already installed."
            fi
        done
        
        if [ ! -f "$BASE_IMAGE" ]; then
            echo "Base image not found. Downloading..."
            sudo wget -P /var/tmp/ "$IMAGE_URL"
        else
            echo "Base image already exists. Skipping download."
        fi

        sudo virt-customize -a "$BASE_IMAGE" --root-password password:ubuntu
        sudo virt-sysprep -a "$BASE_IMAGE"

        echo "Configuring interface: $INTERFACE"
        ip link set up dev "$INTERFACE"
        
        if ! ip link show "$VLAN_INTERFACE" &>/dev/null; then
            echo "Creating VLAN interface: vlan.${VLAN_ID}"
            ip link add link "$INTERFACE" name "$VLAN_INTERFACE" type vlan id "$VLAN_ID"
        else
            echo "VLAN interface vlan.${VLAN_ID} already exists, skipping creation."
        fi

        sudo netplan apply || echo "Netplan apply failed, but continuing."
        
        for ((i=1; i<=VM_COUNT; i++)); do
            VM_NAME="${VM_PREFIX}${i}"
            VM_IMAGE="$VM_DIR/$VM_NAME.img"
            VM_IP=$(echo $SUBNET | sed "s/\.0\/.*$/.$((9 + i))/")

            echo "Creating VM: $VM_NAME"
            sudo cp "$BASE_IMAGE" "$VM_IMAGE"
            create_vm_xml "$VM_NAME"
            create_vm_conf "$VM_NAME" "$VM_IP"
            virsh define "$VM_DIR/$VM_NAME.xml"
            virsh start "$VM_NAME"
        done

        echo "VM setup completed successfully."
        ;;
    stop)
        echo "Stopping and cleaning up VMs..."
        for VM in $(virsh list --all --name | grep "^$VM_PREFIX"); do
            echo "Shutting down and undefining $VM"
            virsh destroy "$VM" || echo "$VM was not running."
            virsh undefine "$VM"
        done
        echo "VM teardown completed successfully."
        ;;
    *)
        usage
        ;;
esac
