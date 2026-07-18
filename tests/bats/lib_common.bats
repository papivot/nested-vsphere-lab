#!/usr/bin/env bats
# lib/common.sh :: is_ipv4 (pure validation) and ensure_line (idempotent
# file-line append). write_file has its own dedicated lib_write_file.bats.
load _helper

setup() { load_libs; }

@test "is_ipv4 accepts valid dotted-quad addresses" {
  is_ipv4 "192.168.100.1"
  is_ipv4 "0.0.0.0"
  is_ipv4 "255.255.255.255"
}

@test "is_ipv4 rejects an out-of-range octet" {
  run is_ipv4 "256.1.1.1"
  [ "$status" -ne 0 ]
}

@test "is_ipv4 rejects too few or too many octets" {
  run is_ipv4 "192.168.1"
  [ "$status" -ne 0 ]
  run is_ipv4 "192.168.1.1.1"
  [ "$status" -ne 0 ]
}

@test "is_ipv4 rejects non-numeric input" {
  run is_ipv4 "not.an.ip.address"
  [ "$status" -ne 0 ]
}

@test "ensure_line appends a missing line, is a no-op if already present" {
  F="$(mktemp)"
  ensure_line "$F" "hello"
  [ "$(cat "$F")" = "hello" ]
  ensure_line "$F" "hello"
  [ "$(wc -l < "$F" | tr -d ' ')" -eq 1 ]
  ensure_line "$F" "world"
  [ "$(cat "$F")" = "$(printf 'hello\nworld')" ]
  rm -f "$F"
}

@test "ensure_line creates the file if it does not exist yet" {
  F="$(mktemp -u)"
  [ ! -e "$F" ]
  ensure_line "$F" "first line"
  [ "$(cat "$F")" = "first line" ]
  rm -f "$F"
}
