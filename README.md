# WireGuard — Omarchy bar widget

Connect, switch, import, edit, rename and QR-export WireGuard tunnels from
the [Omarchy](https://github.com/basecamp/omarchy) bar — with live traffic and a warning when a tunnel drops
behind your back.

![The WireGuard panel](preview.png)

Tunnels are NetworkManager connection profiles. The widget lists every
WireGuard profile NetworkManager knows about, and importing a `.conf` file
creates one. Switching is exclusive and transactional: the tunnel you pick
comes up and every other WireGuard tunnel goes down — but when interface
names allow it the new tunnel comes up *first*, and if anything fails the
previously active tunnels are restored, so a broken profile never leaves
you without the VPN you had. Non-WireGuard connections (wifi, ethernet,
tailscale) are never touched.

**No sudo, no root shell.** Everything goes through NetworkManager over
D-Bus, authorized by polkit — on a stock Omarchy desktop an active local
session controls networking without a password, so the widget needs no
sudoers rules and never prompts. Unlike `wg-quick`, NetworkManager does not
execute `PreUp`/`PostUp`/`PreDown`/`PostDown` shell hooks, so a config file
is data, not code: importing a malicious config cannot run commands. Configs
containing hook directives are rejected with a clear message.

## Requirements

- **NetworkManager** — running (Omarchy default).
- **`wireguard-tools`** — only `wg` is used, to validate keys before import.
- **`zenity`** — optional, for the file picker and the config editor.
  `kdialog` or `yad` also work for the file picker.
- **`wl-clipboard`** — optional, for importing a config from the clipboard.
- **`qrencode`** — optional, for showing a profile as a QR code.
- **`notify-send`** (libnotify) — optional, for the toast when a tunnel is
  deactivated externally.

No new privileges for any of it: everything still runs as your user.

## Install

```bash
omarchy plugin add https://github.com/glafeara/omarchy-wireguard.git
omarchy plugin enable glafeara.wireguard
omarchy bar plugin add glafeara.wireguard right
```

Plugins land disabled so you can read the code before enabling it — this one
is three QML files and one shell script. Add `--yes` to any of the commands
to skip the prompts.

## Using it

**In the bar:** left click opens and closes the panel, right click
disconnects the active tunnel (or opens the panel when nothing is up),
middle click refreshes. The quick VPN toggle is the switch in the panel
header, the `t` key, or the IPC `toggle` command.

**In the panel:**

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the cursor |
| `Enter`, `Space` | connect or disconnect the selected connection |
| `t` | toggle the last used tunnel |
| `i` | import a `.conf` file |
| `v` | import a config from the clipboard |
| `e` | edit the selected connection's config |
| `n` | rename the selected connection |
| `q` | show the selected connection as a QR code |
| `x` | delete the selected connection (asks first) |
| `r` | refresh |
| `d` | disconnect everything |
| `Esc` | close |

The row under the cursor shows three buttons: the pencil asks whether to
edit the config or the name, the QR square opens the code, the trash can
deletes. While a tunnel is connected its row shows **traffic** — current
rate and session totals (`↓ 3.0K/s ↑ 14.8K/s · ↓ 2.6M ↑ 1.1M`), read from
the interface's `/sys` counters while the panel is open. That line is
activity, not health: WireGuard has no connection state, and an idle tunnel
is not a broken one.

**Importing** asks for a name, because the interface is named after it and
the kernel only accepts up to 15 characters of `[A-Za-z0-9_=+.-]` — provider
files like `US-New York 03.conf` do not qualify. The name doubles as the
replace-or-not decision. Imported profiles never auto-connect; a tunnel
comes up only when you say so.

**Switching** is transactional. With distinct interface names the new
tunnel comes up before the old ones go down (the kernel is fine with
several wg interfaces at once); with a shared or unset interface name the
order has to be down-then-up, and a failed activation rolls back to what
was active before. The panel tells you which of the three outcomes you
got: switched, "the previous tunnels were restored", or — if the rollback
itself failed — a plain statement that the state is unknown. A successful
activation confirms NetworkManager's state, not the peer's reachability:
WireGuard has no connected/disconnected handshake state to report.

**Renaming** changes the profile's display name (`connection.id`) only —
spaces are fine, duplicates are refused. The interface name never changes;
that one obeys kernel rules and belongs to import.

**QR export** (`q`, or the QR button) renders the profile as a QR code in
its own window, centred on the screen — the panel closes, so nothing sits
between the code and the phone's camera. `Esc`, `q` or a click outside
closes it. The PNG lives in `XDG_RUNTIME_DIR` (tmpfs, mode 0600) and is
deleted the moment the window closes. Mind what the code contains: **the
private key**. Scanning
it *moves* the profile, it does not add a device — a WireGuard server
tracks one endpoint per key, so two devices sharing a profile kick each
other offline on every handshake. File export exists too, IPC-only:
`exportConfig` below writes a 0600 `.conf` atomically.

**Notifications.** When a tunnel is deactivated by something other than
this widget — `nmcli` in a terminal, a NetworkManager restart, a dying
network — the bar icon turns urgent and one toast says
"Profile X was deactivated". Disconnects you asked for stay silent, and
several widget instances (one per monitor) coordinate through a lock so
you get one toast, not one per screen.

**Editing** shows the connection as wg-quick-style text in zenity's text
view — reconstructed from NetworkManager, secrets included. Saving unchanged
text does nothing; saving over a running tunnel rebuilds the profile and
brings the tunnel back up on it. Text rejected by validation is handed back
to the editor rather than thrown away.

**Validation.** Every incoming config — file, clipboard or edit — is parsed
key by key. Keys must pass `wg pubkey`, which catches the truncated base64
copy-paste produces. Supported: `Address`, `DNS`, `ListenPort`, `MTU`,
`FwMark`, `Table`, and per peer `PublicKey`, `PresharedKey`, `AllowedIPs`,
`Endpoint`, `PersistentKeepalive`. Hook directives and unknown keys are
rejected outright — with this backend they would never run, and silently
dropping them would lie about what the tunnel does. A rejected import
changes nothing: the profile you had and the tunnel you were on stay as
they were.

## Settings

| Key | Default | Range |
| --- | --- | --- |
| `refreshIntervalSec` | `10` | 2–3600 |

```bash
omarchy bar plugin set glafeara.wireguard refreshIntervalSec 30
```

## IPC

```bash
omarchy-shell glafeara.wireguard status                  # "VPN: kz" / "VPN disconnected"
omarchy-shell glafeara.wireguard toggle                  # connect/disconnect the last used tunnel
omarchy-shell glafeara.wireguard down                    # disconnect everything
omarchy-shell glafeara.wireguard refresh
omarchy-shell glafeara.wireguard open                    # also: close, show, hide
omarchy-shell glafeara.wireguard importConfig /path/to/tunnel.conf
omarchy-shell glafeara.wireguard edit kz
omarchy-shell glafeara.wireguard importPick              # opens the file picker
omarchy-shell glafeara.wireguard importPaste             # imports from the clipboard
omarchy-shell glafeara.wireguard rename kz kz-home       # display name only
omarchy-shell glafeara.wireguard exportConfig kz ~/kz.conf   # 0600, private key inside
omarchy-shell glafeara.wireguard qr kz                   # QR window, centred on screen
```

Name-based commands refuse an ambiguous name and list the matching UUIDs
instead — pass a UUID to disambiguate.

## What it touches

- **NetworkManager connection profiles** of type `wireguard` — lists them,
  activates and deactivates them, creates one per import, deletes only what
  you explicitly delete. Secrets live in NetworkManager's own root-owned
  storage under `/etc/NetworkManager/system-connections/`.
- `~/.local/state/omarchy/wireguard-last` — the UUID of the last tunnel you
  connected, so the bar's quick toggle reconnects what you actually used.
- `$XDG_RUNTIME_DIR/omarchy-wireguard.<uid>.{lock,intent,notified}` —
  the cross-instance lock, the short-lived "this deactivation was ours"
  markers behind the notifications, and the toast cooldown stamp. tmpfs,
  gone at reboot.
- `$XDG_RUNTIME_DIR/wg-qr.*.png` — the QR image while its window is open;
  deleted on close.
- `/sys/class/net/<iface>/statistics/{rx,tx}_bytes` — read-only, for the
  traffic line.

Everything runs as your user; authorization is NetworkManager's stock
polkit policy. Private keys are passed to `nmcli` on stdin, never as
command-line arguments. No install or uninstall scripts, no services, no
network calls of its own.

## Tests

`tests/` holds two suites that run the backend against a fake `nmcli` on
`PATH` — the only way to exercise the switch rollback paths, since a dead
endpoint does not make `nmcli connection up` fail — plus a manual
checklist (`tests/checklist.md`) for what needs real tunnels:

```bash
bash tests/test-connect.sh
bash tests/test-notify.sh
```

## Uninstall

```bash
omarchy bar plugin remove glafeara.wireguard
omarchy plugin remove glafeara.wireguard
```

That disables the widget and deletes the plugin directory. Your tunnels stay
in NetworkManager — remove them with `nmcli connection delete <name>` if you
want them gone, and:

```bash
rm -f ~/.local/state/omarchy/wireguard-last
```

## License

MIT — see [LICENSE](LICENSE).
