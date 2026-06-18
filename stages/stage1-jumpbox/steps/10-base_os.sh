#!/usr/bin/env bash
# ============================================================================
# base_os :: packages, sysctl/perf tuning, kernel modules, hostname/hosts,
# chrony NTP client, optional proxy profile, data dirs. Mirrors roles/base_os.
# ============================================================================

step_base_os() {
  # ---- base packages ----
  pkg_refresh
  log "Installing base packages: ${BASE_PACKAGES[*]}"
  pkg_install "${BASE_PACKAGES[@]}"

  # ---- data dirs ----
  mkdir -p "$REGISTRY_DATA" "$ARTIFACTS_DIR" "$LAB_STATE_DIR"
  chmod 0750 "$LAB_STATE_DIR"

  # ---- kernel modules: load now + persist ----
  local m
  for m in 8021q br_netfilter nf_conntrack; do modprobe "$m" 2>/dev/null || warn "modprobe ${m} failed"; done
  write_file /etc/modules-load.d/nested-lab.conf 0644 <<'EOF'
8021q
br_netfilter
nf_conntrack
EOF

  # ---- sysctl tuning (verbatim from the Ansible template) ----
  write_file /etc/sysctl.d/99-nested-lab.conf 0644 <<'EOF'
# Managed by nested-vsphere-lab (base_os). Tuning for a nested-vSphere router.
# Routing
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 0

# Bridge/netfilter (needed for br_netfilter + nested traffic accounting)
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Relax rp_filter so asymmetric nested/VLAN routing is not dropped
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Connection tracking sized for many nested flows
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576

# Larger socket buffers / backlog for throughput on jumbo fabric
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1

# File descriptors / inotify (registry + many containers)
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152

# Memory behaviour suited to a host packing nested VMs
vm.swappiness = 10
vm.max_map_count = 262144
EOF
  if [[ "$FILE_CHANGED" == yes ]]; then sysctl --system >/dev/null; ok "applied sysctl"; fi

  # ---- hostname + /etc/hosts ----
  hostnamectl set-hostname "$JB_HOST" 2>/dev/null || { echo "$JB_HOST" >/etc/hostname; hostname "$JB_HOST" 2>/dev/null || true; }
  ensure_line /etc/hosts "${NATIVE_GW} ${JB_HOST}.${DOMAIN} ${JB_HOST}"

  # ---- optional upstream HTTP proxy profile ----
  local prof; prof=$(_proxy_render)
  if [[ -n "$prof" ]]; then
    write_file /etc/profile.d/nested-lab-proxy.sh 0644 <<<"$prof"
  else
    rm -f /etc/profile.d/nested-lab-proxy.sh
  fi

  # ---- chrony NTP client ----
  # NOTE: `write_file ... < <(fn)` (not `fn | write_file`) so FILE_CHANGED is set
  # in THIS shell, not a pipeline subshell -- otherwise the restart never fires.
  write_file "$NTP_CONF" 0644 < <(_chrony_render)
  svc_enable_now "$NTP_SERVICE"
  [[ "$FILE_CHANGED" == yes ]] && svc_restart "$NTP_SERVICE"
  ok "base_os tuning applied; NTP (${NTP_SERVICE}) active."
}

# ---- pure renders (testable) ----
_chrony_render() {
  local nn i s upstream=()
  nn=$(cfg_len '.ntp.upstream')
  if (( nn == 0 )); then upstream=(time.vmware.com); else
    for ((i=0; i<nn; i++)); do upstream+=("$(cfg ".ntp.upstream[$i]")"); done
  fi
  echo "# Managed by nested-vsphere-lab (base_os). Jumpbox is an NTP CLIENT only."
  for s in "${upstream[@]}"; do echo "server ${s} iburst"; done
  echo ""
  echo "driftfile /var/lib/chrony/drift"
  echo "makestep 1.0 3"
  echo "rtcsync"
  echo "logdir /var/log/chrony"
}

# echoes the proxy profile, or nothing when no proxy is configured
_proxy_render() {
  local p_http p_https p_no
  p_http=$(cfg '.proxy.http' ''); p_https=$(cfg '.proxy.https' '')
  p_no=$(cfg '.proxy.no_proxy' 'localhost,127.0.0.1')
  [[ -z "$p_http" && -z "$p_https" ]] && return 0
  echo "# Managed by nested-vsphere-lab (base_os). Upstream HTTP proxy."
  [[ -n "$p_http"  ]] && { echo "export http_proxy=\"${p_http}\"";  echo "export HTTP_PROXY=\"${p_http}\""; }
  [[ -n "$p_https" ]] && { echo "export https_proxy=\"${p_https}\""; echo "export HTTPS_PROXY=\"${p_https}\""; }
  echo "export no_proxy=\"${p_no}\""; echo "export NO_PROXY=\"${p_no}\""
}
