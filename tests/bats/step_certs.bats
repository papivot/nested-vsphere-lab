#!/usr/bin/env bats
# certs :: SAN render + a real CA/leaf/verify round-trip (_certs_pki)
load _helper

setup() {
  load_libs; source_step 20-certs.sh; sample_model
  TMP="$(mktemp -d)"; CERTS_DIR="$TMP"; CA_BUNDLE="$TMP/ca-bundle.crt"
}
teardown() { rm -rf "$TMP"; }

@test "leaf SAN includes registry FQDN and IP" {
  run _leaf_san
  [ "$output" = "DNS:registry.env1.lab.test,IP:192.168.100.10" ]
}

@test "self-signed CA + leaf are generated and verify" {
  if ! openssl req -help 2>&1 | grep -q -- '-addext'; then skip "openssl lacks -addext"; fi
  _certs_pki "$CERTS_DIR"
  [ -f "$CERTS_DIR/root-ca.key" ]
  [ -f "$CERTS_DIR/root-ca.crt" ]
  [ -f "$CA_BUNDLE" ]
  [ -f "$CERTS_DIR/registry.crt" ]
  run openssl verify -CAfile "$CA_BUNDLE" "$CERTS_DIR/registry.crt"
  [ "$status" -eq 0 ]
}

@test "issued leaf carries the SAN (DNS + IP)" {
  if ! openssl req -help 2>&1 | grep -q -- '-addext'; then skip "openssl lacks -addext"; fi
  _certs_pki "$CERTS_DIR"
  run openssl x509 -in "$CERTS_DIR/registry.crt" -noout -text
  [[ "$output" == *"DNS:registry.env1.lab.test"* ]]
  [[ "$output" == *"192.168.100.10"* ]]
}

@test "CA cert is a CA (basicConstraints CA:TRUE)" {
  if ! openssl req -help 2>&1 | grep -q -- '-addext'; then skip "openssl lacks -addext"; fi
  _certs_pki "$CERTS_DIR"
  run openssl x509 -in "$CERTS_DIR/root-ca.crt" -noout -text
  [[ "$output" == *"CA:TRUE"* ]]
}
