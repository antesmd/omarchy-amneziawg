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
  property string importName: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: wireguard.active ? foreground : dim
  readonly property color barIconColor: wireguard.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string toggleHint: wireguard.active
    ? "Disconnect"
    : (wireguard.toggleTarget !== "" ? "Connect " + wireguard.toggleTarget : "Connect")
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && wireguard.profiles.length > 0

  readonly property bool importPrompt: importKind !== ""
  readonly property string importNameClean: importName.trim()
  readonly property bool importNameValid: wireguard.isValidName(importNameClean)
  readonly property int importNameCount: importNameValid ? wireguard.countByName(importNameClean) : 0
  readonly property bool importReplaces: importNameCount === 1
  // Several existing profiles share the typed name — "replace" cannot know
  // which one is meant, so the import is refused under this name.
  readonly property bool importAmbiguous: importNameCount > 1
  readonly property bool importAccepted: importNameValid && !importAmbiguous
  readonly property string importSourceLabel: importKind === "text"
    ? "Import from clipboard"
    : "Import " + String(importPayload).split("/").pop()
  readonly property string importHintText: !importNameValid
    ? "Up to 15 characters: letters, digits and . _ - = +"
    : (importAmbiguous
      ? importNameCount + " profiles share the name " + importNameClean + " — pick another name"
      : (importReplaces
        ? "Replaces the existing connection " + importNameClean
        : "Imports as NetworkManager connection " + importNameClean))

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
    importName = suggested !== "" ? String(suggested) : wireguard.suggestName()
  }

  function cancelImport() {
    importKind = ""
    importPayload = ""
    importName = ""
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
    cancelImport()
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
      if (wireguard.countByName(name) > 1) return "error: ambiguous name: several profiles are named " + name
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
    function importPick(): string { wireguard.pickConfigFile(); return "ok" }
    function importPaste(): string { wireguard.pasteConfig(); return "ok" }
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
      blocked: root.pendingDelete !== null || root.importPrompt
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
      Item {
        id: importDialog
        anchors.fill: parent
        visible: root.importPrompt

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.7)

          MouseArea { anchors.fill: parent; onClicked: root.cancelImport() }

          BorderSurface {
            id: importCard
            width: Math.min(parent.width - Style.space(32), Style.space(340))
            height: importCard.contentTopInset + importCard.contentBottomInset + importColumn.implicitHeight
            anchors.centerIn: parent
            color: Color.background
            borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
            padding: Style.space(18)
            radius: Style.cornerRadius

            MouseArea { anchors.fill: parent; onClicked: {} }

            Column {
              id: importColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.topMargin: importCard.contentTopInset
              anchors.leftMargin: importCard.contentLeftInset
              anchors.rightMargin: importCard.contentRightInset
              spacing: Style.space(10)

              Text {
                width: parent.width
                text: root.importSourceLabel
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideMiddle
              }

              TextField {
                id: nameField
                width: parent.width
                placeholderText: "Interface name"
                foreground: root.foreground
                font.family: root.fontFamily
                text: root.importName

                onTextChanged: if (text !== root.importName) root.importName = text
                onAccepted: root.confirmImport()
                Keys.onEscapePressed: root.cancelImport()
              }

              Text {
                width: parent.width
                text: root.importHintText
                color: root.importAccepted ? root.dim : root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }

              Item {
                width: parent.width
                implicitHeight: importButtons.implicitHeight

                Row {
                  id: importButtons
                  anchors.right: parent.right
                  spacing: Style.space(10)

                  Button {
                    text: "Cancel"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.cancelImport()
                  }

                  Button {
                    text: root.importReplaces ? "Replace" : "Import"
                    bordered: true
                    enabled: root.importAccepted
                    foreground: root.importAccepted ? root.foreground : root.dim
                    fontFamily: root.fontFamily
                    onClicked: root.confirmImport()
                  }
                }
              }
            }
          }
        }

        onVisibleChanged: {
          if (visible) {
            Qt.callLater(function() {
              nameField.forceActiveFocus()
              nameField.selectAll()
            })
          } else {
            keyCatcher.forceActiveFocus()
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
          text: configRow.connected ? "Connected — click to disconnect" : "Click to connect"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰏫"
        tooltipText: "Edit config"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        enabled: !wireguard.busy
        visible: configRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: wireguard.editConfig(configRow.profile, "")
      }

      PanelActionButton {
        iconText: "󰆴"
        tooltipText: "Delete config"
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
