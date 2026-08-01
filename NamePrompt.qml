import QtQuick
import qs.Commons
import qs.Ui

// Modal name prompt — a card with a single-line field, a validation hint and
// Cancel/confirm. The caller owns the validation: `accepted` gates both the
// confirm button and Enter.
//
// A file rather than an inline component because it serves two surfaces: the
// import prompt inside the popup, and RenameWindow's screen-centred card. It
// fills whatever it is anchored to and centres the card in it, so the two
// differ only in `maxCardWidth` and in who returns the focus afterwards —
// `dismiss()` deliberately leaves that to the caller, which is the only side
// that knows where focus belongs.
Item {
  id: prompt

  property string title: ""
  property string placeholder: ""
  property string hint: ""
  property bool accepted: false
  property string confirmLabel: "OK"
  property alias value: promptField.text
  // The panel card is Style.space(340) wide, so the prompt inside it cannot
  // be wider; a window of its own can afford more.
  property real maxCardWidth: Style.space(340)
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal confirmed()
  signal canceled()

  visible: false

  function openWith(text) {
    promptField.text = String(text)
    visible = true
    Qt.callLater(function() { prompt.focusField() })
  }

  // Separate from openWith so a host window can re-acquire focus once its
  // surface is mapped — a hidden window has nowhere to put it.
  function focusField() {
    promptField.forceActiveFocus()
    promptField.selectAll()
  }

  function dismiss() {
    visible = false
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: prompt.canceled() }

    BorderSurface {
      id: promptCard
      width: Math.min(parent.width - Style.space(32), prompt.maxCardWidth)
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
          color: prompt.foreground
          font.family: prompt.fontFamily
          font.pixelSize: Style.font.title
          elide: Text.ElideMiddle
        }

        TextField {
          id: promptField
          width: parent.width
          placeholderText: prompt.placeholder
          foreground: prompt.foreground
          font.family: prompt.fontFamily
          onAccepted: if (prompt.accepted) prompt.confirmed()
          Keys.onEscapePressed: prompt.canceled()
        }

        Text {
          width: parent.width
          text: prompt.hint
          color: prompt.accepted ? prompt.dim : prompt.urgent
          font.family: prompt.fontFamily
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
              foreground: prompt.foreground
              fontFamily: prompt.fontFamily
              onClicked: prompt.canceled()
            }

            Button {
              text: prompt.confirmLabel
              bordered: true
              enabled: prompt.accepted
              foreground: prompt.accepted ? prompt.foreground : prompt.dim
              fontFamily: prompt.fontFamily
              onClicked: prompt.confirmed()
            }
          }
        }
      }
    }
  }
}
