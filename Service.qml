import QtQuick
import Quickshell
import Quickshell.Io

// Headless state for the WireGuard widget: lists WireGuard connection
// profiles in NetworkManager, tracks which are active, and activates or
// deactivates them through backend.sh (nmcli over D-Bus, authorized by
// polkit — no sudo, no root shell, config hooks never run).
Item {
  id: root

  property var settings: ({})

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string lastFile: stateDir + "/wireguard-last"
  readonly property string backendPath: String(Qt.resolvedUrl("backend.sh")).replace(/^file:\/\//, "")

  // Connection names of NetworkManager's wireguard profiles, sorted
  property var configs: []
  // name -> profile UUID; all control operations address profiles by UUID
  // because NetworkManager permits duplicate names
  property var uuidByName: ({})
  // Names of the wireguard profiles currently active
  property var activeConnections: []
  readonly property bool active: activeConnections.length > 0
  // Most recently connected config, persisted across restarts so the
  // hero toggle reconnects what you actually used last.
  property string lastConnected: ""
  property string actionStatus: ""
  property string lastError: ""

  readonly property bool busy: controlProcess.running
  readonly property string statusText: active ? "VPN: " + activeConnections.join(" ") : "VPN disconnected"
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
    return activeConnections.indexOf(String(name)) !== -1
  }

  function applyStatus(raw) {
    var lines = String(raw || "").split("\n")
    var sep = lines.indexOf("---")
    if (sep === -1) {
      lastError = "Failed to read WireGuard status"
      return
    }
    var names = []
    var byName = {}
    var byUuid = {}
    for (var i = 0; i < sep; i++) {
      // uuid:name:type — the UUID contains no colons and the type is the
      // last field, so the name is everything in between; nmcli -t escapes
      // colons inside it as "\:".
      var line = lines[i]
      var first = line.indexOf(":")
      var last = line.lastIndexOf(":")
      if (first === -1 || last <= first) continue
      if (line.slice(last + 1) !== "wireguard") continue
      var name = line.slice(first + 1, last).replace(/\\:/g, ":").replace(/\\\\/g, "\\")
      names.push(name)
      byName[name] = line.slice(0, first)
      byUuid[line.slice(0, first)] = name
    }
    names.sort()
    var up = []
    for (var j = sep + 1; j < lines.length; j++) {
      var uuid = lines[j].trim()
      if (uuid !== "" && byUuid[uuid] !== undefined) up.push(byUuid[uuid])
    }
    configs = names
    uuidByName = byName
    activeConnections = up
    // Track connects made outside the widget too (nmcli, GUI).
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
    var uuid = uuidByName[String(name)]
    if (!uuid) return
    actionStatus = "Connecting " + name + "…"
    _pendingConnect = String(name)
    runControl(["connect", uuid])
  }

  function disconnectOne(name) {
    if (busy || !name) return
    var uuid = uuidByName[String(name)]
    if (!uuid) return
    actionStatus = "Disconnecting " + name + "…"
    runControl(["down", uuid])
  }

  function disconnectAll() {
    if (busy) return
    actionStatus = "Disconnecting…"
    runControl(["down-all"])
  }

  function deleteConfig(name) {
    if (busy || !name) return
    var uuid = uuidByName[String(name)]
    if (!uuid) return
    actionStatus = "Deleting " + name + "…"
    runControl(["delete", uuid])
  }

  function toggle() {
    if (active) disconnectAll()
    else if (toggleTarget !== "") connectTo(toggleTarget)
  }

  // Import: a picked file or pasted text becomes an NM connection profile,
  // and the status poll picks it up on the next tick.
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

  // Opens the profile as wg-quick text in zenity's editable view (the
  // backend reconstructs the text from NetworkManager, secrets included).
  // Saving goes back through importText, so an edit gets the same parsing
  // and validation as an import — and a tunnel that was up when you
  // started editing is brought back up on the new profile.
  // `seedText` reopens the editor on text that was rejected rather than on
  // what is stored, so a refused save costs a keystroke to fix instead of
  // the whole edit.
  function editConfig(name, seedText) {
    if (!name || editProcess.running) return
    var uuid = uuidByName[String(name)]
    if (!uuid) return
    _editTarget = String(name)
    _editWasActive = isActive(name)
    if (!seedText) lastError = ""
    actionStatus = "Editing " + name + "…"
    // The seed goes over stdin — it is config text with a private key in it,
    // and argv is world-readable via /proc.
    _editSeed = String(seedText || "")
    editProcess.stdinEnabled = true
    editProcess.command = ["bash", backendPath, "edit", uuid, String(name)]
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
    runControl(["import", String(name), uuidByName[String(name)] || "", String(path)])
  }

  // Writes a queued editor save once controlProcess is free. Bypasses
  // importText's silent busy-guard on purpose: by the time the text exists
  // the user has already committed the edit, so it either writes now or
  // stays queued — it never just disappears.
  function _flushPendingSave() {
    if (_pendingSaveName === "" || busy) return
    var name = _pendingSaveName
    var text = _pendingSaveText
    _pendingSaveName = ""
    _pendingSaveText = ""
    if (_pendingSaveReconnect) _reconnectAfter = name
    _pendingSaveReconnect = false
    // Held so a rejected save can be handed back to the editor instead of
    // being thrown away.
    _editRetryName = name
    _editRetryText = text
    actionStatus = "Importing " + name + "…"
    runControl(["import", name, uuidByName[name] || ""], text)
  }

  function importText(text, name) {
    if (busy || !text || !name) return
    actionStatus = "Importing " + name + "…"
    runControl(["import", String(name), uuidByName[String(name)] || ""], String(text))
  }

  // The connection (and interface) is named after the file, and the kernel
  // caps interface names at 15 chars from [A-Za-z0-9_=+.-] — provider
  // configs ("US-New York 03.conf") routinely break both rules.
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

  // Config text rides on stdin, never in argv: anything in the command line
  // is world-readable through /proc/<pid>/cmdline for as long as the process
  // lives, and config text contains the private key.
  function runControl(args, stdinData) {
    _controlError = ""
    _controlStdin = stdinData === undefined ? "" : String(stdinData)
    controlProcess.stdinEnabled = true
    controlProcess.command = ["bash", backendPath].concat(args)
    controlProcess.running = true
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  // Everything that touches NetworkManager lives in backend.sh — status,
  // connect, down, delete, import (with the wg-quick parser) and the
  // editor round-trip. Only the desktop-integration helpers below stay
  // inline.

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

  readonly property string clipboardScript:
    "command -v wl-paste >/dev/null 2>&1 || exit 2\n" +
    "wl-paste --no-newline --type text/plain 2>/dev/null || wl-paste --no-newline\n"

  property string _controlError: ""
  property string _controlStdin: ""
  property string _pendingConnect: ""
  property string _editTarget: ""
  property bool _editWasActive: false
  property string _editSeed: ""
  // Edited text waiting for controlProcess to free up. The editor can close
  // while another operation runs (busy only gates controlProcess); a save
  // must queue, not silently vanish.
  property string _pendingSaveName: ""
  property string _pendingSaveText: ""
  property bool _pendingSaveReconnect: false
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
      // Still winding down — try again rather than let editConfig's guard
      // silently swallow the retry text.
      if (editProcess.running) {
        editRetryTimer.restart()
        return
      }
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
    command: ["bash", root.backendPath, "status"]
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
    stdinEnabled: false
    onStarted: {
      if (root._editSeed !== "") write(root._editSeed)
      root._editSeed = ""
      stdinEnabled = false
    }
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
        if (exitCode !== 3 && exitCode !== 4) root.lastError = "Could not open " + target
        return
      }
      var text = String(editStdout.text || "")
      if (!root.looksLikeConfig(text)) {
        root.retryEdit(target, text, "Not saved: that is not a WireGuard config")
        return
      }
      // Queued rather than written directly: busy only gates controlProcess,
      // so another operation may be mid-flight right now. The queue drains
      // from controlProcess.onExited — the save waits its turn instead of
      // being dropped.
      root._pendingSaveName = target
      root._pendingSaveText = text
      root._pendingSaveReconnect = wasActive
      Qt.callLater(root._flushPendingSave)
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
    stdinEnabled: false
    onStarted: {
      if (root._controlStdin !== "") write(root._controlStdin)
      root._controlStdin = ""
      stdinEnabled = false
    }
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
        var reason = root.elide(root._controlError || "NetworkManager operation failed")
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
      } else if (root._pendingSaveName !== "") {
        // A save queued while this operation ran; write it now.
        Qt.callLater(root._flushPendingSave)
      }
    }
  }
}
