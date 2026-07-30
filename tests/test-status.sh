#!/bin/bash
# Tests for backend.sh status: a failing child query must fail the whole
# command — a swallowed error would read as "no tunnels up" (false drop
# toasts) or as an empty interface-name (import offers a duplicate).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
pass=0 fail=0

fresh() {
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
  printf 'U1:wireguard::pm\n' > "$FAKE_DIR/list"
  echo wg-pm > "$FAKE_DIR/ifname.U1"
}

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

fresh
out="$(bash "$backend" status 2>/dev/null)"; rc=$?
expect "happy path: three sections, ifname present" \
  '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | grep -cx -- ---)" = 2 ] && printf "%s\n" "$out" | grep -qx "U1:wg-pm"'

fresh
: > "$FAKE_DIR/fail-active"
bash "$backend" status >/dev/null 2>&1; rc=$?
expect "failing active listing fails status" '[ "$rc" != 0 ]'

fresh
rm "$FAKE_DIR/ifname.U1"
bash "$backend" status >/dev/null 2>&1; rc=$?
expect "failing interface-name query fails status" '[ "$rc" != 0 ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
