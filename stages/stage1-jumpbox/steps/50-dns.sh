#!/usr/bin/env bash
# ============================================================================
# dns :: BIND9 with a forward zone for the lab domain + one reverse zone per
# VLAN /24. Recursion/queries limited to the private subnets; forwards out.
# Debian uses the split include layout; RHEL/Photon use a single named.conf.
# Mirrors roles/dns_bind.
# ============================================================================

step_dns() {
  pkg_install "${BIND_PACKAGES[@]}"
  mkdir -p "$ZONES_DIR"
  chown "${BIND_USER}:${BIND_GROUP}" "$ZONES_DIR" 2>/dev/null || true
  chmod 0750 "$ZONES_DIR"
  if [[ "$OS_FAMILY" != debian ]]; then
    mkdir -p /run/named; chown "${BIND_USER}:${BIND_GROUP}" /run/named 2>/dev/null || true
  fi

  local serial; serial="$(date +%Y%m%d)01"
  local changed=0

  # NOTE: `write_file ... < <(fn)` keeps FILE_CHANGED in THIS shell (a pipeline
  # would set it in a subshell and we'd never restart named on a change).

  # ---- forward zone ----
  write_file "${ZONES_DIR}/db.forward" 0644 < <(_dns_forward "$serial")
  [[ "$FILE_CHANGED" == yes ]] && changed=1
  chown "${BIND_USER}:${BIND_GROUP}" "${ZONES_DIR}/db.forward" 2>/dev/null || true
  named-checkzone "$DOMAIN" "${ZONES_DIR}/db.forward" >/dev/null || die "forward zone failed named-checkzone."

  # ---- reverse zones (one per VLAN) ----
  local i f
  for ((i=0; i<N_VLANS; i++)); do
    f="${ZONES_DIR}/db.${V_NAME[i]}.rev"
    write_file "$f" 0644 < <(_dns_reverse "$i" "$serial")
    [[ "$FILE_CHANGED" == yes ]] && changed=1
    chown "${BIND_USER}:${BIND_GROUP}" "$f" 2>/dev/null || true
    named-checkzone "${V_REVZONE[i]}" "$f" >/dev/null || die "reverse zone ${V_REVZONE[i]} failed named-checkzone."
  done

  # ---- named config ----
  if [[ "$BIND_LAYOUT" == "include" ]]; then
    write_file "$NAMED_OPTIONS" 0644 < <(_dns_options); [[ "$FILE_CHANGED" == yes ]] && changed=1
    write_file "$NAMED_LOCAL"   0644 < <(_dns_zones);   [[ "$FILE_CHANGED" == yes ]] && changed=1
  else
    write_file "$NAMED_CONF" 0640 < <( _dns_options; echo ""; _dns_zones ); [[ "$FILE_CHANGED" == yes ]] && changed=1
    chown "root:${BIND_GROUP}" "$NAMED_CONF" 2>/dev/null || true
  fi
  named-checkconf >/dev/null || die "named configuration failed named-checkconf."

  svc_enable_now "$BIND_SERVICE"
  (( changed )) && svc_restart "$BIND_SERVICE"

  # Point the jumpbox's own resolver at BIND for lab names.
  _configure_jumpbox_resolver

  ok "BIND active: forward '${DOMAIN}' + ${N_VLANS} reverse zone(s)."
}

# _resolved_dropin (PURE) — systemd-resolved drop-in that routes the lab domain
# (as search + route) and each reverse zone to the local BIND, while leaving
# external DNS on the existing upstream link. Testable in isolation.
_resolved_dropin() {
  local i doms="${DOMAIN}"
  for ((i=0; i<N_VLANS; i++)); do doms="${doms} ~${V_REVZONE[i]}"; done
  cat <<EOF
# Managed by nested-vsphere-lab (dns): resolve lab names via the local BIND.
[Resolve]
DNS=${NATIVE_GW}
Domains=${doms}
EOF
}

# Repoint the jumpbox's own resolver at BIND so tools ON the jumpbox — and SSH
# -D SOCKS remote DNS — resolve *.${DOMAIN} and the reverse zones. Without this,
# systemd-resolved sends lab queries to the upstream (which has no lab records),
# so `getent hosts vcsa.<domain>` (the path sshd uses) fails even though BIND is
# healthy. Opt out with dns.use_local_resolver: false.
_configure_jumpbox_resolver() {
  [[ "$(cfg_bool '.dns.use_local_resolver' 'true')" == "true" ]] || {
    log "dns.use_local_resolver=false; leaving the jumpbox resolver unchanged."
    return
  }

  if svc_is_active systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    write_file /etc/systemd/resolved.conf.d/nested-lab.conf 0644 < <(_resolved_dropin)
    [[ "$FILE_CHANGED" == yes ]] && svc_restart systemd-resolved
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null || true
    ok "Jumpbox resolver: lab names -> BIND (${NATIVE_GW}) via systemd-resolved."
  elif [[ ! -L /etc/resolv.conf ]]; then
    # Classic /etc/resolv.conf: make BIND the primary resolver + search domain.
    ensure_line /etc/resolv.conf "search ${DOMAIN}"
    grep -qxF "nameserver ${NATIVE_GW}" /etc/resolv.conf \
      || sed -i "1i nameserver ${NATIVE_GW}" /etc/resolv.conf
    ok "Jumpbox resolver: BIND (${NATIVE_GW}) via /etc/resolv.conf."
  else
    warn "Skipped jumpbox resolver repoint: /etc/resolv.conf is a managed symlink and systemd-resolved is not active. If this host uses NetworkManager, run: nmcli con mod <mgmt-con> ipv4.dns ${NATIVE_GW} ipv4.dns-search ${DOMAIN} && nmcli con up <mgmt-con>"
  fi
}

_dns_forward() {
  local serial="$1" i
  cat <<EOF
; Managed by nested-vsphere-lab (dns). Forward zone for ${DOMAIN}.
\$TTL 3600
@   IN  SOA ${JB_HOST}.${DOMAIN}. admin.${DOMAIN}. (
            ${serial} ; serial
            3600       ; refresh
            600        ; retry
            604800     ; expire
            3600 )     ; minimum
@           IN  NS  ${JB_HOST}.${DOMAIN}.
${JB_HOST}  IN  A   ${NATIVE_GW}
; VLAN gateway interfaces owned by the jumpbox
EOF
  for ((i=0; i<N_VLANS; i++)); do printf 'gw-%-16s IN  A   %s\n' "${V_NAME[i]}" "${V_GW[i]}"; done
  echo "; Pre-created records for nested nodes (Stage 2)"
  local nr; nr=$(cfg_len '.dns.records')
  for ((i=0; i<nr; i++)); do
    printf '%-19s IN  A   %s\n' "$(cfg ".dns.records[$i].name")" "$(cfg ".dns.records[$i].ip")"
  done
}

_dns_reverse() {
  local idx="$1" serial="$2" i nr
  cat <<EOF
; Managed by nested-vsphere-lab (dns). Reverse zone for ${V_CIDR[idx]}.
\$TTL 3600
@   IN  SOA ${JB_HOST}.${DOMAIN}. admin.${DOMAIN}. (
            ${serial} 3600 600 604800 3600 )
@           IN  NS  ${JB_HOST}.${DOMAIN}.
$(last_octet "${V_GW[idx]}")    IN  PTR  gw-${V_NAME[idx]}.${DOMAIN}.
EOF
  nr=$(cfg_len '.dns.records')
  for ((i=0; i<nr; i++)); do
    local rip rname; rip=$(cfg ".dns.records[$i].ip"); rname=$(cfg ".dns.records[$i].name")
    if ip_in_cidr "$rip" "${V_CIDR[idx]}"; then
      printf '%s    IN  PTR  %s.%s.\n' "$(last_octet "$rip")" "$rname" "$DOMAIN"
    fi
  done
}

_dns_options() {
  local i nf
  echo "options {"
  echo "    directory \"${NAMED_CACHE_DIR}\";"
  echo "    forwarders {"
  nf=$(cfg_len '.dns.forwarders')
  if (( nf == 0 )); then echo "        8.8.8.8; 1.1.1.1;"
  else for ((i=0; i<nf; i++)); do echo "        $(cfg ".dns.forwarders[$i]");"; done; fi
  echo "    };"
  echo "    forward only;"
  echo "    dnssec-validation no;"
  echo "    version none;"
  echo "    listen-on-v6 { none; };"
  printf '    listen-on { 127.0.0.1;'
  for ((i=0; i<N_VLANS; i++)); do printf ' %s;' "${V_GW[i]}"; done; echo " };"
  printf '    allow-query { localhost;'
  for ((i=0; i<N_VLANS; i++)); do printf ' %s;' "${V_CIDR[i]}"; done; echo " };"
  echo "    allow-query-cache { any; };"
  echo "    recursion yes;"
  printf '    allow-recursion { 127.0.0.1;'
  for ((i=0; i<N_VLANS; i++)); do printf ' %s;' "${V_CIDR[i]}"; done; echo " };"
  [[ "$OS_FAMILY" != debian ]] && echo "    pid-file \"/run/named/named.pid\";"
  echo "};"
}

_dns_zones() {
  local i
  echo "zone \"${DOMAIN}\" { type master; file \"${ZONES_DIR}/db.forward\"; };"
  for ((i=0; i<N_VLANS; i++)); do
    echo "zone \"${V_REVZONE[i]}\" { type master; file \"${ZONES_DIR}/db.${V_NAME[i]}.rev\"; };"
  done
}
