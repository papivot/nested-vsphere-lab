#!/usr/bin/env bats
# Pure render test for stage2 labinfo step (Stage 2 access summary sheet).
# Named step_labinfo2 (not step_labinfo) to avoid colliding with Stage 1's
# 90-labinfo.sh, which has the same basename but lives under stage1-jumpbox/.
# Run: bats tests/bats/step_labinfo2.bats
load _helper

setup() { load_libs; sample_model2; source_step2 90-labinfo.sh; }

@test "summary lists vCenter, ESXi hosts, cluster and Supervisor details" {
  run _lab2info_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://vcsa.env1.lab.test/ui/"* ]]
  [[ "$output" == *"administrator@vsphere.local"* ]]
  [[ "$output" == *"esxi01.env1.lab.test"*"192.168.100.51"* ]]
  [[ "$output" == *"esxi02.env1.lab.test"*"192.168.100.52"* ]]
  [[ "$output" == *"esxi03.env1.lab.test"*"192.168.100.53"* ]]
  [[ "$output" == *"Datacenter : nested-dc"* ]]
  [[ "$output" == *"Cluster    : nested-cluster"* ]]
  [[ "$output" == *"vsanDatastore  (OSA, FTT=1)"* ]]
  [[ "$output" == *"Name             : supervisor"* ]]
  [[ "$output" == *"--server 192.168.103.10"* ]]
  [[ "$output" == *"https://registry.env1.lab.test/"* ]]
}

@test "credentials point at secrets.env, never printed in the clear" {
  run _lab2info_render
  [[ "$output" == *"(in secrets.env VCSA_SSO_PASSWORD)"* ]]
  [[ "$output" == *"(in secrets.env ESXI_ROOT_PASSWORD)"* ]]
  [[ "$output" != *labpass* ]]
}
