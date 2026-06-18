#!/usr/bin/env bash
# ============================================================================
# certs :: self-signed root CA (or BYO), optional intermediate, leaf cert for
# the registry, OS trust install, key lock-down + backup. Pure openssl.
# Mirrors roles/certs. The CA bundle is trusted end-to-end and handed to Stage 2.
#
# _certs_pki() does only the key/cert generation in a target dir (testable);
# step_certs() adds OS trust install, key lockdown, backup, fingerprint.
# ============================================================================

# subjectAltName string for the registry leaf (testable)
_leaf_san() { printf 'DNS:%s,IP:%s' "$REGISTRY_FQDN" "$HARBOR_IP"; }

# Generate CA (+ optional intermediate) + CA bundle + registry leaf into $1.
# No trust-store changes, no chown root, no backup -- pure crypto + files.
_certs_pki() {
  local dir="$1"
  local ca_key="${dir}/root-ca.key" ca_crt="${dir}/root-ca.crt"
  local int_key="${dir}/intermediate-ca.key" int_crt="${dir}/intermediate-ca.crt"
  local org cn country intermediate
  org=$(cfg '.certs.subject.org' 'CustomerLab')
  cn=$(cfg '.certs.subject.cn' 'Nested Lab Root CA')
  country=$(cfg '.certs.subject.country' 'US')
  intermediate=$(cfg_bool '.certs.intermediate' 'false')

  mkdir -p "$dir"; chmod 0700 "$dir"

  local -a GENPASS=() CAPASS=()
  if [[ -n "${CA_KEY_PASSPHRASE:-}" ]]; then
    GENPASS=(-aes256 -passout "pass:${CA_KEY_PASSPHRASE}")
    CAPASS=(-passin "pass:${CA_KEY_PASSPHRASE}")
  fi

  if [[ "$CA_MODE" == "byo" ]]; then
    local bc bk; bc=$(cfg '.certs.byo.cert'); bk=$(cfg '.certs.byo.key')
    [[ -f "$ca_crt" ]] || { install -m0644 "$bc" "$ca_crt"; log "installed BYO CA cert"; }
    [[ -f "$ca_key" ]] || { install -m0600 "$bk" "$ca_key"; log "installed BYO CA key"; }
  else
    if [[ ! -f "$ca_key" ]]; then
      openssl genrsa "${GENPASS[@]}" -out "$ca_key" 4096; chmod 0600 "$ca_key"; log "generated root CA key"
    fi
    if [[ ! -f "$ca_crt" ]]; then
      openssl req -x509 -new -key "$ca_key" "${CAPASS[@]}" -sha256 -days 3650 \
        -subj "/C=${country}/O=${org}/CN=${cn}" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$ca_crt"
      chmod 0644 "$ca_crt"; log "self-signed root CA cert"
    fi
  fi

  # optional intermediate
  local sign_crt="$ca_crt" sign_key="$ca_key"; local -a SIGNPASS=("${CAPASS[@]}")
  if [[ "$intermediate" == "true" ]]; then
    [[ -f "$int_key" ]] || { openssl genrsa -out "$int_key" 4096; chmod 0600 "$int_key"; }
    if [[ ! -f "$int_crt" ]]; then
      openssl req -new -key "$int_key" -subj "/O=${org}/CN=${cn} Intermediate" -out "${dir}/intermediate-ca.csr"
      openssl x509 -req -in "${dir}/intermediate-ca.csr" -CA "$ca_crt" -CAkey "$ca_key" "${CAPASS[@]}" \
        -CAcreateserial -days 1825 -sha256 \
        -extfile <(printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n') \
        -out "$int_crt"
      chmod 0644 "$int_crt"; log "signed intermediate CA"
    fi
    sign_crt="$int_crt"; sign_key="$int_key"; SIGNPASS=()
  fi

  # CA bundle
  write_file "$CA_BUNDLE" 0644 < <( cat "$ca_crt"; [[ -f "$int_crt" ]] && cat "$int_crt" )

  # registry leaf
  local lk="${dir}/registry.key" lc="${dir}/registry.crt" lcsr="${dir}/registry.csr" san
  san=$(_leaf_san)
  if [[ ! -f "$lk" ]]; then openssl genrsa -out "$lk" 2048; chmod 0640 "$lk"; fi
  if [[ ! -f "$lc" ]]; then
    openssl req -new -key "$lk" -subj "/O=${org}/CN=${REGISTRY_FQDN}" -addext "subjectAltName=${san}" -out "$lcsr"
    openssl x509 -req -in "$lcsr" -CA "$sign_crt" -CAkey "$sign_key" "${SIGNPASS[@]}" \
      -CAcreateserial -days 825 -sha256 \
      -extfile <(printf 'subjectAltName=%s\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san") \
      -out "$lc"
    chmod 0644 "$lc"; log "issued registry leaf cert (${REGISTRY_FQDN})"
  fi
}

step_certs() {
  local dir="$CERTS_DIR" backup ca_key="${CERTS_DIR}/root-ca.key" ca_crt="${CERTS_DIR}/root-ca.crt"
  backup=$(cfg '.certs.backup_path' '/root/lab-ca-backup')
  chown root:root "$dir" 2>/dev/null || true

  _certs_pki "$dir"

  # ---- install CA into the OS trust store ----
  cp "$CA_BUNDLE" "${CA_TRUST_DIR}/nested-lab-ca.crt"; chmod 0644 "${CA_TRUST_DIR}/nested-lab-ca.crt"
  "$CA_TRUST_UPDATE" >/dev/null 2>&1 || "$CA_TRUST_UPDATE"
  ok "CA bundle installed into OS trust anchors."

  # ---- lock down + back up the CA key ----
  chmod 0600 "$ca_key"; chown root:root "$ca_key" 2>/dev/null || true
  mkdir -p "$backup"; chmod 0700 "$backup"; chown root:root "$backup" 2>/dev/null || true
  install -m0600 "$ca_key" "${backup}/"
  install -m0600 "$ca_crt" "${backup}/"

  openssl x509 -in "$ca_crt" -noout -fingerprint -sha256 > "${LAB_STATE_DIR}/ca-fingerprint.txt"
  ok "certs complete. CA: ${CA_BUNDLE}  fingerprint: $(cat "${LAB_STATE_DIR}/ca-fingerprint.txt")"
}
