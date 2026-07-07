#!/usr/bin/env bats
# Pure render tests for stage2 vcenter step. Run: bats tests/bats/step_vcenter.bats
load _helper

setup() {
  command -v envsubst >/dev/null || skip "envsubst not installed"
  load_libs; sample_model2; source_step2 20-vcenter.sh
}

@test "vcsa install config renders valid JSON with static network + sso" {
  run _render_vcsa_json
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
  echo "$output" | jq -e '.new_vcsa.network.ip        == "192.168.100.50"'
  echo "$output" | jq -e '.new_vcsa.network.prefix     == "24"'
  echo "$output" | jq -e '.new_vcsa.network.gateway    == "192.168.100.1"'
  echo "$output" | jq -e '.new_vcsa.network.system_name == "vcsa.env1.lab.test"'
  echo "$output" | jq -e '.new_vcsa.sso.domain_name    == "vsphere.local"'
  echo "$output" | jq -e '.new_vcsa.appliance.deployment_option == "tiny"'
  echo "$output" | jq -e '.ceip.settings.ceip_enabled  == false'
}

@test "vcsa config targets the underlying esxi + datastore (type=esxi)" {
  run _render_vcsa_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.new_vcsa.esxi.hostname           == "10.0.0.5"'
  echo "$output" | jq -e '.new_vcsa.esxi.datastore          == "datastore1"'
  echo "$output" | jq -e '.new_vcsa.esxi.deployment_network == "VM Network"'
  echo "$output" | jq -e '.new_vcsa.esxi != null and (.new_vcsa.vc == null)'
}

@test "vcsa config targets an existing vCenter when type=vcenter" {
  export UNDERLYING_TYPE=vcenter
  run _render_vcsa_json
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
  echo "$output" | jq -e '.new_vcsa.vc.datacenter[0] == "Datacenter"'
  echo "$output" | jq -e '.new_vcsa.vc.target[0]     == "Cluster1"'
  echo "$output" | jq -e '.new_vcsa.vc.datastore     == "datastore1"'
  echo "$output" | jq -e '.new_vcsa.vc != null and (.new_vcsa.esxi == null)'
}
