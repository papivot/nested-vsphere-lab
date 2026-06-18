#!/usr/bin/env bats
# networking :: per-OS render functions
load _helper

setup() { load_libs; source_step 30-networking.sh; sample_model; }

@test "netplan: native addr under ethernets, tagged under vlans, jumbo MTU" {
  run _net_render_debian
  [[ "$output" == *"mtu: 9000"* ]]
  [[ "$output" == *"- 192.168.100.1/24"* ]]      # native on the physical NIC
  [[ "$output" == *"ens224.101:"* ]]             # tagged vlan iface
  [[ "$output" == *"id: 101"* ]]
  [[ "$output" == *"link: ens224"* ]]
  [[ "$output" == *"addresses: [192.168.101.1/24]"* ]]
}

@test "nmcli: native is ethernet on the physical NIC" {
  run _net_nmcli_addargs 0
  [[ "$output" == *"type ethernet"* ]]
  [[ "$output" == *"ifname ens224"* ]]
  [[ "$output" == *"ipv4.addresses 192.168.100.1/24"* ]]
  [[ "$output" == *"ethernet.mtu 9000"* ]]
}

@test "nmcli: tagged is a vlan with id + parent dev" {
  run _net_nmcli_addargs 1
  [[ "$output" == *"type vlan"* ]]
  [[ "$output" == *"dev ens224"* ]]
  [[ "$output" == *"id 101"* ]]
  [[ "$output" == *"ipv4.addresses 192.168.101.1/24"* ]]
}

@test "networkd: physical .network lists native addr + VLAN refs" {
  run _net_render_photon_main
  [[ "$output" == *"Name=ens224"* ]]
  [[ "$output" == *"MTUBytes=9000"* ]]
  [[ "$output" == *"Address=192.168.100.1/24"* ]]
  [[ "$output" == *"VLAN=ens224.101"* ]]
  [[ "$output" == *"VLAN=ens224.102"* ]]
}

@test "networkd: per-vlan netdev carries the tag id + jumbo MTU" {
  run _net_render_photon_netdev 1
  [[ "$output" == *"Kind=vlan"* ]]
  [[ "$output" == *"Id=101"* ]]
  [[ "$output" == *"MTUBytes=9000"* ]]
}

@test "registry secondary IP is added on its VLAN interface (all 3 renderers)" {
  V_EXTRA=(192.168.100.10 "" "")    # registry IP held on the native iface
  run _net_render_debian
  [[ "$output" == *"- 192.168.100.10/24"* ]]
  run _net_nmcli_addargs 0
  [[ "$output" == *"ipv4.addresses 192.168.100.1/24,192.168.100.10/24"* ]]
  run _net_render_photon_main
  [[ "$output" == *"Address=192.168.100.10/24"* ]]
}

@test "no secondary IP rendered when V_EXTRA is empty" {
  run _net_render_debian
  [[ "$output" != *"192.168.100.10"* ]]
}
