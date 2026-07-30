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
# Commands:
#   status                      list connections + active wireguard UUIDs
#   connect <uuid>              exclusive up: other wireguard profiles go down
#   down <uuid>                 deactivate one profile
#   down-all                    deactivate every active wireguard profile
#   delete <uuid>               delete a profile (deactivates it first)
#   import <name> [old-uuid] [file]   build a profile from wg-quick config
#                               text (stdin, or [file]); replaces [old-uuid]
#   export <uuid>               print the profile as wg-quick config text
#   edit <uuid> <name>          zenity editor round-trip (seed text on stdin)

set -u
# No globbing: list values from configs are word-split on purpose, and a
# value like "Address = *" must stay a literal asterisk, not a file list.
set -f
export LC_ALL=C

die() { printf '%s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

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

cmd_status() {
  nmcli -t -f UUID,NAME,TYPE connection show
  echo ---
  active_wg_uuids
}

cmd_connect() {
  local target="$1" u
  # Switching is exclusive, but only among wireguard profiles — wifi,
  # tailscale and everything else NetworkManager runs is not ours to touch.
  for u in $(active_wg_uuids); do
    [ "$u" = "$target" ] && continue
    nmcli connection down "$u" || exit 1
  done
  for u in $(active_wg_uuids); do
    [ "$u" = "$target" ] && exit 0
  done
  exec nmcli connection up "$target"
}

cmd_down() { exec nmcli connection down "$1"; }

cmd_down_all() {
  local rc=0 u
  for u in $(active_wg_uuids); do
    nmcli connection down "$u" || rc=1
  done
  exit "$rc"
}

cmd_delete() { exec nmcli connection delete "$1"; }

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
  [[ "$name" =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]] || die "Invalid interface name: $name"
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "No such file: $src"
    exec < "$src"
  fi
  parse_config

  local -a args=(connection add type wireguard
    con-name ".$name.import.$$" ifname "$name" autoconnect no)
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

  # Replace: the old profile only goes away once the new one is complete,
  # and deactivation is a hard precondition — on failure the old profile
  # (and the running tunnel it describes) stays untouched.
  if [ -n "$old_uuid" ]; then
    if active_wg_uuids | grep -qxF "$old_uuid"; then
      out="$(nmcli connection down "$old_uuid" 2>&1)" ||
        fail "Could not deactivate the old profile: $out"
    fi
    out="$(nmcli connection delete "$old_uuid" 2>&1)" ||
      fail "Could not delete the old profile: $out"
  fi
  nmcli connection modify "$uuid" connection.id "$name" ||
    fail "Could not rename the imported profile"
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

case "${1:-}" in
  status) cmd_status ;;
  connect) cmd_connect "$2" ;;
  down) cmd_down "$2" ;;
  down-all) cmd_down_all ;;
  delete) cmd_delete "$2" ;;
  import) cmd_import "$2" "${3:-}" "${4:-}" ;;
  export) cmd_export "$2" ;;
  edit) cmd_edit "$2" "$3" ;;
  *) die "Usage: backend.sh status|connect|down|down-all|delete|import|export|edit ..." ;;
esac
