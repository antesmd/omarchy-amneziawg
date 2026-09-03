#!/bin/bash
# Tests for helper/omarchy-amneziawg-helper — the root helper — exercised
# directly (not via pkexec) with fake awg/awg-quick on PATH and AWG_CONFDIR
# pointed at a tmp dir. Covers the body re-validation (hook rejection, unknown
# keys), iface-name rejection (traversal, over-length), atomic 0600 write and
# temp-file cleanup on a rejected write.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
helper="$here/../helper/omarchy-amneziawg-helper"
pass=0 fail=0

# The real helper is installed under two names; the -secrets one is the only
# entry point that runs getconf/writeconf/delconf.
SBIN="$(mktemp -d)"
ln -s "$helper" "$SBIN/omarchy-amneziawg-helper-secrets"
helper_s="$SBIN/omarchy-amneziawg-helper-secrets"

expect() { # name condition-expr
  if eval "$2"; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; fail=$((fail+1)); fi
}

# --- sandbox with fake awg / awg-quick ------------------------------------
BIN="$(mktemp -d)"
cat > "$BIN/awg" <<'EOF'
#!/bin/bash
# fake awg: `show interfaces` prints nothing
[ "$1" = "show" ] && [ "$2" = "interfaces" ] && exit 0
exit 0
EOF
cat > "$BIN/awg-quick" <<'EOF'
#!/bin/bash
echo "awg-quick $*" >> "${HELPER_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/awg" "$BIN/awg-quick"
export PATH="$BIN:$PATH"

CONF="$(mktemp -d)"
export AWG_CONFDIR="$CONF"
export HELPER_LOG="$CONF/log"

VALID_BODY='[Interface]
PrivateKey = aaaa
Address = 10.0.0.2/32
Jc = 4
S1 = 50
H1 = 12345
# a comment

[Peer]
PublicKey = bbbb
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25'

# (a) valid writeconf -> 0600 file, matching content
printf '%s\n' "$VALID_BODY" | bash "$helper_s" writeconf tun0
rc=$?
expect "writeconf valid: exit 0" "[ $rc = 0 ]"
expect "writeconf valid: file exists" '[ -f "$CONF/tun0.conf" ]'
mode="$(stat -c '%a' "$CONF/tun0.conf" 2>/dev/null)"
expect "writeconf valid: mode 0600" '[ "$mode" = 600 ]'
expect "writeconf valid: content round-trips" \
  '[ "$(cat "$CONF/tun0.conf")" = "$VALID_BODY" ]'

# (e) getconf prints back what writeconf stored
got="$(bash "$helper_s" getconf tun0)"
expect "getconf returns stored body" '[ "$got" = "$VALID_BODY" ]'

# (b) bad iface names rejected, nothing written
for bad in "../etc/passwd" "foo/bar" "aaaaaaaaaaaaaaaa"; do
  before="$(ls -A "$CONF")"
  printf '%s\n' "$VALID_BODY" | bash "$helper_s" writeconf "$bad" >/dev/null 2>&1
  rc=$?
  after="$(ls -A "$CONF")"
  expect "iface '$bad' rejected non-zero" "[ $rc != 0 ]"
  expect "iface '$bad' wrote nothing" '[ "$before" = "$after" ]'
done

# (c) body with PostUp rejected, no file written
HOOK_BODY='[Interface]
PrivateKey = aaaa
PostUp = touch /tmp/pwned'
before="$(ls -A "$CONF")"
printf '%s\n' "$HOOK_BODY" | bash "$helper_s" writeconf hooky >/dev/null 2>&1
rc=$?
expect "PostUp body rejected non-zero" "[ $rc != 0 ]"
expect "PostUp body: no file written" '[ ! -e "$CONF/hooky.conf" ]'
expect "PostUp body: confdir unchanged" '[ "$before" = "$(ls -A "$CONF")" ]'

# (d) unknown key rejected
UNK_BODY='[Interface]
PrivateKey = aaaa
Foo = bar'
printf '%s\n' "$UNK_BODY" | bash "$helper_s" writeconf unk >/dev/null 2>&1
rc=$?
expect "unknown key rejected non-zero" "[ $rc != 0 ]"
expect "unknown key: no file written" '[ ! -e "$CONF/unk.conf" ]'

# (f) no leftover temp files after a rejected write
leftover="$(ls -A "$CONF" | grep -c '^\.omazia\.' || true)"
expect "no leftover mktemp temp files after rejected writes" '[ "$leftover" = 0 ]'

# list: interfaces, then a --- separator, then conf basenames
list_out="$(bash "$helper" list)"
expect "list includes stored conf basename" 'printf "%s\n" "$list_out" | grep -qx tun0'
expect "list emits a --- separator line" 'printf "%s\n" "$list_out" | grep -qx -- ---'
expect "list: conf basename appears after the separator" \
  '[ "$(printf "%s\n" "$list_out" | grep -nx -- --- | cut -d: -f1)" -lt "$(printf "%s\n" "$list_out" | grep -nx tun0 | cut -d: -f1)" ]'

# --- entry-point split (defence in depth behind the polkit actions) -------
for v in getconf writeconf delconf; do
  printf '%s\n' "$VALID_BODY" | bash "$helper" "$v" tun0 >/dev/null 2>&1
  expect "plain entry point refuses '$v'" "[ $? != 0 ]"
done
for v in list up down dump metaconf; do
  bash "$helper_s" "$v" tun0 >/dev/null 2>&1
  expect "-secrets entry point refuses '$v'" "[ $? != 0 ]"
done

# --- metaconf redacts the keys but keeps the routable facts ---------------
SECRET_BODY='[Interface]
PrivateKey = PRIVSECRET123=
Address = 10.9.9.9/32
DNS = 9.9.9.9
MTU = 1280

[Peer]
PublicKey = PUBKEY=
PresharedKey = PSKSECRET456='
printf '%s\n' "$SECRET_BODY" | bash "$helper_s" writeconf redact
meta="$(bash "$helper" metaconf redact)"
expect "metaconf hides PrivateKey" 'printf "%s" "$meta" | grep -q "PrivateKey = (hidden)" && ! printf "%s" "$meta" | grep -q PRIVSECRET123'
expect "metaconf hides PresharedKey" 'printf "%s" "$meta" | grep -q "PresharedKey = (hidden)" && ! printf "%s" "$meta" | grep -q PSKSECRET456'
expect "metaconf keeps Address/DNS/MTU" \
  'printf "%s" "$meta" | grep -q "Address = 10.9.9.9/32" && printf "%s" "$meta" | grep -q "DNS = 9.9.9.9" && printf "%s" "$meta" | grep -q "MTU = 1280"'

# --- dump redacts the interface private key and every peer PresharedKey --
cat > "$BIN/awg" <<'EOF'
#!/bin/bash
[ "$1" = show ] && [ "$3" = dump ] && {
  printf 'IFACEPRIV=\tIFACEPUB=\t51820\toff\n'
  printf 'PEERPUB1=\tPSKSECRET1=\t1.2.3.4:51820\t0.0.0.0/0\t0\t0\t0\t0\n'
  printf 'PEERPUB2=\t(none)\t5.6.7.8:51820\t10.0.0.0/24\t0\t0\t0\t0\n'
  exit 0
}
exit 0
EOF
chmod +x "$BIN/awg"
dump_out="$(bash "$helper" dump tun0)"
expect "dump redacts the interface private key" \
  '! printf "%s\n" "$dump_out" | grep -q IFACEPRIV && printf "%s\n" "$dump_out" | head -1 | grep -q "(hidden)" && printf "%s\n" "$dump_out" | grep -q IFACEPUB'
expect "dump redacts a peer PresharedKey" \
  '! printf "%s\n" "$dump_out" | grep -q PSKSECRET1 && [ "$(printf "%s\n" "$dump_out" | grep -c "(hidden)")" = 2 ]'
expect "dump keeps peer public keys and a (none) PSK" \
  'printf "%s\n" "$dump_out" | grep -q PEERPUB1 && printf "%s\n" "$dump_out" | grep -q PEERPUB2 && printf "%s\n" "$dump_out" | grep -q "(none)"'

# --- resource bounds ----------------------------------------------------
before="$(ls -A "$CONF")"
head -c $((131072 + 100)) /dev/zero | tr '\0' 'x' | bash "$helper_s" writeconf toobig >/dev/null 2>&1
expect "oversized body rejected" "[ $? != 0 ]"
expect "oversized body wrote nothing" '[ "$before" = "$(ls -A "$CONF")" ]'

{ echo '[Interface]'; echo 'PrivateKey = k'; for i in $(seq 1 2100); do echo "# pad $i"; done; } |
  bash "$helper_s" writeconf toolong >/dev/null 2>&1
expect "over-2000-line body rejected" "[ $? != 0 ] && [ ! -e \"\$CONF/toolong.conf\" ]"

{ echo '[Interface]'; echo 'PrivateKey = k'; for i in $(seq 1 70); do echo '[Peer]'; echo "PublicKey = p$i="; done; } |
  bash "$helper_s" writeconf toomany >/dev/null 2>&1
expect "over-64-peer body rejected" "[ $? != 0 ] && [ ! -e \"\$CONF/toomany.conf\" ]"

rm -rf "$BIN" "$CONF" "$SBIN"
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
