#!/usr/bin/env bash
# ============================================================================
# preflight :: hard validation gate. Read-only. Fails fast with actionable
# messages so a stage never breaks half-way. Mirrors roles/preflight.
# ============================================================================

step_preflight() {
  local fail=0
  _pf() { err "PREFLIGHT: $*"; fail=1; }

  # ---- OS ----
  case "$OS_FAMILY" in
    debian|redhat|photon) ok "OS ${OS_PRETTY} is supported (${OS_FAMILY})." ;;
    *) _pf "Unsupported OS family. Need Ubuntu/Debian, RHEL-like, or Photon." ;;
  esac

  # ---- NICs ----
  if [[ -e "/sys/class/net/${PRIVATE_NIC}" && -e "/sys/class/net/${PRIVATE_NIC}/device" ]]; then
    ok "Private NIC '${PRIVATE_NIC}' present and physical."
  else
    _pf "Private NIC '${PRIVATE_NIC}' missing or not physical (no /sys/class/net/${PRIVATE_NIC}/device)."
  fi
  [[ -e "/sys/class/net/${PUBLIC_NIC}" ]] && ok "Public NIC '${PUBLIC_NIC}' present." \
    || _pf "Public/egress NIC '${PUBLIC_NIC}' not found."
  [[ "$PRIVATE_NIC" != "$PUBLIC_NIC" ]] || _pf "private_nic and public_nic must differ."

  # ---- Disk (>= MIN_DISK_GB on /) ----
  local avail_kb avail_gb
  avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if (( avail_gb >= MIN_DISK_GB )); then
    ok "${avail_gb} GB free on '/' (>= ${MIN_DISK_GB} GB)."
  else
    _pf "Only ${avail_gb} GB free on '/'; need >= ${MIN_DISK_GB} GB (registry images + OVAs/ISOs)."
  fi

  # ---- Kernel modules ----
  local m
  for m in 8021q br_netfilter; do
    if modinfo "$m" >/dev/null 2>&1 || [[ -d "/sys/module/$m" ]]; then
      ok "Kernel module '${m}' available."
    else
      _pf "Kernel module '${m}' not available; install the matching kernel-modules package."
    fi
  done

  # ---- Network model (pure validation; see _pf_model_errors) ----
  local merr had=0
  while IFS= read -r merr; do [[ -n "$merr" ]] || continue; _pf "$merr"; had=1; done < <(_pf_model_errors)
  [[ $had -eq 0 ]] && ok "VLAN model valid: ${N_VLANS} /24(s) inside ${SUPERNET}."

  # ---- Secrets (registry admin password only required when auth enabled) ----
  if [[ "$REGISTRY_AUTH" == "true" ]]; then
    local forbidden=("" "VMware1!" "Passw0rd!" "ChangeMe" "ChangeMe-Strong-Passw0rd!" "password" "changeme")
    require_secret REGISTRY_ADMIN_PASSWORD "registry admin password"
    local p="${REGISTRY_ADMIN_PASSWORD:-}" bad=0 f
    for f in "${forbidden[@]}"; do [[ "$p" == "$f" ]] && bad=1; done
    if (( bad )) || (( ${#p} < 8 )); then
      _pf "REGISTRY_ADMIN_PASSWORD is missing, too short (<8), or a known default. Set a strong value in secrets.env."
    else
      ok "Registry admin password is set and non-default."
    fi
  fi

  # ---- BYO CA sanity ----
  if [[ "$CA_MODE" == "byo" ]]; then
    local bc bk
    bc=$(cfg '.certs.byo.cert' ''); bk=$(cfg '.certs.byo.key' '')
    [[ -n "$bc" && -n "$bk" ]] || _pf "ca_mode=byo but certs.byo.cert / certs.byo.key are not set."
    [[ -n "$bc" && -f "$bc" ]] || _pf "BYO CA cert file not found: ${bc}"
    [[ -n "$bk" && -f "$bk" ]] || _pf "BYO CA key file not found: ${bk}"
  fi

  # ---- Best-effort: DNS forwarders reachable on tcp/53 (warn only) ----
  local nf i2 fwd
  nf=$(cfg_len '.dns.forwarders')
  for ((i2=0; i2<nf; i2++)); do
    fwd=$(cfg ".dns.forwarders[$i2]")
    if timeout 4 bash -c "exec 3<>/dev/tcp/${fwd}/53" 2>/dev/null; then
      dbg "forwarder ${fwd} reachable on tcp/53"
    else
      warn "DNS forwarder ${fwd} not reachable on tcp/53 (continuing)."
    fi
  done

  # ---- Physical vSphere portgroup reminder (cannot enforce from the guest) ----
  warn "ACTION REQUIRED on the PHYSICAL vSphere side (cannot be checked from inside this VM):"
  warn "  - Portgroup backing '${PRIVATE_NIC}' must be a VLAN trunk (VLAN ID 4095)."
  warn "  - Promiscuous mode = Accept, Forged transmits = Accept, MAC changes = Accept."
  warn "  - vSwitch/portgroup MTU must allow ${MTU_PRIVATE} (jumbo)."

  [[ $fail -eq 0 ]] || die "Preflight FAILED (${fail} blocking issue(s) above). Fix and re-run."
  ok "Preflight PASSED."
}

# Pure network-model validation: echoes one line per problem (none = valid).
# Uses N_VLANS, V_ID, V_CIDR, V_PREFIX, NATIVE_VLAN, SUPERNET. No host access.
_pf_model_errors() {
  local i ids=() cidrs=()
  for ((i=0; i<N_VLANS; i++)); do ids+=("${V_ID[i]}"); cidrs+=("$(cidr_network "${V_CIDR[i]}")"); done
  printf '%s\n' "${ids[@]}" | grep -qxF "$NATIVE_VLAN" || echo "native_vlan ${NATIVE_VLAN} is not among the defined VLANs."
  [[ "$(printf '%s\n' "${ids[@]}" | sort | uniq -d)" == "" ]] || echo "Duplicate VLAN IDs detected."
  [[ "$(printf '%s\n' "${cidrs[@]}" | sort | uniq -d)" == "" ]] || echo "Overlapping/duplicate VLAN subnets detected."
  for ((i=0; i<N_VLANS; i++)); do
    if [[ "${V_PREFIX[i]}" != "24" ]]; then
      echo "VLAN ${V_ID[i]} (${V_CIDR[i]}) must be a /24."
    elif ! cidr_contains "$SUPERNET" "${V_CIDR[i]}"; then
      echo "VLAN ${V_ID[i]} (${V_CIDR[i]}) is not inside supernet ${SUPERNET}."
    fi
  done
}
