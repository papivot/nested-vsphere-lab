#!/usr/bin/env bats
# Static structure + input validity checks. Run: bats tests/bats/structure.bats

ROOT="${BATS_TEST_DIRNAME}/../.."

@test "entrypoints exist and are executable" {
  [ -x "${ROOT}/run.sh" ]
  [ -x "${ROOT}/bootstrap.sh" ]
}

@test "library files present" {
  for f in common ipcalc yaml os; do [ -f "${ROOT}/lib/${f}.sh" ]; done
}

@test "all stage-1 steps present" {
  for s in 00-preflight 10-base_os 20-certs 30-networking 40-routing 50-dns 60-dhcp 70-registry 90-labinfo; do
    [ -f "${ROOT}/stages/stage1-jumpbox/steps/${s}.sh" ]
  done
}

@test "rollbacks present for mutating steps" {
  for s in 20-certs 30-networking 40-routing 50-dns 60-dhcp 70-registry; do
    [ -f "${ROOT}/stages/stage1-jumpbox/rollback/${s}.sh" ]
  done
}

@test "stage dispatcher + verify present" {
  [ -f "${ROOT}/stages/stage1-jumpbox/stage.sh" ]
  [ -f "${ROOT}/stages/stage1-jumpbox/verify.sh" ]
}

@test "all stage-2 steps present" {
  for s in 00-preflight 10-esxi 20-vcenter 25-imageseed 30-cluster 40-supervisor 90-labinfo; do
    [ -f "${ROOT}/stages/stage2-nested-vsphere/steps/${s}.sh" ]
  done
}

@test "stage-2 rollbacks present for every mutating step" {
  for s in 10-esxi 20-vcenter 25-imageseed 30-cluster 40-supervisor; do
    [ -f "${ROOT}/stages/stage2-nested-vsphere/rollback/${s}.sh" ]
  done
}

@test "stage-2 dispatcher + verify + templates present" {
  [ -f "${ROOT}/stages/stage2-nested-vsphere/stage.sh" ]
  [ -f "${ROOT}/stages/stage2-nested-vsphere/verify.sh" ]
  [ -f "${ROOT}/stages/stage2-nested-vsphere/templates/esxi.template.json" ]
  [ -f "${ROOT}/stages/stage2-nested-vsphere/templates/vcsa.esxi.json.tmpl" ]
  [ -f "${ROOT}/stages/stage2-nested-vsphere/templates/vcsa.vc.json.tmpl" ]
  [ -f "${ROOT}/stages/stage2-nested-vsphere/templates/enable_flb.json.tmpl" ]
  [ -f "${ROOT}/lib/govc.sh" ]
}

@test "example input is valid YAML (yq)" {
  if ! command -v yq >/dev/null 2>&1; then skip "yq not installed"; fi
  run yq '.network.vlans | length' "${ROOT}/input.example.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "secrets example present, real secrets file is not committed" {
  [ -f "${ROOT}/secrets.example.env" ]
  [ ! -f "${ROOT}/secrets.env" ]
}
