#!/usr/bin/env bats
# base_os :: chrony + proxy renders
load _helper

setup() { load_libs; source_step 10-base_os.sh; sample_model; }

@test "chrony uses upstream servers from input" {
  slen '.ntp.upstream' 1; sset '.ntp.upstream[0]' 10.0.0.10
  run _chrony_render
  [[ "$output" == *"server 10.0.0.10 iburst"* ]]
  [[ "$output" == *"driftfile /var/lib/chrony/drift"* ]]
}

@test "chrony falls back to time.vmware.com when no upstream" {
  slen '.ntp.upstream' 0
  run _chrony_render
  [[ "$output" == *"server time.vmware.com iburst"* ]]
}

@test "no proxy -> empty render" {
  run _proxy_render
  [ -z "$output" ]
}

@test "proxy render exports http/https/no_proxy" {
  sset '.proxy.http' http://p:3128; sset '.proxy.https' http://p:3128; sset '.proxy.no_proxy' localhost,127.0.0.1
  run _proxy_render
  [[ "$output" == *'export http_proxy="http://p:3128"'* ]]
  [[ "$output" == *'export HTTPS_PROXY="http://p:3128"'* ]]
  [[ "$output" == *'export no_proxy="localhost,127.0.0.1"'* ]]
}
