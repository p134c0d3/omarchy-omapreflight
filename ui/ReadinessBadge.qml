import QtQuick
import qs.Commons
import "Vocabulary.js" as Vocabulary

// The readiness verdict: glyph, word, and a plain-language line about what it
// means. Used by both surfaces so the bar and the overlay can never disagree
// about what the machine is being told.
//
// There is no score and no percentage here, by design (spec §3.1). The
// vocabulary is finite and each value means something specific.
Item {
  id: badge

  property string readiness: "neutral"
  property bool scanning: false
  property var counts: null
  property string lastScanText: ""

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real glyphSize: Style.font.display
  property bool showBlurb: true

  // Counts and freshness on one line. Computed here rather than inline in the
  // Text so `visible` can test it without the element referring to its own
  // `text` property.
  readonly property string metaLine: {
    var sentence = Vocabulary.countsSentence(badge.counts)
    if (badge.lastScanText.length === 0) return sentence
    return sentence.length > 0
      ? sentence + "  ·  " + badge.lastScanText
      : badge.lastScanText
  }

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color veryDim: Qt.darker(foreground, 1.7)

  readonly property color accentColor: {
    if (badge.scanning) return badge.foreground
    switch (String(badge.readiness)) {
    case "not_recommended": return Color.urgent
    case "review": return Color.accent
    case "ready": return badge.foreground
    default: return badge.veryDim
    }
  }

  implicitHeight: Math.max(glyph.implicitHeight, labels.implicitHeight)

  Text {
    id: glyph
    text: Vocabulary.readinessGlyph(badge.readiness, badge.scanning)
    color: badge.accentColor
    font.family: badge.fontFamily
    font.pixelSize: badge.glyphSize
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
  }

  Column {
    id: labels
    anchors.left: glyph.right
    anchors.leftMargin: Style.space(14)
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      text: Vocabulary.readinessLabel(badge.readiness, badge.scanning).toUpperCase()
      color: badge.accentColor
      font.family: badge.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      font.letterSpacing: 1.2
      elide: Text.ElideRight
      width: parent.width
    }

    Text {
      visible: badge.showBlurb
      text: Vocabulary.readinessBlurb(badge.readiness, badge.scanning)
      color: badge.dim
      font.family: badge.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Text {
      visible: badge.metaLine.length > 0
      text: badge.metaLine
      color: badge.veryDim
      font.family: badge.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: parent.width
    }
  }
}
