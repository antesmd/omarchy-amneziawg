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

  // NetworkManager's wireguard profiles as {uuid, name, active}, sorted by
  // name. Every control operation addresses a profile by UUID, because
  // NetworkManager permits duplicate names — a name is a label here, never
  // an address.
  property var profiles: []
  // Names of the wireguard profiles currently active
  readonly property var activeNames: {
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active) out.push(profiles[i].name)
    }
    return out
  }
  readonly property bool active: activeNames.length > 0
  // Most recently connected config, persisted across restarts so the
  // hero toggle reconnects what you actually used last.
  property string lastConnected: ""
  property string actionStatus: ""
  property string lastError: ""

  readonly property bool busy: controlProcess.running
  readonly property string statusText: active ? "VPN: " + activeNames.join(" ") : "VPN disconnected"
  // What toggle() would bring up: last used config if it still exists,
  // otherwise the first one.
  readonly property string toggleTarget: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === lastConnected) return lastConnected
    }
    return profiles.length > 0 ? profiles[0].name : ""
  }

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

  // First profile with this name, or null. Only for the name-based entry
  // points (import replace, IPC) — with duplicate names this is a guess,
  // and everything row-bound carries its own profile object instead.
  function findByName(name) {
    var value = String(name || "")
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === value) return profiles[i]
    }
    return null
  }

  function applyStatus(raw) {
    var lines = String(raw || "").split("\n")
    var sep = lines.indexOf("---")
    if (sep === -1) {
      lastError = "Failed to read WireGuard status"
      return
    }
    var list = []
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
      var entry = {
        uuid: line.slice(0, first),
        name: line.slice(first + 1, last).replace(/\\:/g, ":").replace(/\\\\/g, "\\"),
        active: false
      }
      list.push(entry)
      byUuid[entry.uuid] = entry
    }
    list.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    var firstUp = ""
    for (var j = sep + 1; j < lines.length; j++) {
      var uuid = lines[j].trim()
      if (uuid === "" || byUuid[uuid] === undefined) continue
      byUuid[uuid].active = true
      if (firstUp === "") firstUp = byUuid[uuid].name
    }
    profiles = list
    // Track connects made outside the widget too (nmcli, GUI).
    if (firstUp !== "") rememberLast(firstUp)
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

  function connectTo(profile) {
    if (busy || !profile || !profile.uuid) return
    actionStatus = "Connecting " + profile.name + "…"
    _pendingConnect = String(profile.name)
    runControl(["connect", profile.uuid])
  }

  function disconnectOne(profile) {
    if (busy || !profile || !profile.uuid) return
    actionStatus = "Disconnecting " + profile.name + "…"
    runControl(["down", profile.uuid])
  }

  function disconnectAll() {
    if (busy) return
    actionStatus = "Disconnecting…"
    runControl(["down-all"])
  }

  function deleteConfig(profile) {
    if (busy || !profile || !profile.uuid) return
    actionStatus = "Deleting " + profile.name + "…"
    runControl(["delete", profile.uuid])
  }

  function toggle() {
    if (active) disconnectAll()
    else if (toggleTarget !== "") connectTo(findByName(toggleTarget))
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
  // Saving goes back through import, so an edit gets the same parsing and
  // validation as an import. Whether the tunnel comes back up is the
  // backend's call, made inside the replace transaction from what is active
  // at that moment — not from a snapshot taken when the editor opened.
  // `seedText` reopens the editor on text that was rejected rather than on
  // what is stored, so a refused save costs a keystroke to fix instead of
  // the whole edit.
  function editConfig(profile, seedText) {
    if (!profile || !profile.uuid || editProcess.running) return
    _editUuid = String(profile.uuid)
    _editName = String(profile.name)
    if (!seedText) lastError = ""
    actionStatus = "Editing " + _editName + "…"
    // The seed goes over stdin — it is config text with a private key in it,
    // and argv is world-readable via /proc.
    _editSeed = String(seedText || "")
    editProcess.stdinEnabled = true
    editProcess.command = ["bash", backendPath, "edit", _editUuid, _editName]
    editProcess.running = true
  }

  // Puts rejected text back in front of the user with the reason showing.
  // Deferred through a timer because the editor process that produced the
  // text is still winding down when the rejection lands.
  function retryEdit(uuid, name, text, message) {
    lastError = message
    _editRetryUuid = String(uuid)
    _editRetryName = String(name)
    _editRetryText = String(text)
    editRetryTimer.restart()
  }

  function importFile(path, name) {
    if (busy || !path || !name) return
    var existing = findByName(name)
    actionStatus = "Importing " + name + "…"
    runControl(["import", String(name), existing ? existing.uuid : "", String(path)])
  }

  // Writes a queued editor save once controlProcess is free. Bypasses
  // importText's silent busy-guard on purpose: by the time the text exists
  // the user has already committed the edit, so it either writes now or
  // stays queued — it never just disappears.
  function _flushPendingSave() {
    if (_pendingSaveUuid === "" || busy) return
    var uuid = _pendingSaveUuid
    var name = _pendingSaveName
    var text = _pendingSaveText
    _pendingSaveUuid = ""
    _pendingSaveName = ""
    _pendingSaveText = ""
    // Held so a rejected save can be handed back to the editor instead of
    // being thrown away.
    _editRetryUuid = uuid
    _editRetryName = name
    _editRetryText = text
    actionStatus = "Saving " + name + "…"
    runControl(["import", name, uuid], text)
  }

  function importText(text, name) {
    if (busy || !text || !name) return
    var existing = findByName(name)
    actionStatus = "Importing " + name + "…"
    runControl(["import", String(name), existing ? existing.uuid : ""], String(text))
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
      if (!findByName("wg" + i)) return "wg" + i
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
  property string _editUuid: ""
  property string _editName: ""
  property string _editSeed: ""
  // Edited text waiting for controlProcess to free up. The editor can close
  // while another operation runs (busy only gates controlProcess); a save
  // must queue, not silently vanish.
  property string _pendingSaveUuid: ""
  property string _pendingSaveName: ""
  property string _pendingSaveText: ""
  // Last edited text and its config, kept only until the write is known to
  // have succeeded.
  property string _editRetryUuid: ""
  property string _editRetryName: ""
  property string _editRetryText: ""

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
      var uuid = root._editRetryUuid
      var name = root._editRetryName
      var text = root._editRetryText
      root._editRetryUuid = ""
      root._editRetryName = ""
      root._editRetryText = ""
      root.editConfig({ uuid: uuid, name: name }, text)
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
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // A failed poll must not read as "disconnected" — keep the last known
      // state and say why it could not be refreshed.
      if (exitCode === 0) root.applyStatus(statusStdout.text)
      else root.lastError = root.elide(statusStderr.text || "Failed to read WireGuard status")
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
      var uuid = root._editUuid
      var name = root._editName
      root._editUuid = ""
      root._editName = ""
      root.actionStatus = ""
      if (exitCode === 2) {
        root.lastError = "zenity is not installed"
        return
      }
      // 3 = Cancel, 4 = nothing changed; neither is worth a message.
      if (exitCode !== 0) {
        if (exitCode !== 3 && exitCode !== 4) root.lastError = "Could not open " + name
        return
      }
      var text = String(editStdout.text || "")
      if (!root.looksLikeConfig(text)) {
        root.retryEdit(uuid, name, text, "Not saved: that is not a WireGuard config")
        return
      }
      // Queued rather than written directly: busy only gates controlProcess,
      // so another operation may be mid-flight right now. The queue drains
      // from controlProcess.onExited — the save waits its turn instead of
      // being dropped.
      root._pendingSaveUuid = uuid
      root._pendingSaveName = name
      root._pendingSaveText = text
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
        root._editRetryUuid = ""
        root._editRetryName = ""
        root._editRetryText = ""
      } else {
        root.actionStatus = ""
        var reason = root.elide(root._controlError || "NetworkManager operation failed")
        // A write refused by wg_check must not cost the edit that produced
        // it; hand the text back to the editor with the reason attached.
        if (root._editRetryName !== "") root.retryEdit(root._editRetryUuid, root._editRetryName, root._editRetryText, reason)
        else root.lastError = reason
      }
      root._pendingConnect = ""
      root.refresh()
      // A save queued while this operation ran; write it now.
      if (root._pendingSaveUuid !== "") Qt.callLater(root._flushPendingSave)
    }
  }
}
