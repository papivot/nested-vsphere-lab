#!/usr/bin/env bats
# registry :: docker daemon.json render
load _helper

setup() { load_libs; source_step 70-registry.sh; sample_model; }

@test "daemon.json is valid JSON with jumbo MTU" {
  out=$(_daemon_json_render)
  echo "$out" | jq -e . >/dev/null
  [ "$(echo "$out" | jq -r '.mtu')" = "9000" ]
}
