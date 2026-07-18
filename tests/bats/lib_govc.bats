#!/usr/bin/env bats
# lib/govc.sh :: pure/env-setting helpers only -- govc_target (no live govc
# call, just sets GOVC_* env vars) and vcsa_rvc_cluster_path (string
# formatting). The rest of lib/govc.sh wraps real govc/curl/ssh calls and is
# exercised live via `./run.sh --stage 2 --verify`, not offline here.
load _helper

setup() {
  load_libs
  source "$TESTROOT/lib/govc.sh"
}

@test "govc_target underlying (esxi): no datacenter/cluster context" {
  UNDERLYING_TYPE=esxi UNDERLYING_HOST=10.0.0.5 UNDERLYING_USER=root
  UNDERLYING_PASSWORD=labpass UNDERLYING_DATASTORE=datastore1
  govc_target underlying
  [ "$GOVC_URL" = "https://10.0.0.5/sdk" ]
  [ "$GOVC_USERNAME" = "root" ]
  [ "$GOVC_DATASTORE" = "datastore1" ]
  [ -z "$GOVC_DATACENTER" ]
}

@test "govc_target underlying (vcenter): sets datacenter + cluster placement" {
  UNDERLYING_TYPE=vcenter UNDERLYING_HOST=vc.example.test UNDERLYING_USER='administrator@vsphere.local'
  UNDERLYING_PASSWORD=labpass UNDERLYING_DATASTORE=datastore1
  UNDERLYING_DATACENTER=Datacenter UNDERLYING_CLUSTER=Cluster1
  govc_target underlying
  [ "$GOVC_DATACENTER" = "Datacenter" ]
  [ "$GOVC_CLUSTER" = "Cluster1" ]
}

@test "govc_target nested-vc: targets the VCSA with the cluster datacenter" {
  VCSA_IP=192.168.100.50 VCSA_USER='administrator@vsphere.local' VCSA_SSO_PASSWORD=labpass
  CLUSTER_DC=nested-dc
  govc_target nested-vc
  [ "$GOVC_URL" = "https://192.168.100.50/sdk" ]
  [ "$GOVC_DATACENTER" = "nested-dc" ]
}

@test "govc_target nested-esxi: requires an IP argument" {
  ESXI_ROOT_PASSWORD=labpass
  govc_target nested-esxi 192.168.100.51
  [ "$GOVC_URL" = "https://192.168.100.51/sdk" ]
  [ "$GOVC_USERNAME" = "root" ]
  run govc_target nested-esxi
  [ "$status" -ne 0 ]
}

@test "govc_target rejects an unknown target" {
  run govc_target bogus
  [ "$status" -ne 0 ]
}

@test "vcsa_rvc_cluster_path formats the localhost/dc/computers/cluster path" {
  CLUSTER_DC=nested-dc CLUSTER_NAME=nested-cluster
  run vcsa_rvc_cluster_path
  [ "$output" = "localhost/nested-dc/computers/nested-cluster" ]
}
