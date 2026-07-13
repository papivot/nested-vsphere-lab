#!/usr/bin/env bats
# Pure render test for stage2 vsanhealth step (RVC command list).
# Run: bats tests/bats/step_vsanhealth.bats
load _helper

setup() { load_libs; sample_model2; source_step2 35-vsanhealth.sh; }

@test "renders the 3 confirmed RVC remediation commands for a cluster path" {
  run _render_vsanhealth_commands "localhost/nested-dc/computers/nested-cluster"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vsan.health.silent_health_check_configure localhost/nested-dc/computers/nested-cluster -a nvmeonhcl"* ]]
  [[ "$output" == *"vsan.health.silent_health_check_configure localhost/nested-dc/computers/nested-cluster -a vsanenablesupportinsight"* ]]
  [[ "$output" == *"vsan.perf.stats_object_create localhost/nested-dc/computers/nested-cluster"* ]]
}

@test "renders exactly 3 lines" {
  run _render_vsanhealth_commands "localhost/dc/computers/c1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
}
