# Design notes

Why Omazia behaves the way it does. The [README](../README.md) is the
reference; this file is the reasoning behind the parts that look opinionated.

## Multiple tunnels, one grid

Several tunnels can be up at once — each row's toggle brings its own tunnel
up or down, and `awg-quick`, another tool or a boot-time unit can add more.
The kernel is fine with several `wg` interfaces at once.

The detail grid still describes **one** tunnel, because one endpoint and one
ping cannot stand for two. By default that is the first active tunnel, or
whichever row you last clicked. The grid names the tunnel it is showing when
more than one is up, and highlights its row. Every other active tunnel keeps
a compact traffic line of its own in the list
(`↓ 3.0K/s ↑ 14.8K/s · ↓ 2.6M ↑ 1.1M`); the one in the grid does not, since
the same four numbers twice on one screen is noise.

Connected tunnels sort to the top of the list, name breaking ties, so what
is up is the first thing you see. The cursor follows the tunnel it was on
across that reorder, not the slot it held.

## Connection details

While a tunnel is up the panel shows what it is doing, in the same grid the
system network widget uses: ping and packet loss, current rates, session
totals, the tunnel address, the peer endpoint, the routes it claims and the
DNS it sets. The last four copy on click; a value too long for its cell
shows in full in the tooltip rather than staying behind an ellipsis.

Everything but the ping is read from `awg show` and `/sys`. The whole block
is live only while the panel is open — a sampled figure with nothing behind
it yet, or nothing behind it any more, reads `--` rather than `0 B/s`. The
numbers are activity, not health: AmneziaWG has no connection state, and an
idle tunnel is not a broken one.

The endpoint and the routes belong to the tunnel's **first peer**. Most
tunnels have exactly one; a tunnel with several says so under the grid
(`first of 3 peers`), because one endpoint line cannot describe a
site-to-site setup and should not pretend to.

## Ping

The ping is an ICMP probe bound to the tunnel device, so it measures the
path the tunnel actually routes rather than your physical link — it is the
one thing here that leaves your machine. It goes to `1.1.1.1` by default,
every three seconds while the panel is open, ten samples to a window. Set
`pingHost` to something inside your tunnel, or to an empty string to switch
the probe off. A split tunnel that does not route the ping host shows `--`
rather than a scary 100%.

Unprivileged: Omarchy leaves ping sockets open to all users, so nothing here
needs `CAP_NET_RAW`.

## Connecting and switching

Connecting brings up exactly one tunnel and leaves every other active tunnel
alone. An already-up tunnel is a no-op. A successful activation confirms
that `awg-quick up` returned, not that the peer is reachable: AmneziaWG has
no connected/disconnected handshake state to report.

To move from one tunnel to another, turn the first one off and the second
one on — there is no exclusive "switch" any more. The master toggle in the
panel header is the one exception: off takes every tunnel down, on brings
back the last one you used.

## Privilege

`awg`/`awg-quick` need root, so every privileged step is one verb of a
small root helper reached through polkit. The verbs split in two, along the
line that matters — does this expose or replace a private key?

Bringing a tunnel **up or down** (and listing, `awg show`, the redacted
detail read) is passwordless on the active local session: the same posture
NetworkManager already gives a desktop VPN, and nothing on that path prints
a `PrivateKey`. The detail grid reads a **redacted** copy of the config —
`PrivateKey`/`PresharedKey` come back as `(hidden)` — and `awg show dump`
has both its interface private-key column and every peer's preshared-key
column blanked, so the panel stays open without a prompt.

`up`/`down` still change root network state without a password. That is a
deliberate match to the NetworkManager posture, not an oversight: a control
verb neither reveals key material nor rewrites a stored config, and the
helper re-validates on every path that could plant an `awg-quick` hook.

**Revealing or rewriting** a stored config authenticates every time, even
on an active session: edit, export, QR, import-that-replaces, and delete
all go through a second helper entry point with its own polkit action. Each
of those either hands you the real key material or overwrites it, and a UI
button press is not an authorization boundary — a compromised session
process can press the same button. `auth_admin_keep` means one prompt
covers a short burst (import then reconnect) rather than one per verb.

There is no `sudo` fallback. polkit is the only privilege path: it is the
one mechanism that can draw the control/secrets line *and* raise a GUI auth
prompt from a bar widget that has no controlling terminal. A sudoers
drop-in could do neither without either going fully passwordless (which
erases the secrets boundary for every wheel process in the session) or
needing an askpass helper the widget cannot rely on. A desktop without a
polkit agent is unsupported.

### What the passwordless action still exposes

Being explicit about the residual surface, since it is a deliberate choice
rather than a gap: any process in the active session can call the control
action, and so can list the tunnel names, bring one up or down, and read the
redacted config — addresses, DNS, MTU, the peer endpoint and its **public**
key. No key material, no writes to a stored config, no deletion.

The alternative — `auth_admin` on the control action too — costs a password
prompt on every connect *and* on opening the panel, since the detail grid
reads the redacted config. That is the posture of a machine where the VPN is
an administrative setting rather than a desktop one; it is one attribute
change in `polkit/com.omarchy.amneziawg.policy` for anyone who wants it.

## Bounds and deadlines

Nothing on the privileged path or on the way into the panel is unbounded.
A config body is capped at 128 KiB, 2000 lines, 64 peers and 4 KiB per
value, checked twice: in `backend.sh` before anything is written, and again
in the root helper, which never trusts the caller. The helper reads stdin
through `head -c` rather than `$(cat)`, so an endless producer is refused
instead of being buffered as root.

Every producer feeding a QML `StdioCollector` is capped at the source, since
a collector with `waitForEnd` has no limit of its own: `backend.sh` output
goes through a `pipefail` pipe into `head -c` that preserves the backend's
exit code (the control and editor paths read `2`..`6` as distinct outcomes),
and the picker, clipboard, traffic and ping snippets cap themselves.

Every collecting process also runs under a watchdog. A producer that never
closes its pipe — a wedged authentication prompt, a stuck `awg-quick` — gets
`SIGTERM`, so its `EXIT` trap can still remove a temp file holding a private
key, and `SIGKILL` two seconds later. The signal reaches the shell this
widget spawned; a root descendant behind `pkexec` is already reparented and
cannot be signalled by an unprivileged process. So the widget stops waiting
on it and says so in the panel rather than clearing the operation silently —
the work may still be finishing as root, and that is the honest report.

## State on disk

Two files live outside `/etc`: the display-name sidecar and the last-used
tunnel marker, both under `~/.local/state/omarchy`. Neither holds a secret,
but both name the tunnels you run and both are writable by anything running
as you, so they are treated as untrusted.

The directory is created `0700` and verified before use — a real directory,
owned by you, not reached through a symlink, unreadable by anyone else; a
loose mode on a directory that predates us is tightened rather than refused.
Writes are atomic: refuse a symlinked or non-regular target, stage in a
`mktemp` file, `fsync`, rename. Reads are no-follow, bounded, and validated
(the marker must parse as a single interface name). A symlink found in place
of the sidecar is skipped with a warning rather than failing the listing —
labels are cosmetic and must not cost you the tunnel list — while a rename,
which writes, refuses outright.

`XDG_RUNTIME_DIR` gets the same privacy check but no repair: it is handed to
us by the session, and a world-readable one is somebody else's decision and
a signal to stop, not something to paper over.

## Importing

Importing asks for a name, because the interface is named after it and the
kernel only accepts up to 15 characters of `[A-Za-z0-9_=+.-]` — provider
files like `US-New York 03.conf` do not qualify. The name is the tunnel's
identity: it is the `.conf` basename under `/etc/amnezia/amneziawg`, the
`awg` interface, and the replace-or-not decision. There are no UUIDs.
Imported tunnels never auto-connect; a tunnel comes up only when you say so.

Replacing a tunnel during import is transactional. If `awg-quick` refuses to
bring the old tunnel down and its rollback also fails, the operation reports
that the state is unknown (backend exit `6`) instead of implying that only
one step failed. Both the old and the fully built replacement configs are
retained for manual recovery; the error names the interfaces rather than
discarding the only new configuration. Exit `6` also marks a failed cleanup
of an incomplete replacement, so editor saves never retry automatically on
top of a config the helper refused to remove.

## Renaming

Renaming changes a cosmetic **display-name sidecar** only —
`~/.local/state/omarchy/amneziawg-names`, an `iface<TAB>label` file on your
side. Spaces are fine, duplicates are refused. The interface name and the
`.conf` never change; that one obeys kernel rules and belongs to import.

## QR export

QR export renders the tunnel as a QR code in its own window, centred on the
screen — the panel closes, so nothing sits between the code and the phone's
camera. The PNG lives in `XDG_RUNTIME_DIR` (tmpfs, mode 0600) and is deleted
the moment the window closes.

Mind what the code contains: **the private key**. Scanning it *moves* the
tunnel, it does not add a device — an AmneziaWG server tracks one endpoint
per key, so two devices sharing a config kick each other offline on every
handshake. File export exists too, IPC-only: `exportConfig` writes a 0600
`.conf` atomically.

## Notifications

When a tunnel is deactivated by something other than this widget —
`awg-quick down` in a terminal, a reboot, a dying network — the bar icon
turns urgent and one toast says "Tunnel X was deactivated". Disconnects you
asked for stay silent, and several widget instances (one per monitor)
coordinate through a lock so you get one toast, not one per screen.

## Editing

Editing closes the panel and shows the config as `awg-quick`-style text in
zenity's text view — read straight from the stored file via the helper,
secrets included. Saving unchanged text does nothing; saving over a running
tunnel rewrites the config and brings the tunnel back up on it. Text
rejected by validation is handed back to the editor rather than thrown away.

## IPC semantics

Commands that start an asynchronous action return `ok` only when it has
actually been accepted. Control actions reject another running control
action; picker, clipboard import, QR and export reject only their own
already-running worker, while an editor may open during a control action and
queues its save. An editor rejects a second editor or a queued editor save.
`rename` to the current name is an idempotent `ok`. Name-based commands
refuse an ambiguous name and list the matching interface names instead.

`details` answers with the addresses whether or not the panel is open, and
with `--` for everything sampled — rates, totals and ping — because sampling
stops with the panel. A figure older than ten seconds reads `--` too: a
stale total is a wrong total, not an old one.
