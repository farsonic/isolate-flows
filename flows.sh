#!/bin/bash

# Define the OVS bridge and physical interface
OVS_BRIDGE="br-ovs"
PHYSICAL_INTERFACE="ens20"
VLAN_ID=10

# Function to get VM interfaces and MAC addresses attached to the specified OVS bridge
get_vm_interfaces() {
    for vm in $(virsh list --name --state-running); do
        # Filter interfaces attached to the specified OVS bridge
        virsh domiflist "$vm" | awk -v bridge="$OVS_BRIDGE" '$3 == bridge {print $1, $5}'
    done
}

# Function to remove existing flows for each VM interface
remove_existing_flows() {
    echo "Removing existing flows for VM interfaces attached to $OVS_BRIDGE..."
    while IFS=" " read -r vnet_interface mac_address; do
        # Remove flows for the specific VM interface
        sudo ovs-ofctl del-flows "$OVS_BRIDGE" "in_port=$vnet_interface"
        sudo ovs-ofctl del-flows "$OVS_BRIDGE" "in_port=$PHYSICAL_INTERFACE,dl_dst=$mac_address"
        echo "Removed flows for $vnet_interface with MAC $mac_address"
    done < <(get_vm_interfaces)
}

# Function to generate and apply new flow rules for each VM interface
apply_flow_rules() {
    echo "Applying new flow rules for VM interfaces attached to $OVS_BRIDGE..."
    while IFS=" " read -r vnet_interface mac_address; do
        # Outbound rule from VM to external network with VLAN tagging
        sudo ovs-ofctl add-flow "$OVS_BRIDGE" "in_port=$vnet_interface, actions=mod_vlan_vid:$VLAN_ID,output=$PHYSICAL_INTERFACE"

        # Inbound rule from external network to VM, matching on MAC and stripping VLAN tag
        sudo ovs-ofctl add-flow "$OVS_BRIDGE" "in_port=$PHYSICAL_INTERFACE, dl_dst=$mac_address, actions=strip_vlan,output=$vnet_interface"

        echo "Applied flows for $vnet_interface with MAC $mac_address"
    done < <(get_vm_interfaces)
}

# Prompt user for confirmation
read -p "Do you want to remove existing flows and apply new ones for VMs on $OVS_BRIDGE? (y/n): " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    # Remove existing flows, then apply new flows
    remove_existing_flows
    apply_flow_rules
    echo "Flow rules have been updated."
else
    echo "Operation canceled by the user."
fi
