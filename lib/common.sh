#!/usr/bin/env bash
# ============================================================================
# lib/common.sh - logging, state/checkpoints, step framework, secrets, file I/O
# Sourced by run.sh and every stage. Assumes `set -Eeuo pipefail` + ERR trap
# are installed by the caller (run.sh).
# ============================================================================

# ---- pretty logging (colours only on a tty) ----
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=
fi

_ts() { date +%H:%M:%S; }
log()  { printf '%s[%s]%s %s\n' "$C_B" "$(_ts)" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
dbg()  { [[ -n "${VERBOSE:-}" ]] && printf '%s      %s%s\n' "$C_D" "$*" "$C_0" || true; }

# die prints a resume hint for the step currently executing.
die() {
  err "$*"
  if [[ -n "${CURRENT_STEP:-}" ]]; then
    err "Resume after fixing: ./run.sh --stage ${STAGE:-1} --from-step ${CURRENT_STEP}"
  fi
  exit 1
}

# ERR trap target - installed by run.sh. Surfaces the failing command + step.
on_err() {
  local rc=$? cmd=${BASH_COMMAND:-?}
  err "command failed (rc=${rc}): ${cmd}"
  if [[ -n "${CURRENT_STEP:-}" ]]; then
    err "Step '${CURRENT_STEP}' did not complete. Re-run: ./run.sh --stage ${STAGE:-1} --from-step ${CURRENT_STEP}"
  fi
  exit "$rc"
}

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This must run as root (use sudo)."; }

# ---- state / checkpoints (the master status file) ----
# One completed step name per line. is_done lets a re-run skip finished work;
# every step is ALSO internally idempotent so --force / --from-step re-run safely.
: "${STATE_FILE:=state/stage1.state}"
is_done()   { [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE"; }
mark_done() {
  mkdir -p "$(dirname "$STATE_FILE")"
  grep -qxF "$1" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$1" >>"$STATE_FILE"
}
unmark() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -vxF "$1" "$STATE_FILE" >"${STATE_FILE}.tmp" 2>/dev/null || : >"${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# run_step <name> <function>  - the single chokepoint for every step.
run_step() {
  local name="$1" fn="$2"
  if is_done "$name" && [[ -z "${FORCE:-}" ]]; then
    ok "step '${name}' already complete (skip; --from-step ${name} to redo)"
    return 0
  fi
  CURRENT_STEP="$name"
  printf '\n%s========== step: %s ==========%s\n' "$C_B" "$name" "$C_0"
  "$fn"
  mark_done "$name"
  ok "step '${name}' complete"
  CURRENT_STEP=""
}

# ---- secrets: gitignored secrets.env, with interactive no-echo fallback ----
load_secrets() {
  local f="${SECRETS_FILE:-secrets.env}"
  if [[ -f "$f" ]]; then
    set -a; # shellcheck disable=SC1090
    . "$f"; set +a
    log "Loaded secrets from ${f}"
  fi
}
# require_secret VARNAME "Human label"
require_secret() {
  local var="$1" label="$2"
  if [[ -z "${!var:-}" ]]; then
    if [[ -t 0 ]]; then
      local v=""
      read -rsp "Enter ${label}: " v; echo
      printf -v "$var" '%s' "$v"
      export "${var?}"
    else
      die "${var} is not set. Provide it in secrets.env or run interactively."
    fi
  fi
}

# ---- idempotent file write ----
# write_file <path> <mode>   (content on stdin)
# Sets global FILE_CHANGED=yes|no so callers can conditionally reload services:
#     write_file /etc/foo 0644 <<EOF ... EOF
#     [[ $FILE_CHANGED == yes ]] && svc_restart foo
FILE_CHANGED=no
write_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp=$(mktemp)
  cat >"$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    FILE_CHANGED=no
    dbg "unchanged: ${path}"
  else
    cat "$tmp" >"$path"
    FILE_CHANGED=yes
    log "wrote ${path}"
  fi
  rm -f "$tmp"
  chmod "$mode" "$path"
}

# ensure_line <file> <exact-line>  (idempotent append; create file if needed)
ensure_line() {
  local file="$1" line="$2"
  touch "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

# is_ipv4 <string>  - 0 if a dotted IPv4 literal
is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=. o; read -r -a o <<<"$1"
  local n; for n in "${o[@]}"; do (( n <= 255 )) || return 1; done
}

# _img <official-image>  - resolve a Docker Hub official image through the
# configured mirror (IMAGE_MIRROR, e.g. mirror.gcr.io/library) to avoid Docker
# Hub rate limits. Empty IMAGE_MIRROR -> use the bare name (Docker Hub direct).
_img() {
  local m="${IMAGE_MIRROR:-}"
  if [[ -n "$m" ]]; then printf '%s/%s' "${m%/}" "$1"; else printf '%s' "$1"; fi
}
