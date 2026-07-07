#!/usr/bin/env bash
# ============================================================================
# preflight :: hard validation gate for Stage 2. Read-only. Fails fast.
# Validates Stage 1 health, underlying target, OVA presence, and sizing.
# ============================================================================

step_preflight() {
  local fail=0
  _pf() { err "PREFLIGHT: $*"; fail=1; }

  # _dns_both <fqdn> <ip> — validate DNS resolves BOTH ways. Forward (A) and
  # reverse (PTR) are both required: the nested ESXi are added to the cluster by
  # FQDN and vSAN uses reverse DNS, and vcsa-deploy aborts without a matching PTR.
  _dns_both() {
    local fqdn="$1" ip="$2" fwd ptr
    fwd=$(dig @"${NATIVE_GW}" +short "$fqdn" 2>/dev/null || true)
    if [[ "$fwd" == *"$ip"* ]]; then
      ok "DNS forward: ${fqdn} -> ${ip}"
    else
      _pf "DNS forward: ${fqdn} does not resolve to ${ip} (got '${fwd:-<none>}')"
    fi
    # PTR of <ip> must equal <fqdn> (trailing dot stripped; tolerate multiple
    # PTR lines by matching the FQDN as a full line).
    ptr=$(dig @"${NATIVE_GW}" +short -x "$ip" 2>/dev/null || true)
    if printf '%s\n' "$ptr" | sed 's/\.$//' | grep -qxF "$fqdn"; then
      ok "DNS reverse: ${ip} -> ${fqdn}"
    else
      _pf "DNS reverse: ${ip} PTR does not resolve to ${fqdn} (got '$(printf '%s' "$ptr" | tr '\n' ' ' | sed 's/ *$//')'). A matching PTR record is required."
    fi
  }

  # ---- govc available ----
  require_govc

  # ---- Secrets set ----
  require_secret UNDERLYING_PASSWORD "underlying ESXi root password"
  require_secret VCSA_SSO_PASSWORD   "nested vCenter SSO administrator password"
  require_secret ESXI_ROOT_PASSWORD  "nested ESXi root password"
  govc_target underlying

  # ---- Stage 1 health: CA bundle exists ----
  if [[ -f "$CA_BUNDLE" ]]; then
    ok "Lab CA bundle present: ${CA_BUNDLE}"
  else
    _pf "Lab CA bundle missing: ${CA_BUNDLE}  (run Stage 1 first)"
  fi

  # ---- Stage 1 health: DNS resolves VCSA + nested ESXi both ways (A + PTR) ----
  local i
  for ((i=0; i<N_NESXI; i++)); do
    _dns_both "${NESXI_FQDN[$i]}" "${NESXI_IP[$i]}"
  done
  _dns_both "${VCSA_FQDN}" "${VCSA_IP}"

  # ---- Stage 1 health: registry reachable ----
  local reg_code
  reg_code=$(curl -sk -o /dev/null -w '%{http_code}' \
    --cacert "$CA_BUNDLE" "https://${REGISTRY_FQDN}/v2/" 2>/dev/null || true)
  if [[ "$reg_code" == "200" || "$reg_code" == "401" ]]; then
    ok "Registry ${REGISTRY_FQDN}/v2/ healthy (HTTP ${reg_code})"
  else
    _pf "Registry ${REGISTRY_FQDN}/v2/ unhealthy (HTTP ${reg_code})"
  fi

  # ---- Underlying ESXi: config sanity ----
  [[ -n "$UNDERLYING_HOST" ]]      || _pf "stage2.underlying.host is not set in input.yaml"
  [[ -n "$UNDERLYING_DATASTORE" ]] || _pf "stage2.underlying.datastore is not set in input.yaml"

  # Skip live-target checks if the host isn't configured (govc would hang/fail).
  if [[ -z "$UNDERLYING_HOST" ]]; then
    die "stage2.underlying.host is required. Fix input.yaml and re-run."
  fi

  # ---- Underlying target: connectivity via govc about ----
  # Gate on govc's exit code (it is 0 only on a successful connect + auth); use
  # the JSON name for display. Do NOT grep the text output — the field labels
  # vary by govc version (0.54 prints "Name:", not "Product name:").
  local about_json
  if about_json=$(govc about -k -json 2>/dev/null) && [[ -n "$about_json" ]]; then
    local prod; prod=$(printf '%s' "$about_json" \
      | jq -r '.about.fullName // .about.name // "connected"' 2>/dev/null || echo connected)
    ok "Underlying ${UNDERLYING_TYPE} reachable at ${UNDERLYING_HOST}: ${prod}"
  else
    _pf "Cannot reach underlying ${UNDERLYING_TYPE} at ${UNDERLYING_HOST} (check host, credentials, network)"
  fi

  # ---- Underlying (vCenter only): datacenter + cluster exist ----
  if [[ "$UNDERLYING_TYPE" == "vcenter" ]]; then
    govc_object_exists "/${UNDERLYING_DATACENTER}" \
      && ok "Datacenter '${UNDERLYING_DATACENTER}' found." \
      || _pf "Datacenter '${UNDERLYING_DATACENTER}' not found on the underlying vCenter."
    govc_object_exists "/${UNDERLYING_DATACENTER}/host/${UNDERLYING_CLUSTER}" \
      && ok "Cluster '${UNDERLYING_CLUSTER}' found." \
      || _pf "Cluster '${UNDERLYING_CLUSTER}' not found on the underlying vCenter."
  fi

  # ---- Underlying: datastore exists ----
  if govc datastore.info -k "${UNDERLYING_DATASTORE}" &>/dev/null; then
    ok "Datastore '${UNDERLYING_DATASTORE}' found on underlying target."
  else
    _pf "Datastore '${UNDERLYING_DATASTORE}' not found on underlying target."
  fi

  # ---- Underlying: trunk portgroup / network exists ----
  # A standard-vSwitch portgroup (ESXi) and a distributed portgroup (vCenter)
  # both appear in the inventory as network objects: 'n' (Network) or
  # 'g' (DistributedVirtualPortgroup). Look it up with govc find — avoids the
  # version-sensitive host.portgroup.info JSON shape.
  if govc find -k / -type n -name "${UNDERLYING_PG}" 2>/dev/null | grep -q . \
     || govc find -k / -type g -name "${UNDERLYING_PG}" 2>/dev/null | grep -q .; then
    ok "Network/portgroup '${UNDERLYING_PG}' found on the underlying target."
  else
    _pf "Network/portgroup '${UNDERLYING_PG}' not found on the underlying target. Create a VLAN-trunk portgroup first."
  fi

  # ---- Underlying ESXi: free disk space estimate ----
  # Each nested ESXi VM ≈ boot + ESA data disks (thin); VCSA ≈ 150 GB thin.
  local vcsa_gb total_gb
  vcsa_gb=150
  total_gb=$(( vcsa_gb + N_NESXI * ESXI_DISK_TOTAL_GB ))
  local free_gb
  free_gb=$(govc datastore.info -k -json "${UNDERLYING_DATASTORE}" 2>/dev/null \
    | jq -r '.datastores[0].summary.freeSpace // 0' \
    | awk '{printf "%d", $1/1073741824}' 2>/dev/null || echo 0)
  if (( free_gb >= total_gb )); then
    ok "Datastore free: ${free_gb} GB >= estimated ${total_gb} GB needed."
  else
    _pf "Datastore free: ${free_gb} GB < estimated ${total_gb} GB needed (${N_NESXI}x ESXi + VCSA thin)."
  fi

  # ---- Binaries present under artifacts.dir ----
  if [[ -f "$ESXI_OVA" ]]; then
    ok "Nested ESXi OVA found: ${ESXI_OVA}"
  else
    _pf "Nested ESXi OVA missing: ${ESXI_OVA}  (copy to artifacts.dir)"
  fi
  if [[ -f "$VCSA_ISO" ]]; then
    ok "VCSA installer ISO found: ${VCSA_ISO}"
  else
    _pf "VCSA installer ISO missing: ${VCSA_ISO}  (copy to artifacts.dir)"
  fi

  # ---- Nested ESXi count sanity ----
  if (( N_NESXI >= 3 )); then
    ok "Nested ESXi count: ${N_NESXI} (>= 3, satisfies vSAN FTT=${VSAN_FTT})"
  else
    _pf "Only ${N_NESXI} nested ESXi entries in dns.records (prefix='${ESXI_DNS_PREFIX}'). Need >= 3 for vSAN."
  fi

  # ---- Required tools ----
  # envsubst renders the vcsa-deploy + WCP JSON templates; mount attaches the
  # VCSA ISO so vcsa-deploy is available.
  local tool
  for tool in jq dig curl envsubst mount; do
    command -v "$tool" >/dev/null 2>&1 \
      && ok "Tool '${tool}' available." \
      || _pf "Tool '${tool}' not found."
  done

  (( fail == 0 )) || die "Preflight failed. Fix the issues above and re-run."
  ok "All Stage 2 preflight checks passed."
}
