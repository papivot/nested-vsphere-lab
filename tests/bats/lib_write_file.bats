#!/usr/bin/env bats
# write_file :: idempotent change-detection (the core of conditional restarts).
# Regression guard: FILE_CHANGED must propagate to the caller's shell, which it
# does NOT when write_file runs in a pipeline subshell. Steps must use
# `write_file PATH MODE < <(render)`, never `render | write_file PATH MODE`.
load _helper

setup() { load_libs; TMP="$(mktemp -d)"; F="$TMP/f"; }
teardown() { rm -rf "$TMP"; }

@test "first write to a new file reports changed" {
  write_file "$F" 0644 < <(printf 'alpha\n')
  [ "$FILE_CHANGED" = "yes" ]
  [ "$(cat "$F")" = "alpha" ]
}

@test "rewriting identical content reports unchanged" {
  write_file "$F" 0644 < <(printf 'alpha\n')
  write_file "$F" 0644 < <(printf 'alpha\n')
  [ "$FILE_CHANGED" = "no" ]
}

@test "writing different content reports changed" {
  write_file "$F" 0644 < <(printf 'alpha\n')
  write_file "$F" 0644 < <(printf 'beta\n')
  [ "$FILE_CHANGED" = "yes" ]
  [ "$(cat "$F")" = "beta" ]
}

@test "mode is applied" {
  write_file "$F" 0600 < <(printf 'x\n')
  # GNU stat's `-f` is a *valid* flag (filesystem-status mode, not file-mode),
  # so trying `stat -f '%Lp'` first and falling back to `-c '%a'` on error
  # does NOT reliably detect GNU vs BSD stat -- `-f` doesn't cleanly fail on
  # GNU, it just returns something else. Detect the variant explicitly instead
  # (`--version` is GNU-only; BSD/macOS stat errors out on it).
  if stat --version >/dev/null 2>&1; then
    perm=$(stat -c '%a' "$F")   # GNU coreutils (Linux)
  else
    perm=$(stat -f '%Lp' "$F")  # BSD (macOS)
  fi
  [ "$perm" = "600" ]
}

@test "REGRESSION: pipeline form does NOT propagate FILE_CHANGED (so we forbid it)" {
  # demonstrates why steps must use `< <(fn)`: a pipe loses FILE_CHANGED.
  FILE_CHANGED=sentinel
  printf 'alpha\n' | write_file "$F" 0644
  [ "$FILE_CHANGED" = "sentinel" ]      # parent value untouched -> pipe is unsafe
  # the redirection form updates it correctly:
  write_file "$F" 0644 < <(printf 'gamma\n')
  [ "$FILE_CHANGED" = "yes" ]
}
