#!/usr/bin/env bats
# Pure render test for stage2 imageseed step (the one-time manual-gate
# instructions printed when the vLCM depot lacks the nested ESXi build).
# Run: bats tests/bats/step_imageseed.bats
load _helper

setup() { load_libs; sample_model2; source_step2 25-imageseed.sh; }

@test "instructions name the seed host, datacenter, and vCenter login" {
  run _imageseed_instructions "esxi01.env1.lab.test" "25370933"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://vcsa.env1.lab.test/ui"* ]]
  [[ "$output" == *"administrator@vsphere.local"* ]]
  [[ "$output" == *"datacenter 'nested-dc'"* ]]
  [[ "$output" == *"Host: esxi01.env1.lab.test"* ]]
  [[ "$output" == *"Extract the image on the host"* ]]
  [[ "$output" == *"(25370933)"* ]]
}

@test "instructions render sanely even with no known build yet" {
  run _imageseed_instructions "esxi01.env1.lab.test" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host: esxi01.env1.lab.test"* ]]
  [[ "$output" != *"()"* ]]
}
