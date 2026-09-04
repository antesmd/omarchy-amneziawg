# Omazia — AmneziaWG tunnels in the Omarchy bar

Connect, import, edit, rename and QR-export AmneziaWG tunnels from the
[Omarchy](https://github.com/basecamp/omarchy) bar — with live traffic, the
connection's own numbers, and a warning when a tunnel drops behind your
back. Each tunnel has its own toggle, so you can run several at once.

Omazia is an unofficial third-party widget. It is not affiliated with,
endorsed by, or connected to the AmneziaWG or WireGuard projects.

![The Omazia panel](preview.png)

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using it](#using-it)
- [Settings](#settings)
- [IPC](#ipc)
- [Security](#security)
- [What it touches](#what-it-touches)
- [Tests](#tests)
- [Uninstall](#uninstall)
- [License](#license) · [Trademarks](#trademarks)
- [Design notes](docs/design.md) — the reasoning behind the opinionated parts

## Requirements

- **`amneziawg-tools`** — `awg` and `awg-quick`. From pacman or the AUR.
- **`zenity`** — optional, for the file picker and the config editor.
  `kdialog` or `yad` also work for the file picker.
- **`wl-clipboard`** — optional, for importing a config from the clipboard
  and copying connection details.
- **`qrencode`** — optional, for showing a tunnel as a QR code.
- **`notify-send`** (libnotify) — optional, for the toast when a tunnel is
  deactivated externally.

## Install

```bash
omarchy plugin add https://github.com/antesmd/omarchy-amneziawg.git
omarchy plugin enable antesmd.amneziawg right
```

`plugin add` is interactive by default; add `--yes` to skip its prompt. The
explicit plugin id and `right` placement make `plugin enable`
non-interactive.

Then, once, for the root helper:

```bash
sudo ./install.sh
```

That installs the helper to `/usr/local/lib/omarchy-amneziawg-helper`, the
polkit policy to `/usr/share/polkit-1/actions/`, and creates
`/etc/amnezia/amneziawg` mode 0700. It is idempotent. **Log out and back in
afterwards** so polkit loads the new actions — until you do, every privileged
call will prompt or fail.

`awg` and `awg-quick` need root, so — unlike the NetworkManager backend this
widget grew from — this one-time step is unavoidable. See
[Security](#security) for what the helper does.

## Using it

**In the bar:** left click opens and closes the panel, right click
disconnects every active tunnel (or opens the panel when nothing is up),
middle click refreshes. The master VPN toggle is the switch in the panel
header, the `t` key with the cursor off the list, or the IPC `toggle`
command — off takes everything down, on brings back the last tunnel used.

**In the panel:**

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the cursor |
| `Enter`, `Space` | point the detail grid at the selected tunnel |
| `t` | toggle the selected tunnel (or, with the cursor on the header, the last used one) |
| `i` | import a `.conf` file |
| `v` | import a config from the clipboard |
| `e` | edit the selected tunnel's config (closes the panel) |
| `n` | rename the selected tunnel (closes the panel) |
| `q` | show the selected tunnel as a QR code |
| `x` | delete the selected tunnel (asks first) |
| `r` | refresh |
| `d` | disconnect everything |
| `Esc` | close |

Hovering a row reveals a toggle — flip it to bring that one tunnel up or
down; at rest the check glyph on the left marks a tunnel connected. Clicking
elsewhere on the row points the detail grid at that tunnel. The row under
the cursor also shows a pencil (edit config or name), a QR square, and a
trash can (delete).

**Connected tunnels sort to the top**, so what is up is the first thing you
see. While a tunnel is up the header carries a QR button for whichever
tunnel the grid is currently showing.

**Connection details.** While a tunnel is up the panel shows ping and packet
loss, current rates, session totals, the tunnel address, the peer endpoint,
routes and DNS — read from `awg show` and `/sys`, live only while the panel
is open. The numbers are activity, not health: AmneziaWG has no connection
state. Details for the semantics of `--`, first-peer endpoints, multiple
tunnels and the ping probe are in the [design notes](docs/design.md).

**Importing** asks for a name (the interface is named after it; the kernel
allows up to 15 characters of `[A-Za-z0-9_=+.-]`). The name is the `.conf`
basename, the `awg` interface, and the replace-or-not decision. Imported
tunnels never auto-connect. Replacing a tunnel during import is
transactional — see the [design notes](docs/design.md).

**Renaming** changes a cosmetic display-name sidecar only
(`~/.local/state/omarchy/amneziawg-names`). The interface name and the
`.conf` never change.

**QR export** renders the tunnel in its own centred window; the PNG lives in
`XDG_RUNTIME_DIR` (0600) and is deleted on close. The code contains **the
private key** — scanning it *moves* the tunnel, it does not add a device.

**Notifications.** When a tunnel is deactivated by something other than this
widget, the bar icon turns urgent and one toast says "Tunnel X was
deactivated". Disconnects you asked for stay silent.

**Editing** shows the config as `awg-quick`-style text in zenity, secrets
included. Saving over a running tunnel rewrites the config and brings the
tunnel back up on it. Text rejected by validation is handed back to the
editor.

## Settings

| Key | Default | Range |
| --- | --- | --- |
| `refreshIntervalSec` | `10` | 2–3600 |
| `pingHost` | `1.1.1.1` | any host, or empty to disable the probe |

```bash
omarchy bar set antesmd.amneziawg refreshIntervalSec 30
omarchy bar set antesmd.amneziawg pingHost ""     # no latency probe
```

## IPC

```bash
omarchy-shell antesmd.amneziawg status                  # "VPN: kz" / "VPN disconnected"
omarchy-shell antesmd.amneziawg details                 # the panel's grid on one line
omarchy-shell antesmd.amneziawg toggle                  # master: everything down, or the last used tunnel up
omarchy-shell antesmd.amneziawg connect kz              # bring up one tunnel, leaving the rest alone
omarchy-shell antesmd.amneziawg disconnect kz           # take down one tunnel, leaving the rest alone
omarchy-shell antesmd.amneziawg down                    # disconnect everything
omarchy-shell antesmd.amneziawg refresh
omarchy-shell antesmd.amneziawg open                    # also: close, show, hide
omarchy-shell antesmd.amneziawg importConfig /path/to/tunnel.conf
omarchy-shell antesmd.amneziawg edit kz
omarchy-shell antesmd.amneziawg importPick              # opens the file picker
omarchy-shell antesmd.amneziawg importPaste             # imports from the clipboard
omarchy-shell antesmd.amneziawg rename kz kz-home       # display name only
omarchy-shell antesmd.amneziawg exportConfig kz ~/kz.conf   # 0600, private key inside
omarchy-shell antesmd.amneziawg qr kz                   # QR window, centred on screen
```

Commands that start an asynchronous action return `ok` only when it has been
accepted. The concurrency rules and the `details` staleness semantics are in
the [design notes](docs/design.md).

## Security

The widget runs entirely as your user. Every privileged operation goes
through a **small root helper** invoked via **`pkexec`**. The same script is
installed under two names, bound to two polkit actions in
`com.omarchy.amneziawg.policy`, split along the line that matters — does this
verb expose or replace a private key?

- `com.omarchy.amneziawg.helper.control` (`list dump up down metaconf`,
  `allow_active=yes`) — an active local session brings its own tunnels up
  and down **without a password**, the same posture NetworkManager + polkit
  gave us. Nothing on this path prints key material: `metaconf` and the
  redacted `dump` return `PrivateKey`/`PresharedKey` as `(hidden)`.
- `com.omarchy.amneziawg.helper.secrets` (`getconf writeconf delconf`,
  `allow_active=auth_admin_keep`) — reading back or rewriting a stored
  config *including its keys*, or deleting a tunnel, **authenticates every
  time**, because a UI button press is not an authorization boundary. One
  prompt covers a short burst (import then reconnect).

The helper is a tiny `set -euf`, no-eval, verb-allowlisted script. It
validates the `<iface>` name against `[A-Za-z0-9_=+.-]{1,15}`, refuses path
traversal, refuses to touch anything outside `/etc/amnezia/amneziawg`, takes
config bodies on stdin so a key never rides on a command line, and caps
config size (128 KiB, 2000 lines, 64 peers) before it acts on one.

`pkexec`/polkit is the only privilege path — a desktop without a polkit
agent is unsupported. (`OMAWG_PRIV=direct` exists solely for the test suite,
which points the helper at a fake and never touches root.)

**`awg-quick` runs hooks.** It executes `PreUp`/`PostUp`/`PreDown`/`PostDown`
and honours `SaveConfig`, as root. Three things keep an imported config from
running commands:

1. every stored config is **generated by us** from a validated parse — the
   file you supply is never passed through, only its recognised keys are;
2. hook directives are rejected by the backend parser **and** re-rejected by
   the helper's `writeconf` before it writes anything;
3. the helper validates the `<iface>` and stays inside
   `/etc/amnezia/amneziawg`.

**Validation.** Every incoming config — file, clipboard or edit — is parsed
key by key. Keys must pass `awg pubkey`. Supported under `[Interface]`:
`Address`, `DNS`, `ListenPort`, `MTU`, `FwMark`, `Table`, and the AmneziaWG
obfuscation parameters `Jc`, `Jmin`, `Jmax`, `S1`–`S4`, `H1`–`H4`, `I1`–`I5`
— passed through verbatim under canonical casing. Under `[Peer]`:
`PublicKey`, `PresharedKey`, `AllowedIPs`, `Endpoint`,
`PersistentKeepalive`. Hook directives and unknown keys are rejected
outright — silently dropping them would lie about what the tunnel does. A
rejected import changes nothing.

Private keys are passed to the helper on stdin, never as command-line
arguments — and the detail query reads the redacted `metaconf` / `dump`, so
it never touches a secret and never prompts. `install.sh` / `uninstall.sh`
are the only privileged scripts; no services, no telemetry.

## What it touches

- **`/etc/amnezia/amneziawg/<iface>.conf`** — one root-owned 0600 config per
  tunnel, all CRUD through the root helper. Brings tunnels up and down with
  `awg-quick`, creates one per import, deletes only what you explicitly
  delete.
- `~/.local/state/omarchy/amneziawg-names` — the display-name sidecar
  (`iface<TAB>label`), your side, cosmetic. Written atomically; never
  touches a `.conf`.
- `~/.local/state/omarchy/amneziawg-last` — the interface name of the last
  tunnel you connected, so the bar's quick toggle reconnects what you used.
- `$XDG_RUNTIME_DIR/omarchy-amneziawg.<uid>.{lock,intent,notified}` — the
  cross-instance lock, the "this deactivation was ours" markers behind the
  notifications, and the toast cooldown stamp. The backend requires a
  private, current-user runtime directory (or its `/run/user/<uid>`
  fallback) and refuses to use `/tmp`. Gone at reboot.
- `$XDG_RUNTIME_DIR/omazia-qr.<shell-pid>.*.png` — the QR image while its
  window is open; deleted on close, dead-PID images reaped on next startup.
- `$XDG_RUNTIME_DIR/omazia-edit.<shell-pid>.*` — private editor buffers and
  result files while zenity is open; deleted on every editor exit.
- `/sys/class/net/<iface>/statistics/{rx,tx}_bytes` — read-only, for the
  traffic line, plus the interface's address and MTU for the detail grid.
- **One ICMP echo to `pingHost` every three seconds while the panel is
  open**, bound to the tunnel device — the only traffic the widget
  originates, and the only part you can switch off in the settings.

## Tests

`tests/` holds backend suites that run against fake `awg`, `awg-quick`,
`helper` and `qrencode` commands on `PATH` — no root, no real awg. A
separate suite drives the real helper. Plus a manual checklist
(`tests/checklist.md`) for what needs real tunnels.

```bash
bash tests/run.sh          # all backend suites, fakes only
bash tests/test-helper.sh  # the root helper itself
```

## Uninstall

```bash
omarchy plugin remove antesmd.amneziawg
sudo ./uninstall.sh
```

The first disables the widget and deletes the plugin directory; the second
removes the helper and polkit policy. Your tunnels stay in
`/etc/amnezia/amneziawg` — bring any down with `sudo awg-quick down <iface>`
and delete the `.conf` if you want them gone, and:

```bash
rm -f ~/.local/state/omarchy/amneziawg-last ~/.local/state/omarchy/amneziawg-names
```

## License

MIT — see [LICENSE](LICENSE).

## Trademarks

"WireGuard" and the "WireGuard" logo are registered trademarks of
Jason A. Donenfeld. See [wireguard.com](https://www.wireguard.com/).
AmneziaWG is a fork of WireGuard by the Amnezia VPN project. Omazia is an
independent third-party widget: it uses these names only to describe which
tunnels it manages, carries none of either project's branding, and is
neither affiliated with nor endorsed by the AmneziaWG or WireGuard projects.
The MIT licence above covers this widget's own code and grants no rights in
anyone else's trademarks.
