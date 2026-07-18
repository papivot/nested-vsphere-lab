#!/usr/bin/env bash
# ============================================================================
# lib/yaml.sh - thin wrappers over `yq` (mikefarah v4) for the single input.yaml.
# Lists are read by index (cfg_len + cfg ".path[$i].field") so we never depend
# on fragile multi-line splitting.
# ============================================================================

: "${INPUT_FILE:?INPUT_FILE must be set before sourcing lib/yaml.sh}"

require_yq() {
  command -v yq >/dev/null 2>&1 || die "yq not found. Run ./bootstrap.sh first."
  # mikefarah yq understands `eval`; the python yq does not.
  if ! yq --version 2>/dev/null | grep -qiE 'mikefarah|version v?4'; then
    warn "yq present but may not be the mikefarah build; YAML reads could differ."
  fi
  # cfg()/cfg_len() below fall back to their default on ANY yq failure (not
  # just a missing key), so a malformed input.yaml would otherwise silently
  # deploy 100% default values with no warning. Catch that here, once, up
  # front -- NOT inside cfg() itself, which is called as `x=$(cfg ...)`
  # throughout; a `die` there would only exit that subshell, not the script.
  local yq_err
  yq_err=$(yq eval '.' "$INPUT_FILE" 2>&1 1>/dev/null) \
    || die "input.yaml is not valid YAML (yq: ${yq_err}). Fix it, or copy a fresh input.example.yaml, and re-run."
}

# cfg <yq-expression> [default]  -> value, or default if null/missing/empty
cfg() {
  local expr="$1" def="${2-}" val
  val=$(yq "$expr" "$INPUT_FILE" 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}

# cfg_len <list-expression>  -> element count (0 if missing)
cfg_len() {
  local n
  n=$(yq "(${1} // []) | length" "$INPUT_FILE" 2>/dev/null || true)
  [[ -z "$n" || "$n" == "null" ]] && n=0
  printf '%s' "$n"
}

# cfg_bool <expr> [default]  -> "true"/"false" (normalised)
cfg_bool() {
  local v lc
  v=$(cfg "$1" "${2:-false}")
  lc=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$lc" in true|yes|1) printf 'true' ;; *) printf 'false' ;; esac
}
