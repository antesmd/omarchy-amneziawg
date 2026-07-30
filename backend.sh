#!/bin/bash
# NetworkManager backend for the Omarchy WireGuard widget.
#
# Everything runs as the invoking user: tunnel control goes through
# NetworkManager over D-Bus, authorized by polkit (an active local session
# has network-control and settings.modify.system without a password on
# stock Omarchy). No sudo, no root shell — and unlike wg-quick, nothing
# here ever eval()s config content, so a config file is data, not code.
#
# Profiles are addressed by UUID everywhere: NetworkManager allows several
# connections with the same name, and names can contain characters that are
# unsafe to round-trip through nmcli's terse output.
#
# Secrets (PrivateKey, PresharedKey) are fed to `nmcli connection edit` on
# stdin, never passed as arguments — argv is world-readable in /proc.
#
# Mutating commands serialize on a per-user flock: the bar builds one widget
# instance per monitor, so two connects can race each other into "exclusive"
# tunnels that are anything but.
#
# Commands:
#   status                      list connections + active wireguard UUIDs
#   connect <uuid>              transactional exclusive switch. Exit 0: only
#                               the target is active. Exit 20: the switch
#                               failed and the previously active tunnels were
#                               restored. Exit 21: the switch failed and the
#                               rollback was incomplete — the resulting state
#                               is unknown.
#   down <uuid>                 deactivate one profile
#   down-all                    deactivate every active wireguard profile
#   delete <uuid>               delete a profile (deactivates it first)
#   rename <uuid> <new-id>      change connection.id (the display name);
#                               the interface name is never touched
#   import <name> [old-uuid] [file]   build a profile from wg-quick config
#                               text (stdin, or [file]); replaces [old-uuid],
#                               keeping its connection.id and interface-name,
#                               and reconnects if it was active. Exit 5 means
#                               the profile was saved but reconnecting failed.
#   export <uuid>               print the profile as wg-quick config text
#   export-file <uuid> <path>   write the config to a file, mode 0600
#   qr-png <uuid>               render the config as a QR PNG in
#                               XDG_RUNTIME_DIR, print its path (exit 2 =
#                               qrencode missing; the caller deletes the
#                               file when done)
#   edit <uuid> <name>          zenity editor round-trip (seed text on stdin)
#   notify-drop <uuid> <name>   decide whether an observed deactivation was
#                               external; exit 0 = external (toast sent,
#                               cooldown permitting), 1 = ours, stay quiet

set -u
# A failing nmcli at the head of a pipeline must fail the pipeline — status
# must never report "no tunnels" just because awk exited cleanly.
set -o pipefail
# No globbing: list values from configs are word-split on purpose, and a
# value like "Address = *" must stay a literal asterisk, not a file list.
set -f
export LC_ALL=C

die() { printf '%s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

# One writer at a time, across every widget instance (one per monitor).
# The fd stays open for the life of the process — including through the
# `exec nmcli` tail calls — so the lock covers the whole operation.
lock() {
  need flock
  local dir="${XDG_RUNTIME_DIR:-/tmp}"
  exec 9>>"$dir/omarchy-wireguard.$(id -u).lock" || die "Cannot open the lock file"
  flock -w 30 9 || die "Another WireGuard operation is already running"
}

# ---------------------------------------------------------------------------
# Intent markers: immediately before this script deactivates a profile it
# records the UUID, under the flock; when the widget later observes a
# tunnel going down, notify-drop consults the file to tell a user-initiated
# drop from an external one (nmcli, NM restart, a dying network) — only the
# latter deserves a notification. A marker is removed the moment the same
# UUID comes up again (by us, or observed by the widget via mark-active),
# so an activation always re-arms the notification. The TTL is only a
# garbage-collection backstop; it must exceed the widget's slowest poll
# (refreshIntervalSec caps at 3600), or an instance polling after expiry
# would toast about a disconnect the user asked for.
# ---------------------------------------------------------------------------

INTENT_TTL=7200

runtime_state() { printf '%s/omarchy-wireguard.%s.%s' "${XDG_RUNTIME_DIR:-/tmp}" "$(id -u)" "$1"; }

# Marker-file helpers. Failures are swallowed: a missed marker costs one
# spurious notification, not a broken operation. Both rewrites drop expired
# entries in passing.
mark_down() { # <uuid>
  local uuid="$1" f now u t keep=""
  f="$(runtime_state intent)"
  now="$(date +%s)"
  if [ -f "$f" ]; then
    while read -r u t; do
      case "$t" in ''|*[!0-9]*) continue ;; esac
      [ "$u" = "$uuid" ] && continue
      [ $((now - t)) -gt "$INTENT_TTL" ] && continue
      keep="$keep$u $t"$'\n'
    done < "$f"
  fi
  printf '%s' "$keep$uuid $now"$'\n' > "$f" 2>/dev/null || true
}

# clear_intent <uuid> [observed-epoch]: drop the uuid's marker. With an
# observation timestamp, only a marker strictly older is dropped — a
# delayed mark-active from a widget's queue must not erase the record of a
# down that happened after the observation, and with one-second timestamps
# a tie is indistinguishable from "after", so a tie keeps the marker (the
# conservative miss is a suppressed toast, not a false one).
clear_intent() {
  local uuid="$1" obs="${2:-}" f now u t keep=""
  f="$(runtime_state intent)"
  now="$(date +%s)"
  [ -f "$f" ] || return 0
  case "$obs" in *[!0-9]*) obs="" ;; esac
  while read -r u t; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ $((now - t)) -gt "$INTENT_TTL" ] && continue
    if [ "$u" = "$uuid" ]; then
      if [ -z "$obs" ] || [ "$t" -lt "$obs" ]; then continue; fi
    fi
    keep="$keep$u $t"$'\n'
  done < "$f"
  printf '%s' "$keep" > "$f" 2>/dev/null || true
}

# notify-drop <uuid> <name>: exit 0 = the drop was external (a desktop
# notification is sent unless one fired within the last 30s — several
# widget instances all observe the same transition), exit 1 = the drop was
# our own doing, stay quiet. Runs under the flock so instances serialize.
cmd_notify_drop() {
  local uuid="$1" name="$2" f now t u
  now="$(date +%s)"
  f="$(runtime_state intent)"
  if [ -f "$f" ]; then
    while read -r u t; do
      case "$t" in ''|*[!0-9]*) continue ;; esac
      if [ "$u" = "$uuid" ] && [ $((now - t)) -le "$INTENT_TTL" ]; then exit 1; fi
    done < "$f"
  fi
  f="$(runtime_state notified)"
  if [ -f "$f" ]; then
    t="$(cat "$f" 2>/dev/null)" || t=0
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    # External, but another instance already said so — no second toast.
    [ $((now - t)) -lt 30 ] && exit 0
  fi
  printf '%s' "$now" > "$f" 2>/dev/null || true
  command -v notify-send >/dev/null 2>&1 || exit 0
  notify-send -a WireGuard "WireGuard" "Profile $name was deactivated" 2>/dev/null || true
  exit 0
}

valid_key() { printf '%s\n' "$1" | wg pubkey >/dev/null 2>&1; }

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Undo nmcli -t escaping (\: and \\) in a captured field value.
unescape() {
  local s="$1"
  s="${s//\\:/:}"
  printf '%s' "${s//\\\\/\\}"
}

active_wg_uuids() {
  nmcli -t -f UUID,TYPE connection show --active | awk -F: '$2=="wireguard"{print $1}'
}

# NAME goes last: it is the only field that can contain (escaped) colons,
# so the QML side can split on the first three and take the rest verbatim.
# DEVICE is the live interface of an active connection — that, not the
# configured interface-name, is where /sys traffic counters live. The third
# section maps each wireguard UUID to its *configured* interface-name:
# rename decouples the display name from it, and import matches its
# replace-or-create decision on this, not on the label.
cmd_status() {
  local out actives ifnames uuid ifname
  out="$(nmcli -t -f UUID,TYPE,DEVICE,NAME connection show)" || exit 1
  # Everything is gathered before anything is printed, each fetch failing
  # the whole command: a swallowed error here would read as "no tunnels
  # up" or "no such interface" — status must never lie about either.
  actives="$(active_wg_uuids)" || exit 1
  ifnames=""
  for uuid in $(printf '%s\n' "$out" | awk -F: '$2=="wireguard"{print $1}'); do
    ifname="$(nmcli --escape no -g connection.interface-name connection show "$uuid")" || exit 1
    ifnames="$ifnames$uuid:$ifname"$'\n'
  done
  printf '%s\n' "$out"
  echo ---
  [ -n "$actives" ] && printf '%s\n' "$actives"
  echo ---
  printf '%s' "$ifnames"
}

# Transactional exclusive switch. The old tunnel must not be lost to a
# target that fails to come up: when interface names allow it the new tunnel
# comes up before the old ones go down (make-before-break — the kernel is
# fine with several wg interfaces at once), and any failure restores the
# snapshot of what was active when the switch began. Only wireguard profiles
# are touched — wifi, tailscale and everything else NetworkManager runs is
# not ours to bring down.
cmd_connect() {
  local target="$1" snapshot u out
  snapshot="$(active_wg_uuids)" || die "Could not list active connections"

  local target_was_active=0 others=""
  for u in $snapshot; do
    if [ "$u" = "$target" ]; then target_was_active=1
    else others="$others$u "; fi
  done
  [ "$target_was_active" = 1 ] && [ -z "$others" ] && exit 0

  # Overlap is only safe when every interface name involved is known and
  # distinct: the kernel refuses a second interface with the same name, and
  # an empty interface-name means NetworkManager picks one at activation —
  # unknowable in advance, so treated as a collision.
  local overlap=1 target_if u_if
  if [ "$target_was_active" = 0 ]; then
    target_if="$(nmcli --escape no -g connection.interface-name connection show "$target")" ||
      die "No such profile: $target"
    [ -n "$target_if" ] || overlap=0
    for u in $others; do
      u_if="$(nmcli --escape no -g connection.interface-name connection show "$u")" || u_if=""
      if [ -z "$u_if" ] || [ "$u_if" = "$target_if" ]; then overlap=0; fi
    done
  fi

  # Restore the snapshot: the target back down if it was not active before,
  # every snapshot member back up. Returns non-zero if anything resisted.
  restore() {
    local ok=0 u now
    now="$(active_wg_uuids)" || return 1
    if [ "$target_was_active" = 0 ] && printf '%s\n' "$now" | grep -qxF "$target"; then
      mark_down "$target"
      nmcli connection down "$target" >/dev/null 2>&1 || { clear_intent "$target"; ok=1; }
      now="$(active_wg_uuids)" || return 1
    fi
    for u in $snapshot; do
      printf '%s\n' "$now" | grep -qxF "$u" && continue
      if nmcli connection up "$u" >/dev/null 2>&1; then clear_intent "$u"; else ok=1; fi
    done
    return "$ok"
  }

  fail_switch() {
    printf '%s\n' "$1" >&2
    if restore; then
      echo "The previous tunnels were restored" >&2
      exit 20
    fi
    echo "Restoring the previous tunnels failed too — check your connections" >&2
    exit 21
  }

  if [ "$target_was_active" = 0 ] && [ "$overlap" = 0 ]; then
    # Same or unknown interface name: the old tunnels have to clear the way
    # first, so the unavoidable no-VPN window gets a rollback instead.
    for u in $others; do
      mark_down "$u"
      out="$(nmcli connection down "$u" 2>&1)" || {
        clear_intent "$u"
        fail_switch "Could not deactivate the previous tunnel: $out"
      }
    done
    out="$(nmcli connection up "$target" 2>&1)" ||
      fail_switch "Could not activate the tunnel: $out"
    clear_intent "$target"
  else
    if [ "$target_was_active" = 0 ]; then
      # Nothing has changed yet, so a refused activation needs no restore —
      # but it is still exit 20: the previous tunnels are all still up.
      out="$(nmcli connection up "$target" 2>&1)" ||
        fail_switch "Could not activate the tunnel: $out"
      clear_intent "$target"
    fi
    for u in $others; do
      mark_down "$u"
      out="$(nmcli connection down "$u" 2>&1)" || {
        clear_intent "$u"
        fail_switch "Could not deactivate the previous tunnel: $out"
      }
    done
  fi
}

cmd_down() {
  mark_down "$1"
  nmcli connection down "$1" || { clear_intent "$1"; exit 1; }
}

cmd_down_all() {
  local rc=0 u active
  active="$(active_wg_uuids)" || die "Could not list active connections"
  for u in $active; do
    mark_down "$u"
    nmcli connection down "$u" || { clear_intent "$u"; rc=1; }
  done
  exit "$rc"
}

cmd_delete() {
  # Deletion deactivates first; the marker keeps that from reading as an
  # external drop. A failed delete may leave the profile up — un-mark it.
  mark_down "$1"
  nmcli connection delete "$1" || { clear_intent "$1"; exit 1; }
}

# connection.id is a free-form display label; renaming must never touch
# connection.interface-name — that one obeys kernel rules and changing it
# on a live profile would strand the running interface.
cmd_rename() {
  local uuid="$1" new_id="$2"
  new_id="$(trim "$new_id")"
  [ -n "$new_id" ] || die "The new name must not be empty"
  case "$new_id" in
    *$'\n'*) die "The name must be a single line" ;;
  esac
  # The QML refuses duplicates too, but each widget instance judges by its
  # own possibly-stale snapshot — this check under the flock is the
  # authoritative one. NetworkManager itself would happily take the dup.
  nmcli --escape no -t -f NAME connection show | grep -qxF "$new_id" &&
    die "A profile named $new_id already exists"
  exec nmcli connection modify "$uuid" connection.id "$new_id"
}

# ---------------------------------------------------------------------------
# import: parse wg-quick config text into an NM profile.
#
# The profile is created with `nmcli connection add ... autoconnect no`, so
# it is inert from birth — `nmcli connection import` would instead activate
# the tunnel the instant the profile lands, before autoconnect could be
# switched off. Every key is mapped explicitly; hooks (PreUp/PostUp/...)
# are rejected with a clear message rather than silently dropped, because
# with this backend they will never run.
# ---------------------------------------------------------------------------

# Parser state (bash has no structs; the per-peer fields are flushed into
# PEERS as one nmcli attribute string per peer).
PK="" PORT="" MTU="" FWMARK="" TABLE=""
ADDR4="" ADDR6="" DNS4="" DNS6="" DNSSEARCH=""
PEERS=()
P_PUB="" P_PSK="" P_ALLOWED="" P_ENDPOINT="" P_KA=""

append() { # append <varname> <value> [separator]
  local -n ref="$1"
  ref="${ref:+$ref${3-,}}$2"
}

flush_peer() {
  if [ -z "$P_PUB$P_PSK$P_ALLOWED$P_ENDPOINT$P_KA" ]; then return 0; fi
  [ -n "$P_PUB" ] || die "A [Peer] section has no PublicKey"
  local s="$P_PUB"
  [ -n "$P_ALLOWED" ] && s+=" allowed-ips=$P_ALLOWED"
  [ -n "$P_ENDPOINT" ] && s+=" endpoint=$P_ENDPOINT"
  [ -n "$P_KA" ] && s+=" persistent-keepalive=$P_KA"
  [ -n "$P_PSK" ] && s+=" preshared-key=$P_PSK preshared-key-flags=0"
  PEERS+=("$s")
  P_PUB="" P_PSK="" P_ALLOWED="" P_ENDPOINT="" P_KA=""
}

parse_config() {
  local section="" lineno=0 line key value item
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    line="$(trim "$line")"
    [ -z "$line" ] && continue
    if [[ "$line" == \[*\] ]]; then
      value="${line#[}"; value="${value%]}"
      case "${value,,}" in
        interface) flush_peer; section=interface ;;
        peer) flush_peer; section=peer ;;
        *) die "Unknown section [$value] on line $lineno" ;;
      esac
      continue
    fi
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [ "$key" = "$line" ] && die "Line $lineno is not 'Key = value'"
    [ -n "$value" ] || die "$key on line $lineno has no value"
    case "$section" in
      interface)
        case "${key,,}" in
          privatekey)
            valid_key "$value" || die "Invalid PrivateKey — not a valid WireGuard key"
            PK="$value" ;;
          address)
            for item in ${value//,/ }; do
              case "$item" in
                *:*) append ADDR6 "$item" ;;
                *) append ADDR4 "$item" ;;
              esac
            done ;;
          dns)
            # wg-quick semantics: IP entries are resolvers, anything else
            # is a search domain.
            for item in ${value//,/ }; do
              if [[ "$item" == *:* ]]; then append DNS6 "$item"
              elif [[ "$item" =~ ^[0-9.]+$ ]]; then append DNS4 "$item"
              else append DNSSEARCH "$item"; fi
            done ;;
          listenport)
            is_num "$value" || die "Invalid ListenPort: $value"
            PORT="$value" ;;
          mtu)
            is_num "$value" || die "Invalid MTU: $value"
            MTU="$value" ;;
          fwmark)
            FWMARK="$value" ;;
          table)
            TABLE="$value" ;;
          preup|postup|predown|postdown)
            die "$key is not supported: with the NetworkManager backend config hooks never run" ;;
          saveconfig)
            die "SaveConfig is not supported with the NetworkManager backend" ;;
          *)
            die "Unsupported [Interface] key: $key" ;;
        esac ;;
      peer)
        case "${key,,}" in
          publickey)
            valid_key "$value" || die "Invalid PublicKey — not a valid WireGuard key"
            P_PUB="$value" ;;
          presharedkey)
            valid_key "$value" || die "Invalid PresharedKey — not a valid WireGuard key"
            P_PSK="$value" ;;
          allowedips)
            for item in ${value//,/ }; do
              append P_ALLOWED "$item" ";"
            done ;;
          endpoint)
            P_ENDPOINT="$value" ;;
          persistentkeepalive)
            is_num "$value" || die "Invalid PersistentKeepalive: $value"
            P_KA="$value" ;;
          *)
            die "Unsupported [Peer] key: $key" ;;
        esac ;;
      *)
        die "Line $lineno appears before any [Interface] or [Peer] section" ;;
    esac
  done
  flush_peer
  [ -n "$PK" ] || die "Not a WireGuard config (no PrivateKey)"
}

cmd_import() {
  local name="$1" old_uuid="${2:-}" src="${3:-}"
  need wg
  need nmcli
  # Replacing keeps the old profile's identity. connection.id is a free-form
  # display name ("Office VPN") while interface-name obeys kernel rules —
  # they are separate properties, and only the interface name is validated.
  # A fresh import has no old profile, so there the name serves as both.
  # --escape no: -g implies terse mode, which backslash-escapes ':' and '\'
  # by default even for a single field — the value must come back verbatim,
  # or the id is written back corrupted.
  local ifname="$name" con_id="$name" old_ifname
  if [ -n "$old_uuid" ]; then
    con_id="$(nmcli --escape no -g connection.id connection show "$old_uuid")" ||
      die "No such profile: $old_uuid"
    [ -n "$con_id" ] || con_id="$name"
    old_ifname="$(nmcli --escape no -g connection.interface-name connection show "$old_uuid")" || old_ifname=""
    [ -n "$old_ifname" ] && ifname="$old_ifname"
  fi
  [[ "$ifname" =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]] || die "Invalid interface name: $ifname"
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "No such file: $src"
    exec < "$src"
  fi
  parse_config

  local -a args=(connection add type wireguard
    con-name ".$ifname.import.$$" ifname "$ifname" autoconnect no)
  if [ -n "$ADDR4" ]; then args+=(ipv4.method manual ipv4.addresses "$ADDR4")
  else args+=(ipv4.method disabled); fi
  if [ -n "$ADDR6" ]; then args+=(ipv6.method manual ipv6.addresses "$ADDR6")
  else args+=(ipv6.method disabled); fi
  [ -n "$DNS4" ] && args+=(ipv4.dns "$DNS4")
  [ -n "$DNS6" ] && args+=(ipv6.dns "$DNS6")
  [ -n "$DNSSEARCH" ] && args+=(ipv4.dns-search "$DNSSEARCH")
  if [ -n "$DNS4$DNS6$DNSSEARCH" ]; then
    # wg-quick's resolvconf -x makes the tunnel DNS exclusive; a negative
    # priority is NetworkManager's way of saying the same thing.
    args+=(ipv4.dns-priority -10 ipv6.dns-priority -10)
  fi
  [ -n "$PORT" ] && args+=(wireguard.listen-port "$PORT")
  [ -n "$MTU" ] && args+=(wireguard.mtu "$MTU")
  [ -n "$FWMARK" ] && args+=(wireguard.fwmark "$FWMARK")
  case "$TABLE" in
    ""|auto) ;;
    off) args+=(wireguard.peer-routes no) ;;
    *)
      is_num "$TABLE" || die "Unsupported Table value: $TABLE"
      args+=(ipv4.route-table "$TABLE" ipv6.route-table "$TABLE") ;;
  esac

  local out uuid
  out="$(nmcli "${args[@]}" 2>&1)" || die "$out"
  uuid="$(printf '%s\n' "$out" | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -1)"
  [ -n "$uuid" ] || die "Could not determine the new profile's UUID"

  # From here on a failure must not leave the half-built profile behind.
  fail() {
    nmcli connection delete "$uuid" >/dev/null 2>&1
    die "$1"
  }

  # Secrets go in over the interactive editor's stdin, not argv.
  local feed peer
  feed="set wireguard.private-key $PK"$'\n'"set wireguard.private-key-flags 0"$'\n'
  if [ ${#PEERS[@]} -gt 0 ]; then
    local joined=""
    for peer in "${PEERS[@]}"; do
      joined="${joined:+$joined, }$peer"
    done
    feed+="set wireguard.peers $joined"$'\n'
  fi
  feed+="save persistent"$'\n'"quit"$'\n'
  printf '%s' "$feed" | nmcli connection edit "$uuid" >/dev/null 2>&1

  # The editor exits 0 even when a `set` failed — verify what was stored.
  [ "$(nmcli -s -g wireguard.private-key connection show "$uuid")" = "$PK" ] ||
    fail "Failed to store the private key in NetworkManager"
  if [ ${#PEERS[@]} -gt 0 ]; then
    local stored
    stored="$(nmcli -s -g wireguard.peers connection show "$uuid")"
    for peer in "${PEERS[@]}"; do
      case "$stored" in
        *"${peer%% *}"*) ;;
        *) fail "Failed to store peer ${peer%% *} in NetworkManager" ;;
      esac
    done
  fi

  # Replace, without a window where both profiles are lost: the new profile
  # takes its final connection.id first (duplicate ids are legal in
  # NetworkManager), so the old one is deleted only once the replacement is
  # fully usable — any failure up to that point keeps the old profile.
  # Whether to reconnect is decided here, from what is active right now, not
  # from what the UI saw when the edit began — the user may have switched
  # tunnels while the editor sat open.
  out="$(nmcli connection modify "$uuid" connection.id "$con_id" 2>&1)" ||
    fail "Could not rename the imported profile: $out"
  if [ -n "$old_uuid" ]; then
    local was_active=0 active
    active="$(active_wg_uuids)" || fail "Could not list active connections"
    printf '%s\n' "$active" | grep -qxF "$old_uuid" && was_active=1
    if [ "$was_active" = 1 ]; then
      mark_down "$old_uuid"
      out="$(nmcli connection down "$old_uuid" 2>&1)" || {
        clear_intent "$old_uuid"
        fail "Could not deactivate the old profile: $out"
      }
    fi
    out="$(nmcli connection delete "$old_uuid" 2>&1)" || {
      # Roll back: the tunnel was only taken down for the swap, so a failed
      # swap must not leave the VPN silently off.
      [ "$was_active" = 1 ] && nmcli connection up "$old_uuid" >/dev/null 2>&1 &&
        clear_intent "$old_uuid"
      fail "Could not delete the old profile: $out"
    }
    if [ "$was_active" = 1 ]; then
      # The replacement is complete; a failed activation must not delete it,
      # and must not read as a failed save either — the UI would reopen the
      # editor against the already-deleted old profile. Exit 5 says "saved,
      # but not reconnected".
      out="$(nmcli connection up "$uuid" 2>&1)" || {
        printf '%s\n' "Saved, but reconnecting failed: $out" >&2
        exit 5
      }
      clear_intent "$uuid"
    fi
  fi
}

# ---------------------------------------------------------------------------
# export: reconstruct wg-quick config text from an NM profile. Covers every
# key import accepts, so import -> export -> import is lossless.
# ---------------------------------------------------------------------------

cmd_export() {
  local uuid="$1"
  local pk="" port="" mtu="" fwmark="" peer_routes="" rtable=""
  local addr4="" addr6="" dns4="" dns6="" dnssearch="" peers=""
  local line key value
  while IFS= read -r line; do
    key="${line%%:*}"
    value="$(unescape "${line#*:}")"
    case "$key" in
      wireguard.private-key) pk="$value" ;;
      wireguard.listen-port) [ "$value" != 0 ] && port="$value" ;;
      wireguard.mtu) [ "$value" != 0 ] && mtu="$value" ;;
      wireguard.fwmark) [ "$value" != "0x0" ] && fwmark="$value" ;;
      wireguard.peer-routes) peer_routes="$value" ;;
      wireguard.peers) peers="$value" ;;
      ipv4.route-table) [ "$value" != 0 ] && rtable="$value" ;;
      ipv4.addresses) addr4="$value" ;;
      ipv6.addresses) addr6="$value" ;;
      ipv4.dns) dns4="$value" ;;
      ipv6.dns) dns6="$value" ;;
      ipv4.dns-search) dnssearch="$value" ;;
    esac
  done < <(nmcli -s -t connection show "$uuid")
  [ -n "$pk" ] || die "Could not read the private key from NetworkManager"

  local joined
  echo "[Interface]"
  echo "PrivateKey = $pk"
  joined="${addr4:+$addr4}${addr4:+${addr6:+, }}${addr6:-}"
  [ -n "$joined" ] && echo "Address = ${joined//,/, }" | sed 's/,  */, /g'
  joined="${dns4:-}"
  [ -n "$dns6" ] && joined="${joined:+$joined,}$dns6"
  [ -n "$dnssearch" ] && joined="${joined:+$joined,}$dnssearch"
  [ -n "$joined" ] && echo "DNS = ${joined//,/, }" | sed 's/,  */, /g'
  [ -n "$port" ] && echo "ListenPort = $port"
  [ -n "$mtu" ] && echo "MTU = $mtu"
  [ -n "$fwmark" ] && echo "FwMark = $fwmark"
  if [ "$peer_routes" = "no" ]; then echo "Table = off"
  elif [ -n "$rtable" ]; then echo "Table = $rtable"; fi

  [ -z "$peers" ] && return 0
  local chunk token first
  while IFS= read -r chunk; do
    chunk="$(trim "$chunk")"
    [ -z "$chunk" ] && continue
    echo
    echo "[Peer]"
    first=1
    for token in $chunk; do
      if [ "$first" = 1 ]; then
        echo "PublicKey = $token"
        first=0
        continue
      fi
      key="${token%%=*}"
      value="${token#*=}"
      case "$key" in
        allowed-ips) echo "AllowedIPs = ${value//;/, }" ;;
        endpoint) echo "Endpoint = $value" ;;
        persistent-keepalive) echo "PersistentKeepalive = $value" ;;
        preshared-key) echo "PresharedKey = $value" ;;
      esac
    done
  done < <(printf '%s\n' "${peers//, /$'\n'}")
}

# ---------------------------------------------------------------------------
# export-file / qr: the config leaves NetworkManager's root-owned storage
# with the private key inside, so the handling is deliberate. The file lands
# with mode 0600 no matter what existed at the destination: written as a
# 0600 temp in the destination directory, then renamed over the target —
# plain `umask 077` + `>` would keep a pre-existing file's 0644. The QR PNG
# lives only in XDG_RUNTIME_DIR (tmpfs on Omarchy, mode 0700, gone by
# reboot).
# ---------------------------------------------------------------------------

cmd_export_file() {
  local uuid="$1" dest="$2" dir tmp
  [ -n "$dest" ] || die "No destination path"
  # A directory destination would let mv slide the secret inside it under
  # the temp file's hidden name — refuse anything but a regular file.
  [ -d "$dest" ] && die "Destination is a directory: $dest"
  [ -e "$dest" ] && [ ! -f "$dest" ] && die "Destination is not a regular file: $dest"
  dir="$(dirname -- "$dest")"
  [ -d "$dir" ] || die "No such directory: $dir"
  umask 077
  tmp="$(mktemp -- "$dir/.wg-export.XXXXXX")" || die "Cannot create a file in $dir"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  cmd_export "$uuid" > "$tmp" || die "Could not export the profile"
  # -T: dest is the file itself, never a directory to move into.
  mv -fT -- "$tmp" "$dest" || die "Could not write $dest"
  trap - EXIT HUP INT TERM
}

# Renders the PNG and prints its path — the panel displays it inline and
# deletes it when the QR dialog closes, so the file's lifetime belongs to
# the caller, not to a trap here. XDG_RUNTIME_DIR is tmpfs with mode 0700:
# nothing lands on disk, and a crashed caller leaks the file only until
# reboot.
cmd_qr_png() {
  local uuid="$1" dir png
  command -v qrencode >/dev/null 2>&1 ||
    { echo "qrencode is not installed — sudo pacman -S qrencode" >&2; exit 2; }
  dir="${XDG_RUNTIME_DIR:-}"
  [ -n "$dir" ] && [ -d "$dir" ] ||
    die "XDG_RUNTIME_DIR is not available — refusing to write key material anywhere less private"
  umask 077
  png="$(mktemp -- "$dir/wg-qr.XXXXXX.png")" || die "Cannot create a file in $dir"
  cmd_export "$uuid" | qrencode -t PNG -s 6 -m 2 -o "$png" ||
    { rm -f "$png"; die "Could not encode the config as a QR code"; }
  printf '%s\n' "$png"
}

# ---------------------------------------------------------------------------
# edit: zenity round-trip. Exit codes: 2 = no zenity, 3 = Cancel,
# 4 = saved with no changes. Seed text (a rejected edit being retried)
# arrives on stdin; empty stdin means a fresh edit of the stored profile.
# ---------------------------------------------------------------------------

cmd_edit() {
  local uuid="$1" name="$2" seed src tmp buf
  seed="$(cat)"
  command -v zenity >/dev/null 2>&1 || exit 2
  src="$(cmd_export "$uuid")" || exit 1
  umask 077
  tmp="$(mktemp)" && buf="$(mktemp)" || exit 1
  trap 'rm -f "$tmp" "$buf"' EXIT
  if [ -n "$seed" ]; then printf '%s\n' "$seed" > "$buf"
  else printf '%s\n' "$src" > "$buf"; fi
  zenity --text-info --editable --filename="$buf" \
    --title="Edit $name" --width=700 --height=560 > "$tmp" || exit 3
  printf '%s\n' "$src" | cmp -s "$tmp" - && exit 4
  cat -- "$tmp"
}

# edit is deliberately unlocked: it holds zenity open for as long as the
# user cares to type, and the save that follows goes through import anyway.
case "${1:-}" in
  status) cmd_status ;;
  connect) lock; cmd_connect "$2" ;;
  down) lock; cmd_down "$2" ;;
  down-all) lock; cmd_down_all ;;
  delete) lock; cmd_delete "$2" ;;
  rename) lock; cmd_rename "$2" "$3" ;;
  import) lock; cmd_import "$2" "${3:-}" "${4:-}" ;;
  notify-drop) lock; cmd_notify_drop "$2" "$3" ;;
  # The widget reports profiles it saw come up outside this script, so a
  # stale "we downed this" marker never mutes a genuinely external drop.
  # The third argument is when the widget made the observation.
  mark-active) lock; clear_intent "$2" "${3:-}" ;;
  export) cmd_export "$2" ;;
  export-file) cmd_export_file "$2" "$3" ;;
  qr-png) cmd_qr_png "$2" ;;
  edit) cmd_edit "$2" "$3" ;;
  *) die "Usage: backend.sh status|connect|down|down-all|delete|rename|import|export|export-file|qr-png|edit ..." ;;
esac
