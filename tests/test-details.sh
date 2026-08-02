#!/bin/bash
# Tests for backend.sh details: the read-only query behind the panel's
# connection grid. It runs on a timer while the panel is open, so the two
# things that matter are that it never asks nmcli for secrets and that a
# missing profile fails loudly instead of printing a grid of blanks.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
pass=0 fail=0

fresh() {
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
  # As nmcli -t prints it: colons inside a value arrive escaped.
  cat > "$FAKE_DIR/props.U1" <<'EOF'
connection.type:wireguard
connection.interface-name:pm
ipv4.addresses:10.8.0.13/32
ipv4.dns:8.8.8.8,1.1.1.1
wireguard.mtu:0
wireguard.peers:6o/y01yXuoHtXhyixJTPXwho0gWdaD/R07B4D3d6SH4= allowed-ips=0.0.0.0/0;192.0.2.0/24 endpoint=185.55.56.151\:51820 persistent-keepalive=25
EOF
}

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
  rm -rf "$FAKE_DIR"
}

field() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

fresh
out="$(bash "$backend" details U1 2>/dev/null)"; rc=$?
expect "happy path: address, endpoint, routes, dns, peer count" \
  '[ "$rc" = 0 ] && [ "$(field ip)" = "10.8.0.13/32" ] \
    && [ "$(field endpoint)" = "185.55.56.151:51820" ] \
    && [ "$(field allowed)" = "0.0.0.0/0, 192.0.2.0/24" ] \
    && [ "$(field dns)" = "8.8.8.8, 1.1.1.1" ] \
    && [ "$(field peers)" = "1" ]'

fresh
out="$(bash "$backend" details U1 2>/dev/null)"
expect "every key is printed even when the profile has no value for it" \
  '[ "$(printf "%s\n" "$out" | wc -l)" = 7 ] && [ "$(field mtu)" = "" ] && [ "$(field ip6)" = "" ]'

fresh
bash "$backend" details U1 >/dev/null 2>&1
expect "never asks nmcli for secrets" '! grep -q -- " -s " "$FAKE_DIR/log"'

fresh
bash "$backend" details U9 >/dev/null 2>&1; rc=$?
expect "unknown profile fails instead of printing blanks" '[ "$rc" != 0 ]'

fresh
# Two peers: the grid describes the first, the count flags the rest.
cat > "$FAKE_DIR/props.U1" <<'EOF'
wireguard.peers:AAAA= allowed-ips=192.0.2.0/24 endpoint=203.0.113.7\:1234, BBBB= allowed-ips=198.51.100.0/24 endpoint=203.0.113.8\:1234
EOF
out="$(bash "$backend" details U1 2>/dev/null)"
expect "multi-peer profile: first peer described, all peers counted" \
  '[ "$(field peers)" = "2" ] && [ "$(field endpoint)" = "203.0.113.7:1234" ] \
    && [ "$(field allowed)" = "192.0.2.0/24" ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
