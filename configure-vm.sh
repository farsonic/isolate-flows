#!/bin/bash

# Check if VM name is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <vm-name>"
  exit 1
fi

VM_NAME=$1
CONF_URL="https://raw.githubusercontent.com/farsonic/isolate-flows/refs/heads/main/${VM_NAME}.conf"
IMG_PATH="/mnt/kvm/boot/${VM_NAME}.img"
TMP_CONF="/var/tmp/99-netcfg.yaml"

# Download the configuration file
sudo wget -O $TMP_CONF $CONF_URL

# Check if the download was successful
if [ $? -ne 0 ]; then
  echo "Failed to download configuration file from $CONF_URL"
  exit 1
fi

# Customize the VM image
sudo virt-customize -a $IMG_PATH --upload $TMP_CONF:/etc/netplan/99-netcfg.yaml --hostname $VM_NAME --run-command 'netplan apply'

# Clean up the temporary file
rm $TMP_CONF

echo "Configuration applied to $VM_NAME"
