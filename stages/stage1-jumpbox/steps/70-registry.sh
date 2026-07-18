#!/usr/bin/env bash
# ============================================================================
# registry :: Docker + a CNCF Distribution (registry:2) OCI registry on :443,
# TLS from the lab CA. Optional htpasswd auth and an optional pull-through
# mirror. Replaces the Harbor role with a single, debuggable container.
# ============================================================================

REGISTRY_NAME=lab-registry
REGISTRY_MIRROR_NAME=lab-registry-mirror

# docker daemon config (testable): jumbo MTU on the default bridge
_daemon_json_render() {
  jq -n --argjson mtu "$MTU_PRIVATE" '{ mtu: $mtu }'
}

step_registry() {
  _docker_install

  # Docker daemon: jumbo MTU on the default bridge (the Ansible version missed this).
  # `< <(fn)` (not a pipe) so FILE_CHANGED is set in this shell, not a subshell.
  write_file /etc/docker/daemon.json 0644 < <(_daemon_json_render)
  local docker_changed="$FILE_CHANGED"
  svc_enable_now docker
  [[ "$docker_changed" == yes ]] && svc_restart docker

  # Trust the lab CA for docker pushes/pulls to our registry.
  mkdir -p "/etc/docker/certs.d/${REGISTRY_FQDN}"
  cp "$CA_BUNDLE" "/etc/docker/certs.d/${REGISTRY_FQDN}/ca.crt"

  mkdir -p "$REGISTRY_DATA"
  ensure_line /etc/hosts "${REGISTRY_ADDR} ${REGISTRY_FQDN}"

  local rimg; rimg=$(_img registry:2)
  log "Pulling ${rimg}"
  docker pull "$rimg" >/dev/null || die "could not pull ${rimg} (check egress/NAT or registry.image_mirror)."

  # ---- optional htpasswd auth ----
  local -a AUTH_ARGS=()
  if [[ "$REGISTRY_AUTH" == "true" ]]; then
    require_secret REGISTRY_ADMIN_PASSWORD "registry admin password"
    mkdir -p "${REGISTRY_DATA}/auth"
    # No 2>/dev/null: let docker's own error (pull failure, runtime error) show
    # before the die message, instead of hiding the reason behind a generic one.
    docker run --rm --entrypoint htpasswd "$(_img httpd:2)" -Bbn admin "$REGISTRY_ADMIN_PASSWORD" \
      > "${REGISTRY_DATA}/auth/htpasswd" || die "failed to generate htpasswd."
    AUTH_ARGS=(
      -v "${REGISTRY_DATA}/auth:/auth:ro"
      -e REGISTRY_AUTH=htpasswd
      -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm"
      -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
    )
  fi

  # ---- (re)create the registry container with TLS ----
  # Publish ONLY on the private VLAN IP (REGISTRY_ADDR) so the registry is not
  # exposed on the jumpbox public NIC / outside world.
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --restart=always --name "$REGISTRY_NAME" \
    -p "${REGISTRY_ADDR}:443:5000" \
    -v "${REGISTRY_DATA}:/var/lib/registry" \
    -v "${CERTS_DIR}/registry.crt:/certs/registry.crt:ro" \
    -v "${CERTS_DIR}/registry.key:/certs/registry.key:ro" \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
    "${AUTH_ARGS[@]}" \
    "$rimg" >/dev/null
  ok "registry bound to ${REGISTRY_ADDR}:443 (private VLAN only) -> https://${REGISTRY_FQDN}/ (auth=${REGISTRY_AUTH})."

  # ---- optional pull-through mirror ----
  local pt_url pt_port
  pt_url=$(cfg '.registry.pull_through.url' '')
  if [[ -n "$pt_url" ]]; then
    pt_port=$(cfg '.registry.pull_through.port' '5443')
    docker rm -f "$REGISTRY_MIRROR_NAME" >/dev/null 2>&1 || true
    mkdir -p "${REGISTRY_DATA}-mirror"
    docker run -d --restart=always --name "$REGISTRY_MIRROR_NAME" \
      -p "${REGISTRY_ADDR}:${pt_port}:5000" \
      -v "${REGISTRY_DATA}-mirror:/var/lib/registry" \
      -v "${CERTS_DIR}/registry.crt:/certs/registry.crt:ro" \
      -v "${CERTS_DIR}/registry.key:/certs/registry.key:ro" \
      -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
      -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
      -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
      -e "REGISTRY_PROXY_REMOTEURL=${pt_url}" \
      "$rimg" >/dev/null
    ok "pull-through mirror of ${pt_url} on :${pt_port}."
  fi

  # ---- health wait ----
  local i code
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_BUNDLE" "https://${REGISTRY_FQDN}/v2/" || true)
    [[ "$code" == "200" || "$code" == "401" ]] && { ok "registry health OK (HTTP ${code})."; return 0; }
    sleep 2
  done
  die "registry did not become healthy at https://${REGISTRY_FQDN}/v2/ (last HTTP ${code:-none})."
}

_docker_install() {
  if command -v docker >/dev/null 2>&1; then dbg "docker already installed"; return 0; fi
  case "$OS_FAMILY" in
    debian) pkg_install docker.io ;;
    photon) pkg_install docker ;;
    redhat)
      curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
      pkg_install docker-ce docker-ce-cli containerd.io
      ;;
  esac
}
