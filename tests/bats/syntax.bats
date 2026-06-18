#!/usr/bin/env bats
# Syntax checks for every shell script. Run: bats tests/bats/syntax.bats
# With shellcheck installed it also lints; otherwise it falls back to `bash -n`.

ROOT="${BATS_TEST_DIRNAME}/../.."

_scripts() {
  find "${ROOT}" -name '*.sh' -not -path '*/.git/*'
}

@test "bash -n parses every .sh file" {
  local f rc=0
  while IFS= read -r f; do
    if ! bash -n "$f"; then echo "parse error: $f"; rc=1; fi
  done < <(_scripts)
  [ "$rc" -eq 0 ]
}

@test "shellcheck passes (if installed)" {
  if ! command -v shellcheck >/dev/null 2>&1; then skip "shellcheck not installed"; fi
  local f rc=0
  while IFS= read -r f; do
    # SC1090/SC1091: dynamic `source`; SC2034: vars consumed across sourced files.
    if ! shellcheck -e SC1090,SC1091,SC2034 -x "$f"; then rc=1; fi
  done < <(_scripts)
  [ "$rc" -eq 0 ]
}
