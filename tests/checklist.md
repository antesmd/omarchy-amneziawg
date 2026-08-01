# Manual checklist

What the fake-nmcli suites cannot prove — run against real tunnels before a
release. A dead endpoint does **not** test rollback: `nmcli connection up`
activates a WireGuard profile successfully even when the peer is
unreachable, which is why the failure paths live in `test-connect.sh`.

## Switching

- [ ] Switch between two tunnels with different interface names — the new
      one comes up before the old one goes down (no VPN-less window).
- [ ] Switch between two tunnels sharing an interface name — old down,
      new up.
- [ ] Switch to a tunnel while several are active (activated via `nmcli`) —
      only WireGuard profiles are touched, wifi/tailscale stay up.
- [ ] Toggle from the bar and via `omarchy-shell glafeara.wireguard toggle`.

## Traffic

- [ ] Connected row shows `↓ …/s ↑ …/s · ↓ … ↑ …` within ~4s of opening
      the panel; totals reset after a reconnect.

## Export / QR

- [ ] `q` on a profile (or the QR button) opens the code centred on screen
      and closes the panel; `Esc`, `q` or a click outside closes it and
      deletes `$XDG_RUNTIME_DIR/wg-qr.*.png`. The panel stays closed.
- [ ] `omarchy-shell glafeara.wireguard qr <name>` with the panel closed
      opens the window without flashing the panel; on a second monitor the
      window lands on the screen whose bar was used.
- [ ] Without `qrencode` the window still opens and shows the install hint;
      the bar icon does not turn urgent.
- [ ] Two `qr` calls back to back: the second answers
      `error: another QR code is still rendering`, never a false `ok`.
- [ ] Opening the panel while a code is up (IPC `open`, or an import
      landing) closes the code rather than hiding the panel beneath it.
- [ ] Scanning with the phone's WireGuard app imports a working tunnel.
- [ ] `omarchy-shell glafeara.wireguard exportConfig <name> <path>` writes a
      0600 file that re-imports losslessly.

## Notifications

- [ ] With a tunnel up, `nmcli connection down <name>` from a terminal →
      one toast "Profile <name> was deactivated", bar icon turns urgent.
- [ ] Disconnecting from the panel/bar produces **no** toast.
- [ ] With two monitors (two widget instances), the external drop still
      produces exactly one toast.
- [ ] Restart NetworkManager with a tunnel up — toast appears, widget
      recovers on the next poll.

## Editing

- [ ] Pencil → Config closes the panel, and zenity comes up focused rather
      than behind the popup; the save goes over a running tunnel and the
      tunnel comes back up on the new profile.
- [ ] Pencil → Name closes the panel and opens the prompt centred on screen,
      field focused with the name selected. Renames without touching the
      interface; duplicates are refused. `Esc` or a click outside cancels,
      and the panel stays closed either way.
- [ ] `e` and `n` on the selected row do the same as the pencil's two
      answers, panel closing included.
- [ ] With `zenity` uninstalled, Config reopens the panel on "zenity is not
      installed" rather than leaving a closed popup and an urgent bar icon.
      Cancelling the editor, or saving unchanged text, does **not** reopen
      it. `omarchy-shell glafeara.wireguard edit <name>` with the panel
      closed stays headless either way.
- [ ] Opening the panel while the rename prompt is up (IPC `open`, or an
      import landing) closes the prompt rather than hiding the panel beneath
      it; `qr` while it is up does the same.
- [ ] The import prompt (`i` / `v`) still lives inside the panel and gets the
      focus back on cancel.
