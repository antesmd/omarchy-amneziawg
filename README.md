# WireGuard — Omarchy bar widget

Connect, switch, import and edit WireGuard tunnels from the Omarchy bar.

![The WireGuard panel](preview.png)

Tunnels are NetworkManager connection profiles. The widget lists every
WireGuard profile NetworkManager knows about, and importing a `.conf` file
creates one. Switching is exclusive: the tunnel you pick comes up and every
other WireGuard tunnel goes down. Non-WireGuard connections (wifi, ethernet,
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

## Install

```bash
omarchy plugin add https://github.com/glafeara/omarchy-wireguard.git
omarchy plugin enable glafeara.wireguard
omarchy bar plugin add glafeara.wireguard right
```

Plugins land disabled so you can read the code before enabling it — this one
is three QML files and one shell script. Add `--yes` to any of the commands
to skip the prompts.

## Migrating from 1.x

Version 1.x drove `wg-quick` via a sudoers rule and kept configs in
`~/.config/wireguard/`. To migrate:

1. Import each config through the panel (`i`, or
   `omarchy-shell glafeara.wireguard importConfig ~/.config/wireguard/kz.conf`).
2. Delete the old sudoers rule — it granted passwordless root and nothing
   needs it anymore:

   ```bash
   sudo rm -f /etc/sudoers.d/wireguard-omarchy
   ```

3. Optionally delete `~/.config/wireguard/*.conf` — after import the
   private keys live in NetworkManager's root-owned storage, so the copies
   in your home directory are just leftover secrets.

Tunnels brought up manually with `wg-quick up` are invisible to
NetworkManager and to this widget; bring them down once and use the widget
from then on.

## Using it

**In the bar:** left click toggles the last used tunnel (or opens the panel
when there are no connections yet), right click opens the panel (or
disconnects if a tunnel is up), middle click refreshes.

**In the panel:**

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the cursor |
| `Enter`, `Space` | connect or disconnect the selected connection |
| `t` | toggle the last used tunnel |
| `i` | import a `.conf` file |
| `v` | import a config from the clipboard |
| `e` | edit the selected connection |
| `x` | delete the selected connection (asks first) |
| `r` | refresh |
| `d` | disconnect everything |
| `Esc` | close |

**Importing** asks for a name, because the interface is named after it and
the kernel only accepts up to 15 characters of `[A-Za-z0-9_=+.-]` — provider
files like `US-New York 03.conf` do not qualify. The name doubles as the
replace-or-not decision. Imported profiles never auto-connect; a tunnel
comes up only when you say so.

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
```

## What it touches

- **NetworkManager connection profiles** of type `wireguard` — lists them,
  activates and deactivates them, creates one per import, deletes only what
  you explicitly delete. Secrets live in NetworkManager's own root-owned
  storage under `/etc/NetworkManager/system-connections/`.
- `~/.local/state/omarchy/wireguard-last` — the name of the last tunnel you
  connected, so the bar's quick toggle reconnects what you actually used.

Everything runs as your user; authorization is NetworkManager's stock
polkit policy. Private keys are passed to `nmcli` on stdin, never as
command-line arguments. No install or uninstall scripts, no services, no
network calls of its own.

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
