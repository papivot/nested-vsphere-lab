#!/usr/bin/env bats
# routing :: nftables / routes / FRR renders
load _helper

setup() { load_libs; source_step 40-routing.sh; sample_model; }

@test "private iface list is unique and comma-joined" {
  run _priv_iface_list
  [ "$output" = "ens224,ens224.101,ens224.102" ]
}

@test "nft has masquerade out the public NIC when nat=true" {
  sset '.routing.nat' true
  run _nft_render
  [[ "$output" == *'oifname $PUBLIC masquerade'* ]]
  [[ "$output" == *'define PUBLIC = "ens192"'* ]]
  [[ "$output" == *"ens224.101"* ]]
}

@test "nft omits masquerade when nat=false" {
  sset '.routing.nat' false
  run _nft_render
  [[ "$output" != *"masquerade"* ]]
}

@test "routes render uses ip route replace" {
  slen '.routing.static_routes' 1
  sset '.routing.static_routes[0].dest' 192.168.103.0/24
  sset '.routing.static_routes[0].via'  192.168.101.2
  run _routes_render
  [[ "$output" == *"ip route replace 192.168.103.0/24 via 192.168.101.2"* ]]
}

@test "FRR config has ASN, neighbor and advertised networks" {
  sset '.routing.bgp.local_asn' 65010
  sset '.routing.bgp.router_id' 192.168.100.1
  slen '.routing.bgp.neighbors' 1
  sset '.routing.bgp.neighbors[0].ip' 10.0.0.1
  sset '.routing.bgp.neighbors[0].asn' 65000
  run _frr_render
  [[ "$output" == *"router bgp 65010"* ]]
  [[ "$output" == *"neighbor 10.0.0.1 remote-as 65000"* ]]
  [[ "$output" == *"network 192.168.100.0/24"* ]]
  [[ "$output" == *"neighbor 10.0.0.1 activate"* ]]
}
