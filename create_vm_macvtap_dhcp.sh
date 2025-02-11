#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 [-i interface] [-m uplink_mac] [-v vlan_id] [-c vm_count] {start|stop}"
    exit 1
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
while getopts "i:m:v:c:" opt; do
    case ${opt} in
        i ) INTERFACE=$OPTARG ;;
        m ) UPLINK_MAC=$OPTARG ;;
        v ) VLAN_ID=$OPTARG ;;
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

if [ -n "$VLAN_ID" ]; then
    validate_vlan "$VLAN_ID"
fi

if [ -n "$VM_COUNT" ]; then
    validate_vm_count "$VM_COUNT"
fi

VLAN_INTERFACE="vlan.${VLAN_ID}"

# Function to generate cloud-init configuration
generate_cloud_init() {
    local VM_NAME="$1"
    local CLOUD_INIT_DIR="$VM_DIR/$VM_NAME-cloud-init"
    local USER_DATA="$CLOUD_INIT_DIR/user-data"
    local META_DATA="$CLOUD_INIT_DIR/meta-data"

    mkdir -p "$CLOUD_INIT_DIR"

    # Create user-data
    cat <<EOL > "$USER_DATA"
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
users:
  - name: pensando
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: "\$6\$rounds=4096\$X9n6vNh2JGfo3TXK\$wtxph.YGJh/ZrVf7AIpi3pbDdAPPl2Xo5shXfCWuy6D0lY59Vx0jASZa5NA8T4WNeRe2P84c7b9R1ST6mXhyN."
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

    # Create ISO for cloud-init
    genisoimage -output "$VM_DIR/$VM_NAME-cloud-init.iso" -volid cidata -joliet -rock "$USER_DATA" "$META_DATA"
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
        
        echo "Configuring VLAN interface: $VLAN_INTERFACE"
        ip link add link "$INTERFACE" name "$VLAN_INTERFACE" type vlan id "$VLAN_ID"
        ip link set up dev "$VLAN_INTERFACE"
        
        echo "VM setup completed successfully."
        ;;
    stop)
        echo "Stopping and cleaning up VMs..."
        
        for VM in $(virsh list --all --name | grep "^VM_"); do
            echo "Shutting down and undefining $VM"
            virsh destroy "$VM" || echo "$VM was not running."
            virsh undefine "$VM"
        done
        
        echo "Removing VLAN interface: $VLAN_INTERFACE"
        ip link del "$VLAN_INTERFACE" || true
        
        echo "VM teardown completed successfully."
        ;;
    *)
        usage
        ;;
esac
