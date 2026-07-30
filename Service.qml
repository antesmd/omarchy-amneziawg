import QtQuick
import Quickshell
import Quickshell.Io

// Headless state for the WireGuard widget: discovers configs in
// ~/.config/wireguard, tracks which interfaces are up, and drives
// wg-quick up/down (sudoers grants NOPASSWD for wg/wg-quick).
Item {
  id: root

  property var settings: ({})

  readonly property string configsDir: Quickshell.env("HOME") + "/.config/wireguard"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string lastFile: stateDir + "/wireguard-last"

  // Config basenames without .conf, e.g. ["kz", "padel"]
  property var configs: []
  // Interface names currently up; wg-quick names them after the conf file
  property var activeInterfaces: []
  readonly property bool active: activeInterfaces.length > 0
  // Most recently connected config, persisted across restarts so the
  // hero toggle reconnects what you actually used last.
  property string lastConnected: ""
  property string actionStatus: ""
  property string lastError: ""

  readonly property bool busy: controlProcess.running
  readonly property string statusText: active ? "VPN: " + activeInterfaces.join(" ") : "VPN disconnected"
  // What toggle() would bring up: last used config if it still exists,
  // otherwise the first one.
  readonly property string toggleTarget: configs.indexOf(lastConnected) !== -1 ? lastConnected : (configs.length > 0 ? configs[0] : "")

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 3600)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function isActive(name) {
    return activeInterfaces.indexOf(String(name)) !== -1
  }

  function applyStatus(raw) {
    var lines = String(raw || "").split("\n")
    var sep = lines.indexOf("---")
    if (sep === -1) {
      lastError = "Failed to read WireGuard status"
      return
    }
    var found = []
    for (var i = 0; i < sep; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".conf") found.push(name.slice(0, -5))
    }
    var up = []
    for (var j = sep + 1; j < lines.length; j++) {
      var iface = lines[j].trim()
      if (iface !== "") up.push(iface)
    }
    configs = found
    activeInterfaces = up
    // Track connects made outside the widget too (CLI, scripts).
    if (up.length > 0) rememberLast(up[0])
    lastError = ""
  }

  function rememberLast(name) {
    var value = String(name || "")
    if (value === "" || value === lastConnected) return
    lastConnected = value
    saveProcess.command = ["bash", "-c",
      "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$1/wireguard-last\"",
      "wireguard", stateDir, value]
    saveProcess.running = true
  }

  function connectTo(name) {
    if (busy || !name) return
    actionStatus = "Connecting " + name + "…"
    _pendingConnect = String(name)
    runControl(connectScript, [name])
  }

  function disconnectOne(name) {
    if (busy || !name) return
    actionStatus = "Disconnecting " + name + "…"
    runControl(disconnectOneScript, [name])
  }

  function disconnectAll() {
    if (busy) return
    actionStatus = "Disconnecting…"
    runControl(disconnectAllScript, [])
  }

  function deleteConfig(name) {
    if (busy || !name) return
    actionStatus = "Deleting " + name + "…"
    runControl(deleteScript, [name])
  }

  function toggle() {
    if (active) disconnectAll()
    else if (toggleTarget !== "") connectTo(toggleTarget)
  }

  // Import: a picked file or pasted text lands as $configsDir/<name>.conf,
  // and the status poll picks it up as a new config on the next tick.
  // Emitted once a source is in hand; the panel then asks for a name,
  // because neither source carries one the kernel will accept.
  signal importReady(string kind, string payload, string suggestedName)

  function pickConfigFile() {
    if (busy || pickerProcess.running) return
    lastError = ""
    actionStatus = "Waiting for the file picker…"
    pickerProcess.running = true
  }

  function pasteConfig() {
    if (busy || clipboardProcess.running) return
    lastError = ""
    actionStatus = "Reading clipboard…"
    clipboardProcess.running = true
  }

  // Opens the config in zenity's editable text view. Saving goes back
  // through importText, so an edit gets the same validation and atomic
  // write as an import — and a tunnel that was up when you started editing
  // is brought back up on the new config.
  // `seedText` reopens the editor on text that was rejected rather than on
  // what is still on disk, so a save refused by wg_check costs a keystroke
  // to fix instead of the whole edit.
  function editConfig(name, seedText) {
    if (!name || editProcess.running) return
    if (configs.indexOf(String(name)) === -1) return
    _editTarget = String(name)
    _editWasActive = isActive(name)
    if (!seedText) lastError = ""
    actionStatus = "Editing " + name + "…"
    editProcess.command = ["bash", "-c", editScript, "wireguard",
      configsDir, String(name), String(seedText || "")]
    editProcess.running = true
  }

  // Puts rejected text back in front of the user with the reason showing.
  // Deferred through a timer because the editor process that produced the
  // text is still winding down when the rejection lands.
  function retryEdit(name, text, message) {
    lastError = message
    _editRetryName = String(name)
    _editRetryText = String(text)
    editRetryTimer.restart()
  }

  function importFile(path, name) {
    if (busy || !path || !name) return
    actionStatus = "Importing " + name + "…"
    runControl(importFileScript, [String(path), String(name)])
  }

  function importText(text, name) {
    if (busy || !text || !name) return
    actionStatus = "Importing " + name + "…"
    runControl(importTextScript, [String(name), String(text)])
  }

  // wg-quick names the interface after the file, and the kernel caps
  // interface names at 15 chars from [A-Za-z0-9_=+.-] — provider configs
  // ("US-New York 03.conf") routinely break both rules.
  function sanitizeName(raw) {
    var base = String(raw || "").split("/").pop()
    if (base.slice(-5).toLowerCase() === ".conf") base = base.slice(0, -5)
    base = base.replace(/[^A-Za-z0-9_=+.-]+/g, "-")
    base = base.replace(/^[-.]+/, "").replace(/[-.]+$/, "")
    // Trim again after the cut so truncation can't leave a trailing "-".
    return base.substring(0, 15).replace(/[-.]+$/, "")
  }

  function isValidName(name) {
    return /^[A-Za-z0-9_=+.-]{1,15}$/.test(String(name || ""))
  }

  function looksLikeConfig(text) {
    var value = String(text || "")
    return /^[ \t]*\[Interface\]/m.test(value) && /PrivateKey[ \t]*=/i.test(value)
  }

  // Pasted text carries no name of its own — offer the first free wgN.
  function suggestName() {
    for (var i = 0; i < 100; i++) {
      if (configs.indexOf("wg" + i) === -1) return "wg" + i
    }
    return "wg"
  }

  function runControl(script, args) {
    _controlError = ""
    controlProcess.command = ["bash", "-c", script, "wireguard", configsDir].concat(args)
    controlProcess.running = true
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  // Scripts receive $1 = configs dir, $2 = target config name.
  // Switching is exclusive: everything except the target goes down first,
  // matching how the old waybar setup treated multiple configs.
  readonly property string statusScript:
    "find \"$1\" -maxdepth 1 -name '*.conf' -printf '%f\\n' 2>/dev/null | sort\n" +
    "echo ---\n" +
    "ip -br link show type wireguard 2>/dev/null | awk '{print $1}'\n"

  readonly property string connectScript:
    "set -e\n" +
    "cfgdir=\"$1\"; target=\"$2\"\n" +
    "for iface in $(ip -br link show type wireguard 2>/dev/null | awk '{print $1}'); do\n" +
    "  [ \"$iface\" = \"$target\" ] && continue\n" +
    "  sudo -n wg-quick down \"$cfgdir/$iface.conf\"\n" +
    "done\n" +
    "if ! ip link show \"$target\" >/dev/null 2>&1; then\n" +
    "  sudo -n wg-quick up \"$cfgdir/$target.conf\"\n" +
    "fi\n"

  readonly property string disconnectOneScript:
    "sudo -n wg-quick down \"$1/$2.conf\"\n"

  readonly property string disconnectAllScript:
    "status=0\n" +
    "for iface in $(ip -br link show type wireguard 2>/dev/null | awk '{print $1}'); do\n" +
    "  sudo -n wg-quick down \"$1/$iface.conf\" || status=1\n" +
    "done\n" +
    "exit $status\n"

  readonly property string deleteScript:
    "set -e\n" +
    "cfgdir=\"$1\"; target=\"$2\"\n" +
    "if ip link show \"$target\" >/dev/null 2>&1; then\n" +
    "  sudo -n wg-quick down \"$cfgdir/$target.conf\"\n" +
    "fi\n" +
    "rm -- \"$cfgdir/$target.conf\"\n"

  // The one gate every incoming config passes, whatever the source: an
  // [Interface] section, a PrivateKey, and every key in the file in a form
  // wg itself accepts. `wg pubkey` is the check — it needs no root and
  // rejects the truncated/mangled base64 that copy-paste produces, which is
  // the failure wg-quick would otherwise only report at connect time.
  // Deliberately not a full parse: addresses, endpoints and unknown keys
  // are still wg-quick's business.
  readonly property string checkScript:
    "wg_check() {\n" +
    "  local f=\"$1\" line kind key\n" +
    "  command -v wg >/dev/null 2>&1 || { echo \"wireguard-tools is not installed\" >&2; return 1; }\n" +
    "  grep -qi '^[[:space:]]*\\[Interface\\]' \"$f\" ||\n" +
    "    { echo \"Not a WireGuard config (no [Interface] section)\" >&2; return 1; }\n" +
    "  grep -qiE '^[[:space:]]*PrivateKey[[:space:]]*=' \"$f\" ||\n" +
    "    { echo \"Not a WireGuard config (no PrivateKey)\" >&2; return 1; }\n" +
    "  while IFS= read -r line; do\n" +
    "    kind=\"${line%%=*}\"; kind=\"${kind//[[:space:]]/}\"\n" +
    "    key=\"${line#*=}\"; key=\"${key//[[:space:]]/}\"\n" +
    "    printf '%s\\n' \"$key\" | wg pubkey >/dev/null 2>&1 ||\n" +
    "      { echo \"Invalid $kind — not a valid WireGuard key\" >&2; return 1; }\n" +
    "  done < <(grep -iE '^[[:space:]]*(PrivateKey|PublicKey|PresharedKey)[[:space:]]*=' \"$f\")\n" +
    "  return 0\n" +
    "}\n"

  // Writes go through a temp file in the same dir so a half-written config
  // never becomes visible to the status poll, and 600 is set before the
  // private key is in place.
  readonly property string importPrepareScript:
    "set -e\n" +
    "mkdir -p \"$cfgdir\"\n" +
    "umask 077\n" +
    "tmp=\"$(mktemp \"$cfgdir/.$name.XXXXXX\")\"\n" +
    "trap 'rm -f \"$tmp\"' EXIT\n"

  // Runs only once the new config has passed wg_check: overwriting a live
  // config takes the interface down first (otherwise a later `down` would
  // run against a file that no longer describes the running tunnel), and a
  // rejected import must not cost you the tunnel you already had.
  readonly property string importInstallScript:
    "chmod 600 \"$tmp\"\n" +
    "if ip link show \"$name\" >/dev/null 2>&1; then\n" +
    "  sudo -n wg-quick down \"$cfgdir/$name.conf\" >/dev/null 2>&1 || true\n" +
    "fi\n" +
    "mv -- \"$tmp\" \"$cfgdir/$name.conf\"\n" +
    "trap - EXIT\n"

  readonly property string importFileScript:
    checkScript +
    "cfgdir=\"$1\"; src=\"$2\"; name=\"$3\"\n" +
    "if [ ! -f \"$src\" ]; then echo \"No such file: $src\" >&2; exit 1; fi\n" +
    "wg_check \"$src\" || exit 1\n" +
    importPrepareScript +
    "cat -- \"$src\" > \"$tmp\"\n" +
    importInstallScript

  readonly property string importTextScript:
    checkScript +
    "cfgdir=\"$1\"; name=\"$2\"; text=\"$3\"\n" +
    // Both sources hand back text that already ends in a newline; printf
    // adds one of its own, so trim first and the file doesn't grow a blank
    // line every time it's saved.
    "while [ -n \"$text\" ] && [ \"${text: -1}\" = $'\\n' ]; do text=\"${text%$'\\n'}\"; done\n" +
    importPrepareScript +
    "printf '%s\\n' \"$text\" > \"$tmp\"\n" +
    "wg_check \"$tmp\" || exit 1\n" +
    importInstallScript

  // Exit 2 means "no picker installed" — distinct from the user pressing
  // Cancel, which every one of these exits non-zero for.
  readonly property string pickScript:
    "if command -v zenity >/dev/null 2>&1; then\n" +
    "  exec zenity --file-selection --title='Import WireGuard config' \\\n" +
    "    --file-filter='WireGuard config | *.conf' --file-filter='All files | *'\n" +
    "elif command -v kdialog >/dev/null 2>&1; then\n" +
    "  exec kdialog --getopenfilename \"$HOME\" '*.conf|WireGuard config'\n" +
    "elif command -v yad >/dev/null 2>&1; then\n" +
    "  exec yad --file --title='Import WireGuard config'\n" +
    "fi\n" +
    "exit 2\n"

  // Exit codes: 2 = no zenity, 3 = Cancel, 4 = saved with no changes.
  // The compare happens here so an unchanged save doesn't cycle a live
  // tunnel just because the dialog was dismissed with OK.
  readonly property string editScript:
    "cfgdir=\"$1\"; name=\"$2\"; seed=\"$3\"\n" +
    "src=\"$cfgdir/$name.conf\"\n" +
    "[ -f \"$src\" ] || { echo \"No such config: $name\" >&2; exit 1; }\n" +
    "command -v zenity >/dev/null 2>&1 || exit 2\n" +
    "umask 077\n" +
    "tmp=\"$(mktemp)\"; buf=\"$(mktemp)\"\n" +
    "trap 'rm -f \"$tmp\" \"$buf\"' EXIT\n" +
    // Editing a retry starts from the rejected text; a fresh edit starts
    // from the file. Either way the change check compares against disk.
    "if [ -n \"$seed\" ]; then printf '%s\\n' \"$seed\" > \"$buf\"; else cat -- \"$src\" > \"$buf\"; fi\n" +
    "zenity --text-info --editable --filename=\"$buf\" \\\n" +
    "  --title=\"Edit $name.conf\" --width=700 --height=560 > \"$tmp\" || exit 3\n" +
    "cmp -s \"$tmp\" \"$src\" && exit 4\n" +
    "cat -- \"$tmp\"\n"

  readonly property string clipboardScript:
    "command -v wl-paste >/dev/null 2>&1 || exit 2\n" +
    "wl-paste --no-newline --type text/plain 2>/dev/null || wl-paste --no-newline\n"

  property string _controlError: ""
  property string _pendingConnect: ""
  property string _editTarget: ""
  property bool _editWasActive: false
  // Last edited text and its config, kept only until the write is known to
  // have succeeded.
  property string _editRetryName: ""
  property string _editRetryText: ""
  // Config to bring back up once the current control run finishes.
  property string _reconnectAfter: ""

  FileView {
    path: root.lastFile
    printErrors: false
    onLoaded: {
      var value = String(text() || "").trim()
      if (value !== "" && root.lastConnected === "") root.lastConnected = value
    }
  }

  Timer {
    id: editRetryTimer
    interval: 60
    repeat: false
    onTriggered: {
      var name = root._editRetryName
      var text = root._editRetryText
      root._editRetryName = ""
      root._editRetryText = ""
      root.editConfig(name, text)
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: ["bash", "-c", root.statusScript, "wireguard", root.configsDir]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusStdout.text)
    }
  }

  // Kept out of runControl: these return data rather than pass/fail, and a
  // file dialog can sit open for a while — `busy` would freeze the panel.
  Process {
    id: pickerProcess
    running: false
    command: ["bash", "-c", root.pickScript, "wireguard"]
    stdout: StdioCollector {
      id: pickerStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "No file picker found — install zenity, kdialog or yad"
        return
      }
      // Anything else non-zero is Cancel; say nothing.
      if (exitCode !== 0) return
      var path = String(pickerStdout.text || "").trim()
      if (path !== "") root.importReady("file", path, root.sanitizeName(path))
    }
  }

  Process {
    id: editProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: editStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var target = root._editTarget
      var wasActive = root._editWasActive
      root._editTarget = ""
      root._editWasActive = false
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "zenity is not installed"
        return
      }
      // 3 = Cancel, 4 = nothing changed; neither is worth a message.
      if (exitCode !== 0) {
        if (exitCode !== 3 && exitCode !== 4) root.lastError = "Could not open " + target + ".conf"
        return
      }
      var text = String(editStdout.text || "")
      if (!root.looksLikeConfig(text)) {
        root.retryEdit(target, text, "Not saved: that is not a WireGuard config")
        return
      }
      if (wasActive) root._reconnectAfter = target
      // Held so a rejected save can be handed back to the editor instead of
      // being thrown away.
      root._editRetryName = target
      root._editRetryText = text
      root.importText(text, target)
    }
  }

  Process {
    id: clipboardProcess
    running: false
    command: ["bash", "-c", root.clipboardScript, "wireguard"]
    stdout: StdioCollector {
      id: clipboardStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "wl-clipboard is not installed"
        return
      }
      var text = String(clipboardStdout.text || "")
      if (!root.looksLikeConfig(text)) {
        root.lastError = "Clipboard does not contain a WireGuard config"
        return
      }
      root.importReady("text", text, root.suggestName())
    }
  }

  Process {
    id: saveProcess
    running: false
    command: []
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
      onStreamFinished: root._controlError = text
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        if (root._pendingConnect !== "") root.rememberLast(root._pendingConnect)
        root.lastError = ""
        root.actionStatus = ""
        root._editRetryName = ""
        root._editRetryText = ""
      } else {
        root.actionStatus = ""
        root._reconnectAfter = ""
        var reason = root.elide(root._controlError || "wg-quick failed")
        // A write refused by wg_check must not cost the edit that produced
        // it; hand the text back to the editor with the reason attached.
        if (root._editRetryName !== "") root.retryEdit(root._editRetryName, root._editRetryText, reason)
        else root.lastError = reason
      }
      root._pendingConnect = ""
      root.refresh()
      // An edit of a live config took the tunnel down to rewrite the file;
      // put it back on the new config. Deferred because runControl refuses
      // to start while this process is still winding down.
      if (root._reconnectAfter !== "") {
        var target = root._reconnectAfter
        root._reconnectAfter = ""
        Qt.callLater(function() { root.connectTo(target) })
      }
    }
  }
}
