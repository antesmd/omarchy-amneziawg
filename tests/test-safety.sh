#!/bin/bash
# Regression tests for secret-bearing export, runtime-state safety, import
# cleanup/rollback and QR cleanup.  All NetworkManager calls hit fake/nmcli.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
backend="$here/../backend.sh"
export PATH="$here/fake:$PATH"
pass=0 fail=0

fresh() {
  export FAKE_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$FAKE_DIR/runtime"
  mkdir "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  : > "$FAKE_DIR/active"; : > "$FAKE_DIR/log"
}

done_case() {
  local name="$1" check="$2"
  if eval "$check"; then echo "PASS $name"; pass=$((pass + 1))
  else echo "FAIL $name"; fail=$((fail + 1)); [ -f "$FAKE_DIR/log" ] && sed 's/^/    /' "$FAKE_DIR/log"; fi
  rm -rf "$FAKE_DIR"
}

config() {
  printf '%s\n' '[Interface]' 'PrivateKey = test-private-key' 'Address = 10.0.0.2/32' '' '[Peer]' 'PublicKey = test-peer-key' 'AllowedIPs = 0.0.0.0/0'
}

fresh
printf '%s\n' 'wireguard.private-key:private' > "$FAKE_DIR/partial-export.U1"
printf 'unchanged' > "$FAKE_DIR/dest.conf"
bash "$backend" export U1 >/dev/null 2>&1; export_rc=$?
bash "$backend" export-file U1 "$FAKE_DIR/dest.conf" >/dev/null 2>&1; file_rc=$?
done_case "partial nmcli export fails and never overwrites destination" \
  '[ "$export_rc" != 0 ] && [ "$file_rc" != 0 ] && [ "$(cat "$FAKE_DIR/dest.conf")" = unchanged ]'

fresh
printf '%s\n' 'wireguard.private-key:private' 'wireguard.peers:peer= allowed-ips=0.0.0.0/0' > "$FAKE_DIR/export.U1"
bash "$backend" export-file U1 "$FAKE_DIR/dest.conf" >/dev/null 2>&1; good_export_rc=$?
dest_mode="$(stat -Lc '%a' "$FAKE_DIR/dest.conf")"
done_case "successful export-file is complete and mode 0600" \
  '[ "$good_export_rc" = 0 ] && [ "$dest_mode" = 600 ] && grep -q "PrivateKey = private" "$FAKE_DIR/dest.conf" && grep -q "\[Peer\]" "$FAKE_DIR/dest.conf"'

fresh
mkdir "$FAKE_DIR/unsafe"; chmod 777 "$FAKE_DIR/unsafe"
XDG_RUNTIME_DIR="$FAKE_DIR/unsafe" bash "$backend" down-all >/dev/null 2>&1; unsafe_rc=$?
mkdir "$FAKE_DIR/public755" "$FAKE_DIR/public750"; chmod 755 "$FAKE_DIR/public755"; chmod 750 "$FAKE_DIR/public750"
XDG_RUNTIME_DIR="$FAKE_DIR/public755" bash "$backend" down-all >/dev/null 2>&1; public755_rc=$?
XDG_RUNTIME_DIR="$FAKE_DIR/public750" bash "$backend" down-all >/dev/null 2>&1; public750_rc=$?
ln -s "$XDG_RUNTIME_DIR" "$FAKE_DIR/link"
XDG_RUNTIME_DIR="$FAKE_DIR/link" bash "$backend" down-all >/dev/null 2>&1; link_rc=$?
env -u XDG_RUNTIME_DIR bash "$backend" down-all >/dev/null 2>&1; unset_rc=$?
done_case "unset, non-private, unsafe and symlink runtime directories are refused" '[ "$unsafe_rc" != 0 ] && [ "$public755_rc" != 0 ] && [ "$public750_rc" != 0 ] && [ "$link_rc" != 0 ] && [ "$unset_rc" != 0 ]'

fresh
: > "$FAKE_DIR/fail-list-names"
bash "$backend" rename U1 renamed >/dev/null 2>&1; rename_rc=$?
done_case "rename fails closed when name listing fails" '[ "$rename_rc" != 0 ] && ! grep -q "connection modify" "$FAKE_DIR/log"'

fresh
config | bash "$backend" import wg0 >/dev/null 2>&1; import_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "import succeeds without parsing nmcli human output" '[ "$import_rc" = 0 ] && [ "$new_count" = 1 ]'

fresh
: > "$FAKE_DIR/fail-edit"
config | bash "$backend" import wg0 >/dev/null 2>&1; failed_import_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "failure after connection add cleans temporary profile" '[ "$failed_import_rc" != 0 ] && [ "$new_count" = 0 ]'

fresh
: > "$FAKE_DIR/fail-edit"; : > "$FAKE_DIR/fail-delete-any"
config | bash "$backend" import wg0 >/dev/null 2>"$FAKE_DIR/stderr"; failed_cleanup_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "failed temporary-profile cleanup warns with replacement UUID" \
  '[ "$failed_cleanup_rc" = 6 ] && [ "$new_count" = 1 ] && grep -q "Could not remove incomplete replacement" "$FAKE_DIR/stderr"'

fresh
: > "$FAKE_DIR/slow-add"
config | bash "$backend" import wg0 >/dev/null 2>&1 & import_pid=$!
sleep 0.2; kill -TERM "$import_pid"; wait "$import_pid"; interrupted_import_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "interrupted import cleans the temporary profile" '[ "$interrupted_import_rc" != 0 ] && [ "$new_count" = 0 ]'

fresh
echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.OLD"; echo old > "$FAKE_DIR/id.OLD"; : > "$FAKE_DIR/props.OLD"
: > "$FAKE_DIR/slow-down-any"
config | bash "$backend" import wg0 OLD >/dev/null 2>&1 & down_pid=$!
for _ in $(seq 1 20); do
  grep -q '^nmcli connection down OLD' "$FAKE_DIR/log" && break
  sleep 0.05
done
kill -TERM "$down_pid"; wait "$down_pid"; interrupted_down_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "interrupt after old down restores old and cleans uncommitted replacement" \
  '[ "$interrupted_down_rc" != 0 ] && [ "$new_count" = 1 ] && [ -e "$FAKE_DIR/props.OLD" ] && grep -qx OLD "$FAKE_DIR/active"'

fresh
echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.OLD"; echo old > "$FAKE_DIR/id.OLD"; : > "$FAKE_DIR/props.OLD"
: > "$FAKE_DIR/slow-down-any"; : > "$FAKE_DIR/fail-up.OLD"
config | bash "$backend" import wg0 OLD >/dev/null 2>"$FAKE_DIR/stderr" & failed_down_pid=$!
for _ in $(seq 1 20); do
  grep -q '^nmcli connection down OLD' "$FAKE_DIR/log" && break
  sleep 0.05
done
kill -TERM "$failed_down_pid"; wait "$failed_down_pid"; failed_down_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "interrupt after old down with failed restore keeps both profiles" \
  '[ "$failed_down_rc" = 6 ] && [ "$new_count" = 2 ] && grep -qi "state unknown" "$FAKE_DIR/stderr"'

fresh
echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.OLD"; echo old > "$FAKE_DIR/id.OLD"; : > "$FAKE_DIR/props.OLD"
: > "$FAKE_DIR/slow-down-any"; : > "$FAKE_DIR/fail-show-after.OLD"
config | bash "$backend" import wg0 OLD >/dev/null 2>"$FAKE_DIR/stderr" & failed_query_pid=$!
for _ in $(seq 1 20); do
  grep -q '^nmcli connection down OLD' "$FAKE_DIR/log" && break
  sleep 0.05
done
kill -TERM "$failed_query_pid"; wait "$failed_query_pid"; failed_query_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "cleanup old-query failure is terminal and keeps replacement" \
  '[ "$failed_query_rc" = 6 ] && [ "$new_count" = 2 ] && grep -q "Could not determine whether old profile" "$FAKE_DIR/stderr"'

fresh
echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.OLD"; echo old > "$FAKE_DIR/id.OLD"; : > "$FAKE_DIR/props.OLD"
: > "$FAKE_DIR/slow-up-any"
config | bash "$backend" import wg0 OLD >/dev/null 2>&1 & replacement_pid=$!
for _ in $(seq 1 20); do
  grep -q '^nmcli connection up ' "$FAKE_DIR/log" && break
  sleep 0.05
done
kill -TERM "$replacement_pid"; wait "$replacement_pid"; interrupted_replacement_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "interrupt after old delete keeps committed replacement" \
  '[ "$interrupted_replacement_rc" = 5 ] && [ "$new_count" = 1 ] && ! [ -e "$FAKE_DIR/props.OLD" ]'

fresh
echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.OLD"; echo old > "$FAKE_DIR/id.OLD"; : > "$FAKE_DIR/props.OLD"
: > "$FAKE_DIR/fail-up-any"
config | bash "$backend" import wg0 OLD >/dev/null 2>"$FAKE_DIR/stderr"; saved_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "saved-but-not-up keeps replacement and exits 5" '[ "$saved_rc" = 5 ] && [ "$new_count" = 1 ] && ! [ -e "$FAKE_DIR/props.OLD" ]'

fresh
echo OLD > "$FAKE_DIR/active"; echo wg0 > "$FAKE_DIR/ifname.OLD"; echo old > "$FAKE_DIR/id.OLD"; : > "$FAKE_DIR/props.OLD"
: > "$FAKE_DIR/fail-delete.OLD"; : > "$FAKE_DIR/fail-up.OLD"
config | bash "$backend" import wg0 OLD >/dev/null 2>"$FAKE_DIR/stderr"; rollback_rc=$?
new_count="$(find "$FAKE_DIR" -maxdepth 1 -name 'props.*' | wc -l)"
done_case "failed replacement rollback reports unknown state and keeps both profiles" \
  '[ "$rollback_rc" = 6 ] && grep -qi "state is unknown" "$FAKE_DIR/stderr" && [ "$new_count" = 2 ] && [ -e "$FAKE_DIR/props.OLD" ]'

fresh
: > "$FAKE_DIR/props.U1"
bash "$backend" delete U1 >/dev/null 2>&1; delete_rc=$?
done_case "delete uses the UUID target through NetworkManager" \
  '[ "$delete_rc" = 0 ] && grep -q "connection delete U1" "$FAKE_DIR/log" && ! [ -e "$FAKE_DIR/props.U1" ]'

fresh
printf '%s\n' 'wireguard.private-key:private' > "$FAKE_DIR/export.U1"
: > "$FAKE_DIR/fail-qr"
bash "$backend" qr-png U1 >/dev/null 2>&1; qr_rc=$?
png_count="$(find "$XDG_RUNTIME_DIR" -name 'wg-qr.*.png' | wc -l)"
done_case "failed QR encoding removes private-key PNG" '[ "$qr_rc" != 0 ] && [ "$png_count" = 0 ]'

fresh
printf '%s\n' 'wireguard.private-key:private' > "$FAKE_DIR/export.U1"
: > "$FAKE_DIR/slow-qr"
bash "$backend" qr-png U1 >/dev/null 2>&1 & pid=$!
sleep 0.2; kill -TERM "$pid"; wait "$pid"; signal_rc=$?
png_count="$(find "$XDG_RUNTIME_DIR" -name 'wg-qr.*.png' | wc -l)"
done_case "interrupted QR encoding removes private-key PNG" '[ "$signal_rc" != 0 ] && [ "$png_count" = 0 ]'

fresh
live_qr="$XDG_RUNTIME_DIR/wg-qr.$$.aaaaaa.png"
dead_qr="$XDG_RUNTIME_DIR/wg-qr.99999999.bbbbbb.png"
printf PNG > "$live_qr"; printf PNG > "$dead_qr"
bash "$backend" cleanup-runtime >/dev/null 2>&1; cleanup_rc=$?
done_case "runtime stale cleanup keeps live QR owner and removes dead owner" \
  '[ "$cleanup_rc" = 0 ] && [ -f "$live_qr" ] && ! [ -e "$dead_qr" ]'

fresh
printf '%s\n' 'wireguard.private-key:private' > "$FAKE_DIR/export.U1"
: > "$FAKE_DIR/slow-zenity"
bash "$backend" edit U1 tunnel </dev/null >/dev/null 2>&1 & editor_pid=$!
for _ in $(seq 1 20); do
  [ -f "$FAKE_DIR/edit-buffer-path" ] && break
  sleep 0.05
done
edit_count="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wg-edit.*' | wc -l)"
buffer_path="$(cat "$FAKE_DIR/edit-buffer-path" 2>/dev/null || true)"
buffer_mode="$(stat -Lc '%a' "$buffer_path" 2>/dev/null || true)"
kill -TERM "$editor_pid"; wait "$editor_pid"; editor_rc=$?
post_signal_edit_count="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wg-edit.*' | wc -l)"
done_case "editor secrets use private runtime files, never bare mktemp" \
  '[ "$editor_rc" != 0 ] && [ "$edit_count" = 2 ] && [ "$post_signal_edit_count" = 0 ] && [ "$buffer_mode" = 600 ] && [[ "$buffer_path" == "$XDG_RUNTIME_DIR"/* ]]'

fresh
printf '%s\n' 'wireguard.private-key:private' > "$FAKE_DIR/export.U1"
: > "$FAKE_DIR/fail-second-mktemp"
bash "$backend" edit U1 tunnel </dev/null >/dev/null 2>&1; second_mktemp_rc=$?
edit_count="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wg-edit.*' | wc -l)"
done_case "failed second editor mktemp cleans the first secret file" \
  '[ "$second_mktemp_rc" != 0 ] && [ "$edit_count" = 0 ]'

fresh
live_edit="$XDG_RUNTIME_DIR/wg-edit.$$.cccccc"
dead_edit="$XDG_RUNTIME_DIR/wg-edit.99999999.dddddd"
printf secret > "$live_edit"; printf secret > "$dead_edit"
bash "$backend" cleanup-runtime >/dev/null 2>&1; edit_cleanup_rc=$?
done_case "runtime stale cleanup keeps live editor owner and removes dead owner" \
  '[ "$edit_cleanup_rc" = 0 ] && [ -f "$live_edit" ] && ! [ -e "$dead_edit" ]'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
