#!/usr/bin/env bash
# Rollback for registry: remove containers + /etc/hosts entry. Data dir preserved.
rollback_registry() {
  docker rm -f "$REGISTRY_NAME" "$REGISTRY_MIRROR_NAME" >/dev/null 2>&1 || true
  rm -rf "/etc/docker/certs.d/${REGISTRY_FQDN}"
  sed -i "\|[[:space:]]${REGISTRY_FQDN}\$|d" /etc/hosts 2>/dev/null || true
  ok "Removed registry containers (data dir ${REGISTRY_DATA} preserved)."
}
