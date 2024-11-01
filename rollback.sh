#!/bin/bash

# Remove downloaded images
cd /mnt/kvm/boot/
sudo rm -f ubuntu-20.04-server-cloudimg-amd64-disk-kvm.img
sudo rm -f vm1.img vm2.img vm3.img vm4.img vm5.img vm6.img

# Remove defined VMs
virsh undefine vm1
virsh undefine vm2
virsh undefine vm3
virsh undefine vm4
virsh undefine vm5
virsh undefine vm6

virsh destroy vm1
virsh destroy vm2
virsh destroy vm3
virsh destroy vm4
virsh destroy vm5
virsh destroy vm6


# Remove VLAN and bridge configurations
sudo ip link set br-vlan10 down
sudo ip link delete vlan.10
sudo ip link delete br-vlan.10
sudo brctl delbr br-vlan10
sudo ovs-vsctl del-br br-ovs


