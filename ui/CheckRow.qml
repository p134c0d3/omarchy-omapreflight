pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "Vocabulary.js" as Vocabulary

// One check result, collapsed to a line and expandable to its evidence.
//
// Spec §7.4 and §27.1: the status is carried by a glyph and a word before it
// is carried by a colour, technical detail is available but never in the way,
// and the whole row is reachable and operable from the keyboard.
Item {
  id: row

  property var result: null
  property bool expanded: false
  property bool selected: false

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal activated()

  readonly property string status: result ? String(result.status) : "unknown"
  readonly property bool hasDetail: result
    && ((result.details && result.details.length > 0)
        || (result.evidence && result.evidence.length > 0)
        || (result.remediation !== null && result.remediation !== undefined))

  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color veryDim: Qt.darker(foreground, 1.75)

  // Colour is the third cue, after the glyph and the word, and it comes
  // entirely from theme tokens — the plugin never names a colour of its own
  // (ADR-004).
  readonly property color statusColor: {
    switch (row.status) {
    case "fail": return Color.urgent
    case "warn": return Color.accent
    case "pass": return row.foreground
    default: return row.veryDim
    }
  }

  implicitHeight: content.implicitHeight + Style.space(16)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.selected ? Color.menu.selectedBackground : "transparent"
  }

  MouseArea {
    anchors.fill: parent
    enabled: row.hasDetail
    cursorShape: row.hasDetail ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: row.activated()
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(8)
    spacing: Style.space(6)

    // ---- headline ----
    Item {
      width: parent.width
      implicitHeight: Math.max(glyph.implicitHeight, headline.implicitHeight)

      Text {
        id: glyph
        text: Vocabulary.statusGlyph(row.status)
        color: row.statusColor
        font.family: row.fontFamily
        font.pixelSize: Style.font.title
        anchors.left: parent.left
        anchors.top: parent.top
        width: Style.space(26)
      }

      Column {
        id: headline
        anchors.left: glyph.right
        anchors.leftMargin: Style.space(6)
        anchors.right: statusWord.left
        anchors.rightMargin: Style.space(12)
        anchors.top: parent.top
        spacing: Style.space(2)

        Text {
          text: row.result ? String(row.result.title) : ""
          color: row.foreground
          font.family: row.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: row.result ? String(row.result.summary) : ""
          color: row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }

      // The word, always present. This is what makes the row legible with no
      // colour perception at all.
      Text {
        id: statusWord
        text: Vocabulary.statusLabel(row.status)
        color: row.statusColor
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.1
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.space(2)
      }
    }

    // ---- expandable technical detail ----
    Column {
      id: detail
      width: parent.width
      visible: row.expanded && row.hasDetail
      spacing: Style.space(8)
      leftPadding: Style.space(32)

      Repeater {
        model: row.expanded && row.result && row.result.details ? row.result.details : []
        delegate: Text {
          required property string modelData
          text: "• " + modelData
          color: row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: detail.width - detail.leftPadding
        }
      }

      Repeater {
        model: row.expanded && row.result && row.result.evidence ? row.result.evidence : []
        delegate: Column {
          id: evidenceItem
          required property var modelData
          width: detail.width - detail.leftPadding
          spacing: Style.space(2)

          Text {
            text: evidenceItem.modelData.label
            color: row.veryDim
            font.family: row.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            visible: String(evidenceItem.modelData.value).length > 0
            text: String(evidenceItem.modelData.value)
            color: row.dim
            font.family: row.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            width: parent.width
          }
        }
      }

      Text {
        visible: row.result && row.result.remediation
        text: "→ " + (row.result && row.result.remediation ? String(row.result.remediation) : "")
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: detail.width - detail.leftPadding
      }
    }
  }

  // A quiet affordance, shown only where there is something to open.
  Text {
    visible: row.hasDetail
    text: row.expanded ? "−" : "+"
    color: row.veryDim
    font.family: row.fontFamily
    font.pixelSize: Style.font.caption
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(6)
  }
}
