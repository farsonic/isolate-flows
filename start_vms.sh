#!/bin/bash

# Set script to exit on error
set -e

# Define variables
IMAGE_URL="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img"
IMAGE_PATH="/var/tmp/ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img"
VM1_IMAGE="/var/tmp/vm1.img"
VM2_IMAGE="/var/tmp/vm2.img"
CONFIG_SCRIPT="/home/pensando/isolate-flows/configure-vm.sh"
VM1_XML="/home/pensando/isolate-flows/vm1.xml"
VM2_XML="/home/pensando/isolate-flows/vm2.xml"

# Make configure script executable
chmod +x "$CONFIG_SCRIPT"

# Download Ubuntu cloud image
sudo wget -P /var/tmp/ "$IMAGE_URL"

# Set root password in the cloud image
sudo virt-customize -a "$IMAGE_PATH" --root-password password:ubuntu

# Run virt-sysprep to clean the image
sudo virt-sysprep -a "$IMAGE_PATH"

# Copy the image for VM1 and VM2
sudo cp "$IMAGE_PATH" "$VM1_IMAGE"
sudo cp "$IMAGE_PATH" "$VM2_IMAGE"

# Set up network interfaces
ip link set up dev ens19
ip link add link ens19 name vlan.10 type vlan id 10

# Configure the VMs
"$CONFIG_SCRIPT" vm1
"$CONFIG_SCRIPT" vm2

# Define VMs with virsh
virsh define "$VM1_XML"
virsh define "$VM2_XML"

# Start the VMs
virsh start vm1
virsh start vm2

# Print completion message
echo "VM setup completed successfully."
