import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "glafeara.wireguard"
  ipcTarget: "glafeara.wireguard"
  manageIpc: false

  property string focusSection: "header"
  property int configIndex: 0
  property bool cursorActive: false
  // Profile ({uuid, name}) awaiting delete confirmation; non-null opens the
  // dialog. A profile object, not a name — names are not unique.
  property var pendingDelete: null
  // Incoming config awaiting a name; "file" | "text" | "" (no prompt open).
  property string importKind: ""
  property string importPayload: ""
  // Profile ({uuid, name}) awaiting a new display name; non-null while the
  // rename dialog is open.
  property var pendingRename: null
  // Profile whose pencil was clicked — the chooser asks whether to edit
  // the config or the name; keyboard users go straight there with e / n.
  property var pendingEdit: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: wireguard.active ? foreground : dim
  // Urgent trumps everything: a failed operation or an externally dropped
  // tunnel must be visible without opening the panel.
  readonly property color barIconColor: wireguard.lastError !== ""
    ? (bar ? bar.urgent : Color.urgent)
    : (wireguard.active ? barForeground : Qt.darker(barForeground, 1.55))
  readonly property string toggleHint: wireguard.active
    ? "Disconnect"
    : (wireguard.toggleTarget !== "" ? "Connect " + wireguard.toggleTarget : "Connect")
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && wireguard.profiles.length > 0

  readonly property string importNameClean: importDialog.value.trim()
  readonly property bool importNameValid: wireguard.isValidName(importNameClean)
  // Matching is by configured interface-name: rename can move the display
  // name anywhere, but the interface is what a re-import collides with.
  readonly property int importNameCount: importNameValid ? wireguard.countByIfname(importNameClean) : 0
  readonly property bool importReplaces: importNameCount === 1
  // Several existing profiles use the typed interface — "replace" cannot
  // know which one is meant, so the import is refused under this name.
  readonly property bool importAmbiguous: importNameCount > 1
  readonly property bool importAccepted: importNameValid && !importAmbiguous
  readonly property var importReplaceTarget: importReplaces ? wireguard.findByIfname(importNameClean) : null
  readonly property string importSourceLabel: importKind === "text"
    ? "Import from clipboard"
    : "Import " + String(importPayload).split("/").pop()
  readonly property string importHintText: !importNameValid
    ? "Up to 15 characters: letters, digits and . _ - = +"
    : (importAmbiguous
      ? importNameCount + " profiles use the interface " + importNameClean + " — pick another name"
      : (importReplaces
        ? "Replaces the existing connection " + (importReplaceTarget ? importReplaceTarget.name : importNameClean)
        : "Imports as NetworkManager connection " + importNameClean))

  // Rename touches connection.id only — a free-form label, so spaces are
  // fine. Duplicates are refused: every name-based entry point in the
  // widget treats an ambiguous name as an error, so don't let one be made.
  readonly property string renameClean: renameDialog.value.trim()
  readonly property bool renameDuplicate: renameClean !== ""
    && (pendingRename === null || renameClean !== pendingRename.name)
    && wireguard.countByName(renameClean) > 0
  readonly property bool renameAccepted: pendingRename !== null && renameClean !== "" && !renameDuplicate
  readonly property string renameHint: renameClean === ""
    ? "The name must not be empty"
    : (renameDuplicate
      ? "A profile named " + renameClean + " already exists"
      : "Display name only — the interface name does not change")

  function ensureCursor() {
    if (wireguard.profiles.length === 0) {
      focusSection = "header"
      configIndex = 0
      return
    }
    if (focusSection !== "configs" && focusSection !== "header") focusSection = "configs"
    if (configIndex >= wireguard.profiles.length) configIndex = Math.max(0, wireguard.profiles.length - 1)
    if (configIndex < 0) configIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0 && wireguard.profiles.length > 0) {
        focusSection = "configs"
        configIndex = 0
        scrollCursorIntoView()
      }
      return
    }
    if (focusSection === "configs") {
      if (dy < 0 && configIndex === 0) {
        setHeaderCursor()
        return
      }
      configIndex = Math.max(0, Math.min(wireguard.profiles.length - 1, configIndex + dy))
      scrollCursorIntoView()
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
  }

  function setConfigCursor(index) {
    cursorActive = true
    focusSection = "configs"
    configIndex = index
    scrollCursorIntoView()
  }

  function selectedProfile() {
    if (wireguard.profiles.length === 0) return null
    return wireguard.profiles[Math.max(0, Math.min(configIndex, wireguard.profiles.length - 1))]
  }

  function activateConfig(profile) {
    if (wireguard.busy || !profile) return
    if (profile.active) wireguard.disconnectOne(profile)
    else wireguard.connectTo(profile)
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") wireguard.toggle()
    else if (focusSection === "configs") activateConfig(selectedProfile())
  }

  function requestDelete(profile) {
    if (wireguard.busy || !profile) return
    pendingDelete = profile
  }

  function beginImport(kind, payload, suggested) {
    importKind = String(kind)
    importPayload = String(payload)
    // A sanitized provider filename can come back empty ("~/VPN (1).conf");
    // fall back to a free wgN rather than opening the prompt on nothing.
    importDialog.openWith(suggested !== "" ? String(suggested) : wireguard.suggestName())
  }

  function cancelImport() {
    importKind = ""
    importPayload = ""
    importDialog.dismiss()
  }

  function requestEdit(profile) {
    if (wireguard.busy || !profile) return
    pendingEdit = profile
  }

  function confirmEdit(kind) {
    var profile = pendingEdit
    pendingEdit = null
    if (!profile || kind === "") return
    if (kind === "name") requestRename(profile)
    else wireguard.editConfig(profile, "")
  }

  function requestRename(profile) {
    if (wireguard.busy || !profile) return
    pendingRename = profile
    renameDialog.openWith(profile.name)
  }

  function cancelRename() {
    pendingRename = null
    renameDialog.dismiss()
  }

  function confirmRename() {
    if (!renameAccepted) return
    var profile = pendingRename
    var name = renameClean
    cancelRename()
    wireguard.renameConfig(profile, name)
  }

  function confirmImport() {
    if (!importAccepted) return
    var kind = importKind
    var payload = importPayload
    var name = importNameClean
    cancelImport()
    if (kind === "file") wireguard.importFile(payload, name)
    else if (kind === "text") wireguard.importText(payload, name)
  }

  function scrollCursorIntoView() {
    if (focusSection !== "configs" || !configRepeater) return
    // itemAt, not configColumn.children[i]: the Repeater itself sits in the
    // children list ahead of its delegates, so raw indexing is off by one.
    var item = configRepeater.itemAt(configIndex)
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    pendingDelete = null
    pendingEdit = null
    wireguard.closeQr()
    cancelImport()
    cancelRename()
    if (opened) {
      cursorActive = false
      if (panelFlick) panelFlick.contentY = 0
      wireguard.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onConfigIndexChanged: scrollCursorIntoView()

  Service {
    id: wireguard
    settings: root.settings
    trafficMonitoring: root.opened
  }

  Connections {
    target: wireguard
    function onProfilesChanged() { root.ensureCursor() }
    // The picker runs whether or not the popup is open (bar right-click,
    // IPC); open the popup so the name prompt has somewhere to appear.
    function onImportReady(kind, payload, suggestedName) {
      if (!root.opened) root.open()
      root.beginImport(kind, payload, suggestedName)
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    // VPN toggle, not panel visibility — open/close/show/hide already cover
    // the popup, and the bar's left click promises the same thing.
    function toggle(): void { wireguard.toggle() }
    function refresh(): string { wireguard.refresh(); return "ok" }
    function down(): string { wireguard.disconnectAll(); return "ok" }
    function status(): string { return wireguard.statusText }
    // Headless import — no prompt, the name is derived from the filename.
    // (`import` is a JS keyword, hence the longer name.)
    function importConfig(path: string): string {
      var name = wireguard.sanitizeName(path)
      if (!wireguard.isValidName(name)) return "error: cannot derive an interface name from " + path
      if (wireguard.countByIfname(name) > 1) return "error: ambiguous: several profiles use the interface " + name
      wireguard.importFile(path, name)
      return name
    }
    // Takes a connection name or a profile UUID; a name shared by several
    // profiles is refused rather than resolved to an arbitrary one.
    function edit(target: string): string {
      var profile = wireguard.findByUuid(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use a UUID: " + wireguard.uuidsForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      wireguard.editConfig(profile, "")
      return "ok"
    }
    // Same target resolution as edit; the new name is a display label, so
    // anything single-line goes — except a name another profile already
    // holds, which would poison every name-based entry point.
    function rename(target: string, newName: string): string {
      var profile = wireguard.findByUuid(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use a UUID: " + wireguard.uuidsForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      var value = String(newName || "").trim()
      if (value === "") return "error: the new name must not be empty"
      if (value !== profile.name && wireguard.countByName(value) > 0) return "error: a profile named " + value + " already exists"
      wireguard.renameConfig(profile, value)
      return "ok"
    }
    function importPick(): string { wireguard.pickConfigFile(); return "ok" }
    function importPaste(): string { wireguard.pasteConfig(); return "ok" }
    // Headless export — no warning dialog: an explicit path in argv is
    // already deliberate in a way a panel click is not. The file lands 0600.
    function exportConfig(target: string, path: string): string {
      var profile = wireguard.findByUuid(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use a UUID: " + wireguard.uuidsForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      if (String(path || "") === "") return "error: no destination path"
      wireguard.exportToPath(profile, path)
      return "ok"
    }
    // The QR dialog lives inside the panel, so showing it implies opening.
    function qr(target: string): string {
      var profile = wireguard.findByUuid(target)
      if (!profile) {
        var n = wireguard.countByName(target)
        if (n === 0) return "error: no such config: " + target
        if (n > 1) return "error: ambiguous name: " + target + " — use a UUID: " + wireguard.uuidsForName(target).join(" ")
        profile = wireguard.findByName(target)
      }
      root.open()
      wireguard.showQr(profile)
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The vpn glyph, not the mark: at the bar's 13px the dragon loses its
    // head. The real logo lives in the panel header, where it has room.
    text: "󰖂"
    // No tooltip on hover: the icon itself is the status display — full
    // brightness while a tunnel is up, dimmed while disconnected.
    foreground: root.barIconColor
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (wireguard.active) wireguard.disconnectAll()
        else root.open()
      } else if (buttonCode === Qt.MiddleButton) {
        wireguard.refresh()
      } else {
        // Left click opens/closes the panel — the VPN toggle lives on the
        // hero switch, the `t` key, and the IPC `toggle` command.
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.pendingDelete !== null || root.pendingEdit !== null || qrDialog.visible || importDialog.visible || renameDialog.visible
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: {
        if (root.cursorActive && root.focusSection === "configs") root.requestDelete(root.selectedProfile())
      }
      onTextKey: function(t) {
        if (t === "t" || t === "T") wireguard.toggle()
        else if (t === "r" || t === "R") wireguard.refresh()
        else if (t === "d" || t === "D") wireguard.disconnectAll()
        else if (t === "i" || t === "I") wireguard.pickConfigFile()
        else if (t === "v" || t === "V") wireguard.pasteConfig()
        else if (t === "e" || t === "E") {
          if (root.cursorActive && root.focusSection === "configs") wireguard.editConfig(root.selectedProfile(), "")
        }
        else if (t === "n" || t === "N") {
          if (root.cursorActive && root.focusSection === "configs") root.requestRename(root.selectedProfile())
        }
        else if (t === "q" || t === "Q") {
          if (root.cursorActive && root.focusSection === "configs") wireguard.showQr(root.selectedProfile())
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "WireGuard"
              meta: wireguard.active ? "Connected: " + wireguard.activeNames.join(", ") : "Disconnected"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: wireguard.active ? 1.0 : 0.5
              // The real mark rather than a glyph: at display size the
              // dragon actually reads. The bar keeps the vpn glyph, where
              // 13px would reduce this to a blob.
              iconComponent: Component {
                WireGuardIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: wireguard.profiles.length > 0
                  checked: wireguard.active
                  busy: wireguard.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: wireguard.toggle()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: wireguard.actionStatus !== "" || wireguard.lastError !== ""
            width: parent.width
            text: wireguard.actionStatus !== "" ? wireguard.actionStatus : wireguard.lastError
            color: wireguard.lastError !== "" && wireguard.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(sectionLabel.implicitHeight, importActions.implicitHeight)

              PanelSectionHeader {
                id: sectionLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "CONFIGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                id: importActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "Import a .conf file (i)"
                  foreground: root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !wireguard.busy
                  onClicked: wireguard.pickConfigFile()
                }

                PanelActionButton {
                  iconText: "󰅌"
                  tooltipText: "Import from clipboard (v)"
                  foreground: root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !wireguard.busy
                  onClicked: wireguard.pasteConfig()
                }
              }
            }

            Text {
              visible: wireguard.profiles.length === 0
              width: parent.width
              text: "No WireGuard connections in NetworkManager\nImport a .conf with + or paste one with v"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WrapAnywhere
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: configColumn
              visible: wireguard.profiles.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: configRepeater
                model: wireguard.profiles
                ConfigRow {
                  required property var modelData
                  required property int index
                  width: configColumn.width
                  profile: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }

      // Name prompt for an incoming config, shared by both import paths.
      // The interface name is derived from the filename, so the name
      // is the one thing neither a picked file nor pasted text can supply
      // reliably — and it doubles as the replace-or-not decision.
      NamePrompt {
        id: importDialog
        anchors.fill: parent
        title: root.importSourceLabel
        placeholder: "Interface name"
        hint: root.importHintText
        accepted: root.importAccepted
        confirmLabel: root.importReplaces ? "Replace" : "Import"
        onConfirmed: root.confirmImport()
        onCanceled: root.cancelImport()
      }

      NamePrompt {
        id: renameDialog
        anchors.fill: parent
        title: "Rename " + (root.pendingRename ? root.pendingRename.name : "")
        placeholder: "Connection name"
        hint: root.renameHint
        accepted: root.renameAccepted
        confirmLabel: "Rename"
        onConfirmed: root.confirmRename()
        onCanceled: root.cancelRename()
      }

      // One pencil, two targets: the chooser splits "edit" into the config
      // text (zenity round-trip) and the display name (rename prompt).
      // Keyboard users never see it — e and n go straight to either.
      Item {
        id: editChooser
        anchors.fill: parent
        visible: root.pendingEdit !== null

        property int selectedIndex: 1
        readonly property var choices: [
          { label: "Cancel", kind: "" },
          { label: "Config", kind: "config" },
          { label: "Name", kind: "name" }
        ]

        onVisibleChanged: {
          if (visible) {
            selectedIndex = 1
            editChooser.forceActiveFocus()
          } else if (root.pendingRename === null) {
            // Choosing "Name" hands focus to the rename prompt, not back
            // to the list.
            keyCatcher.forceActiveFocus()
          }
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) root.pendingEdit = null
          else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab)
            selectedIndex = (selectedIndex + choices.length - 1) % choices.length
          else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab)
            selectedIndex = (selectedIndex + 1) % choices.length
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            root.confirmEdit(choices[selectedIndex].kind)
          else if (event.key === Qt.Key_E || event.key === Qt.Key_C) root.confirmEdit("config")
          else if (event.key === Qt.Key_N) root.confirmEdit("name")
          else return
          event.accepted = true
        }

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.7)

          MouseArea { anchors.fill: parent; onClicked: root.pendingEdit = null }

          BorderSurface {
            id: editCard
            width: Math.min(parent.width - Style.space(32), Style.space(340))
            height: editCard.contentTopInset + editCard.contentBottomInset
              + editMessage.implicitHeight + Style.space(20) + Style.space(34)
            anchors.centerIn: parent
            color: Color.background
            borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: Style.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
              anchors.fill: parent
              anchors.topMargin: editCard.contentTopInset
              anchors.rightMargin: editCard.contentRightInset
              anchors.bottomMargin: editCard.contentBottomInset
              anchors.leftMargin: editCard.contentLeftInset

              Text {
                id: editMessage
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: "Edit " + (root.pendingEdit ? root.pendingEdit.name : "") + "?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Row {
                id: editButtonsRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: Style.space(10)

                Repeater {
                  model: editChooser.choices

                  BorderSurface {
                    required property int index
                    required property var modelData

                    readonly property bool selected: editChooser.selectedIndex === index

                    // Three equal shares of the card, not the fixed 88 the
                    // two-button ConfirmDialog gets away with — three of
                    // those overflow this card's width.
                    width: (editButtonsRow.width - Style.space(10) * 2) / 3
                    height: Style.space(34)
                    color: selected ? Util.alpha(Color.foreground, 0.08) : "transparent"
                    borderSpec: Border.flat(selected
                      ? Color.accent
                      : Util.alpha(root.foreground, 0.38), Style.normalBorderWidth)
                    radius: 0

                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: selected ? Color.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: editChooser.selectedIndex = index
                      onClicked: root.confirmEdit(modelData.kind)
                    }
                  }
                }
              }
            }
          }
        }
      }

      // The QR itself is the dialog: no chooser, no confirmation step — the
      // private-key warning rides under the code. Click anywhere or press
      // Esc/q to close; the PNG in XDG_RUNTIME_DIR is deleted on close.
      Item {
        id: qrDialog
        anchors.fill: parent
        visible: wireguard.qrPath !== ""

        onVisibleChanged: {
          if (visible) qrDialog.forceActiveFocus()
          else keyCatcher.forceActiveFocus()
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q
              || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            wireguard.closeQr()
            event.accepted = true
          }
        }

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.7)

          MouseArea { anchors.fill: parent; onClicked: wireguard.closeQr() }

          BorderSurface {
            id: qrCard
            width: Math.min(parent.width - Style.space(48), Style.space(300))
            height: qrCard.contentTopInset + qrCard.contentBottomInset + qrColumn.implicitHeight
            anchors.centerIn: parent
            color: Color.background
            borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: Style.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: wireguard.closeQr() }

            Column {
              id: qrColumn
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.topMargin: qrCard.contentTopInset
              anchors.leftMargin: qrCard.contentLeftInset
              anchors.rightMargin: qrCard.contentRightInset
              spacing: Style.space(10)

              Text {
                width: parent.width
                text: wireguard.qrName
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
              }

              // White backing behind the PNG: phone cameras want contrast,
              // and the panel background is dark.
              Rectangle {
                width: parent.width
                height: width
                color: "white"

                Image {
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  source: wireguard.qrPath !== "" ? "file://" + wireguard.qrPath : ""
                  fillMode: Image.PreserveAspectFit
                  // Crisp modules beat antialiased mush for a camera.
                  smooth: false
                  cache: false
                }
              }

              Text {
                width: parent.width
                text: "Scan with the WireGuard app. The code holds the private key — this moves the profile; two devices on one key kick each other offline."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteDialog
        anchors.fill: parent
        opened: root.pendingDelete !== null
        message: "Delete connection " + (root.pendingDelete ? root.pendingDelete.name : "") + "?"
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Keys.onPressed: function(event) { event.accepted = deleteDialog.handleKey(event) }
        onOpenedChanged: {
          if (opened) {
            selectedIndex = 0
            forceActiveFocus()
          } else {
            keyCatcher.forceActiveFocus()
          }
        }
        onCanceled: root.pendingDelete = null
        onConfirmed: {
          var profile = root.pendingDelete
          root.pendingDelete = null
          wireguard.deleteConfig(profile)
        }
      }
    }
  }

  // Modal name prompt over the panel — a card with a single-line field, a
  // validation hint and Cancel/confirm. The caller owns the validation:
  // `accepted` gates both the confirm button and Enter.
  component NamePrompt: Item {
    id: prompt
    property string title: ""
    property string placeholder: ""
    property string hint: ""
    property bool accepted: false
    property string confirmLabel: "OK"
    property alias value: promptField.text
    signal confirmed()
    signal canceled()

    visible: false

    function openWith(text) {
      promptField.text = String(text)
      visible = true
      Qt.callLater(function() {
        promptField.forceActiveFocus()
        promptField.selectAll()
      })
    }

    function dismiss() {
      visible = false
      keyCatcher.forceActiveFocus()
    }

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.7)

      MouseArea { anchors.fill: parent; onClicked: prompt.canceled() }

      BorderSurface {
        id: promptCard
        width: Math.min(parent.width - Style.space(32), Style.space(340))
        height: promptCard.contentTopInset + promptCard.contentBottomInset + promptColumn.implicitHeight
        anchors.centerIn: parent
        color: Color.background
        borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
        padding: Style.space(18)
        radius: Style.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          id: promptColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: promptCard.contentTopInset
          anchors.leftMargin: promptCard.contentLeftInset
          anchors.rightMargin: promptCard.contentRightInset
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: prompt.title
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideMiddle
          }

          TextField {
            id: promptField
            width: parent.width
            placeholderText: prompt.placeholder
            foreground: root.foreground
            font.family: root.fontFamily
            onAccepted: if (prompt.accepted) prompt.confirmed()
            Keys.onEscapePressed: prompt.canceled()
          }

          Text {
            width: parent.width
            text: prompt.hint
            color: prompt.accepted ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }

          Item {
            width: parent.width
            implicitHeight: promptButtons.implicitHeight

            Row {
              id: promptButtons
              anchors.right: parent.right
              spacing: Style.space(10)

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: prompt.canceled()
              }

              Button {
                text: prompt.confirmLabel
                bordered: true
                enabled: prompt.accepted
                foreground: prompt.accepted ? root.foreground : root.dim
                fontFamily: root.fontFamily
                onClicked: prompt.confirmed()
              }
            }
          }
        }
      }
    }
  }

  component ConfigRow: CursorSurface {
    id: configRow
    // {uuid, name, active} — the row keeps the whole profile so its actions
    // hit exactly this profile even when names collide.
    property var profile: null
    property int rowIndex: 0
    readonly property bool connected: profile ? profile.active === true : false

    hasCursor: root.cursorActive && root.focusSection === "configs" && root.configIndex === rowIndex
    current: connected
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: wireguard.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.setConfigCursor(configRow.rowIndex)
      onClicked: root.activateConfig(configRow.profile)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: configRow.connected ? "󰄬" : "󰌘"
        color: configRow.connected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: configRow.profile ? configRow.profile.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          // Traffic, not health: rate and session totals say the tunnel is
          // moving bytes, nothing more — an idle tunnel is not a broken one.
          text: {
            if (!configRow.connected) return "Click to connect"
            var line = wireguard.trafficLine(configRow.profile ? configRow.profile.ifname : "")
            return line !== "" ? line : "Connected — click to disconnect"
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰏫"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestEdit(configRow.profile)
      }

      PanelActionButton {
        iconText: "󰐲"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: wireguard.showQr(configRow.profile)
      }

      PanelActionButton {
        iconText: "󰆴"
        foreground: root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestDelete(configRow.profile)
      }
    }
  }
}
