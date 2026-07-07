#!/usr/bin/env bats
# Pure render tests for stage2 supervisor step (Foundation-LB WCP payload).
# Run: bats tests/bats/step_supervisor.bats
load _helper

setup() {
  command -v envsubst >/dev/null || skip "envsubst not installed"
  load_libs; sample_model2; source_step2 40-supervisor.sh
}

@test "wcp payload renders valid JSON for the Foundation LB provider" {
  run _render_wcp_payload
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
  echo "$output" | jq -e '.workloads.edge.provider == "VSPHERE_FOUNDATION"'
  echo "$output" | jq -e '.name == "supervisor"'
  echo "$output" | jq -e '.control_plane.count == 1'
  echo "$output" | jq -e '.control_plane.size == "TINY"'
}

@test "control-plane range uses a host ADDRESS + count, never a CIDR" {
  run _render_wcp_payload
  [ "$status" -eq 0 ]
  local addr
  addr=$(echo "$output" | jq -r '.control_plane.network.ip_management.ip_assignments[0].ranges[0].address')
  [ "$addr" = "192.168.100.60" ]
  [[ "$addr" != */* ]]     # regression guard: must not be a CIDR
  echo "$output" | jq -e '.control_plane.network.ip_management.ip_assignments[0].ranges[0].count == 5'
  echo "$output" | jq -e '.control_plane.network.ip_management.gateway_address == "192.168.100.1/24"'
}

@test "workload network + service range are wired" {
  run _render_wcp_payload
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.workloads.network.vsphere.dvpg == "dvportgroup-22"'
  # NODE + SERVICE assignments present on the workload network
  echo "$output" | jq -e '[.workloads.network.ip_management.ip_assignments[].assignee] | index("NODE") != null'
  echo "$output" | jq -e '[.workloads.network.ip_management.ip_assignments[].assignee] | index("SERVICE") != null'
  echo "$output" | jq -e '.workloads.storage.ephemeral_storage_policy == "vsan-default"'
}

@test "load balancer VIP range is present" {
  run _render_wcp_payload
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.workloads.edge.load_balancer_address_ranges[0].address == "192.168.103.10"'
  echo "$output" | jq -e '.workloads.edge.load_balancer_address_ranges[0].count == 100'
}
