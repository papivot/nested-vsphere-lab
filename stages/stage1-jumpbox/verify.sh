#!/usr/bin/env bash
# ============================================================================
# verify.sh :: read-only live assertions for stage 1. Mirrors verify.yml.
#   ./run.sh --stage 1 --verify
# ============================================================================

VERIFY_FAIL=0
_t_ok()   { ok "TEST: $*"; }
_t_fail() { err "TEST: $*"; VERIFY_FAIL=$((VERIFY_FAIL+1)); }
_assert() { if eval "$1"; then _t_ok "$2"; else _t_fail "$2"; fi; }

verify_main() {
  local i

  # ---- MTU + gateway on each VLAN iface ----
  for ((i=0; i<N_VLANS; i++)); do
    local m; m=$(cat "/sys/class/net/${V_IFACE[i]}/mtu" 2>/dev/null || echo 0)
    [[ "$m" == "$MTU_PRIVATE" ]] && _t_ok "${V_IFACE[i]} MTU=${m}" || _t_fail "${V_IFACE[i]} MTU=${m} expected ${MTU_PRIVATE}"
    if ip -4 addr show dev "${V_IFACE[i]}" 2>/dev/null | grep -qw "${V_GW[i]}"; then
      _t_ok "${V_IFACE[i]} has gateway ${V_GW[i]}"
    else
      _t_fail "${V_IFACE[i]} missing gateway ${V_GW[i]}"
    fi
  done

  # ---- routing / NAT ----
  [[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] && _t_ok "ip_forward enabled" || _t_fail "ip_forward disabled"
  if [[ "$(cfg_bool '.routing.nat' 'true')" == "true" ]]; then
    nft list ruleset 2>/dev/null | grep -q masquerade && _t_ok "nft masquerade present" || _t_fail "nft masquerade missing"
  fi
  if curl -fsS -I --max-time 8 https://www.google.com >/dev/null 2>&1; then _t_ok "egress via NAT works"; else warn "egress check failed (warning only)"; fi

  # ---- DNS forward + reverse ----
  local nr; nr=$(cfg_len '.dns.records')
  for ((i=0; i<nr; i++)); do
    local rn ri out
    rn=$(cfg ".dns.records[$i].name"); ri=$(cfg ".dns.records[$i].ip")
    out=$(dig @"${NATIVE_GW}" +short "${rn}.${DOMAIN}" 2>/dev/null || true)
    [[ "$out" == *"$ri"* ]] && _t_ok "forward ${rn}.${DOMAIN} -> ${ri}" || _t_fail "forward ${rn}.${DOMAIN} got '${out}' expected ${ri}"
    out=$(dig @"${NATIVE_GW}" +short -x "${ri}" 2>/dev/null || true)
    [[ "$out" == *"${rn}.${DOMAIN}"* ]] && _t_ok "reverse ${ri} -> ${rn}.${DOMAIN}" || _t_fail "reverse ${ri} got '${out}'"
  done

  # ---- services ----
  svc_is_active "$BIND_SERVICE" && _t_ok "${BIND_SERVICE} running" || _t_fail "${BIND_SERVICE} not running"
  svc_is_active docker && _t_ok "docker running" || _t_fail "docker not running"

  # ---- Kea ----
  grep -q interface-mtu "$KEA_CONF" && _t_ok "Kea advertises interface-mtu (option 26)" || _t_fail "Kea missing interface-mtu"
  "$KEA_BIN" -t "$KEA_CONF" >/dev/null 2>&1 && _t_ok "Kea config valid" || _t_fail "Kea config invalid"

  # ---- CA / registry cert ----
  if openssl verify -CAfile "$CA_BUNDLE" "${CERTS_DIR}/registry.crt" >/dev/null 2>&1; then
    _t_ok "registry leaf verifies against lab CA"
  else
    _t_fail "registry leaf does NOT verify against lab CA"
  fi

  # ---- registry health + round-trip ----
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_BUNDLE" "https://${REGISTRY_FQDN}/v2/" || true)
  [[ "$code" == "200" || "$code" == "401" ]] && _t_ok "registry /v2/ healthy (HTTP ${code})" || _t_fail "registry /v2/ unhealthy (HTTP ${code})"

  if _verify_roundtrip; then _t_ok "docker push/pull round-trip"; else _t_fail "docker push/pull round-trip failed"; fi

  echo ""
  if (( VERIFY_FAIL == 0 )); then
    ok "ALL stage 1 verification checks PASSED."
  else
    die "${VERIFY_FAIL} verification check(s) FAILED (see above)."
  fi
}

_verify_roundtrip() {
  if [[ "$REGISTRY_AUTH" == "true" ]]; then
    require_secret REGISTRY_ADMIN_PASSWORD "registry admin password"
    echo "$REGISTRY_ADMIN_PASSWORD" | docker login "${REGISTRY_FQDN}" -u admin --password-stdin >/dev/null 2>&1 || return 1
  fi
  docker pull hello-world:latest >/dev/null 2>&1 || return 1
  docker tag hello-world:latest "${REGISTRY_FQDN}/library/hello-world:verify" >/dev/null 2>&1 || return 1
  docker push "${REGISTRY_FQDN}/library/hello-world:verify" >/dev/null 2>&1 || return 1
  docker rmi "${REGISTRY_FQDN}/library/hello-world:verify" >/dev/null 2>&1 || true
  docker pull "${REGISTRY_FQDN}/library/hello-world:verify" >/dev/null 2>&1 || return 1
  return 0
}
