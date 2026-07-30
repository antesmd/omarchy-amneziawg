# WireGuard — Omarchy bar widget

Connect, switch, import and edit WireGuard tunnels from the Omarchy bar.

![The WireGuard panel](preview.png)

Configs live in `~/.config/wireguard/` and the widget names each interface
after its file, exactly the way `wg-quick` does. Switching is exclusive: the
tunnel you pick comes up and everything else goes down.

## Requirements

- **`wireguard-tools`** — `wg` and `wg-quick`. Required.
- **Passwordless `wg-quick`.** Bringing a tunnel up needs root, and the widget
  never prompts. Grant exactly two commands and nothing else:

  ```bash
  echo "$USER ALL=(ALL:ALL) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick" |
    sudo tee /etc/sudoers.d/wireguard-omarchy
  sudo chmod 440 /etc/sudoers.d/wireguard-omarchy
  ```

  This plugin does not write that file for you — read the line, decide, then
  run it yourself. Without it the widget still lists configs and reports
  status, but connecting fails with a sudo error.
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
is two QML files. Add `--yes` to any of the commands to skip the prompts.

## Using it

**In the bar:** left click toggles the last used tunnel, right click opens the
panel (or disconnects if a tunnel is up), middle click refreshes.

**In the panel:**

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the cursor |
| `Enter`, `Space` | connect or disconnect the selected config |
| `t` | toggle the last used tunnel |
| `i` | import a `.conf` file |
| `v` | import a config from the clipboard |
| `e` | edit the selected config |
| `x` | delete the selected config (asks first) |
| `r` | refresh |
| `d` | disconnect everything |
| `Esc` | close |

**Importing** asks for a name, because `wg-quick` takes the interface name
from the filename and the kernel only accepts up to 15 characters of
`[A-Za-z0-9_=+.-]` — provider files like `US-New York 03.conf` do not
qualify. The name doubles as the replace-or-not decision.

**Editing** opens the config in zenity's text view. Saving unchanged text
leaves the file alone; saving over a running tunnel rewrites the config and
brings the tunnel back up on it. Text rejected by validation is handed back to
the editor rather than thrown away.

**Validation.** Every incoming config — file, clipboard or edit — must have an
`[Interface]` section, a `PrivateKey`, and keys that `wg pubkey` accepts. That
catches the truncated base64 copy-paste produces, which `wg-quick` would
otherwise only complain about at connect time. Addresses, endpoints and
unknown directives are left to `wg-quick`. Checks run *before* anything is
written, so a rejected import costs you neither the file you had nor the
tunnel you were on.

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
omarchy-shell glafeara.wireguard toggle
omarchy-shell glafeara.wireguard down                    # disconnect everything
omarchy-shell glafeara.wireguard refresh
omarchy-shell glafeara.wireguard open                    # also: close, show, hide
omarchy-shell glafeara.wireguard importConfig /path/to/tunnel.conf
omarchy-shell glafeara.wireguard edit kz
omarchy-shell glafeara.wireguard importPick              # opens the file picker
omarchy-shell glafeara.wireguard importPaste             # imports from the clipboard
```

## What it touches

- `~/.config/wireguard/*.conf` — reads them, and writes one when you import or
  edit. Writes go through a temp file in the same directory and land with mode
  `600`. Deletes only what you explicitly delete.
- `~/.local/state/omarchy/wireguard-last` — the name of the last tunnel you
  connected, so the bar's quick toggle reconnects what you actually used.
- `sudo -n wg-quick up|down` — nothing else runs as root, and the plugin never
  edits sudoers.

Nothing outside those paths, no install or uninstall scripts, no services, no
network calls of its own.

## Uninstall

```bash
omarchy bar plugin remove glafeara.wireguard
omarchy plugin remove glafeara.wireguard
```

That disables the widget and deletes the plugin directory. Your tunnels in
`~/.config/wireguard/` are left alone — they are yours and predate the plugin.
Two leftovers to clean up by hand if you want them gone:

```bash
rm -f ~/.local/state/omarchy/wireguard-last
sudo rm -f /etc/sudoers.d/wireguard-omarchy   # only if nothing else needs it
```

## License

MIT — see [LICENSE](LICENSE).
