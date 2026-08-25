import QtQuick
import qs.Commons
import qs.Ui

// OmaPreflight bar surface: a readiness badge in the bar plus the quick panel
// that hangs off it.
//
// Root type is qs.Ui.Panel — the base built for "a bar button plus a popup from
// one QML entry point". It supplies the opened/open()/close()/toggle()
// lifecycle the shell and the marketplace checklist expect.
//
// `ipcTarget` is deliberately unset: Service.qml owns this plugin's IPC target
// and the shell permits only one handler per target name.
Panel {
  id: root
  moduleName: "p134c0d3.omapreflight"

  // The service is the shared store (ADR-001). It may briefly be null while the
  // shell mounts plugins, so every read below is guarded.
  readonly property var service: bar?.shell?.serviceFor("p134c0d3.omapreflight") ?? null
  readonly property var store: service ? service.store : null

  readonly property string readiness: store ? String(store.readiness) : "neutral"
  readonly property bool scanRunning: store ? store.scanRunning === true : false
  readonly property var lastScanAt: store ? store.lastScanAt : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Status is carried by glyph *and* label, never by colour alone (§27.1).
  readonly property var stateInfo: {
    if (scanRunning) return { glyph: "󰔟", label: "Checking", dim: false }
    switch (readiness) {
      case "ready":           return { glyph: "󰄬", label: "Ready", dim: false }
      case "review":          return { glyph: "󰀦", label: "Review", dim: false }
      case "not_recommended": return { glyph: "󰅚", label: "Not recommended", dim: false }
      case "unknown":         return { glyph: "󰋗", label: "Unknown", dim: false }
      default:                return { glyph: "󰝦", label: "No scan yet", dim: true }
    }
  }

  readonly property color barIconColor: stateInfo.dim
    ? Qt.darker(barForeground, 1.55)
    : barForeground

  function lastScanText() {
    if (!lastScanAt) return "Never"
    return String(lastScanAt)
  }

  // Opening the full overlay goes through the host so its open-panel bookkeeping
  // stays consistent. Both surfaces belong to this same plugin id; because the
  // manifest declares `overlay`, summon routes to Overlay.qml (not back here).
  function openOverlay() {
    root.close()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("p134c0d3.omapreflight", "{}")
  }

  function runPreflight() {
    if (service && typeof service.runPreflight === "function") service.runPreflight()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.stateInfo.glyph
    foreground: root.barIconColor
    tooltipText: "OmaPreflight — " + root.stateInfo.label
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · title · readiness ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: root.stateInfo.glyph
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "OmaPreflight"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.stateInfo.label.toUpperCase()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { width: parent.width }

        Text {
          text: "Last scan: " + root.lastScanText()
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }

        // Categories land here in M1, driven by store.categories. Until the
        // check engine exists this states the truth rather than showing
        // placeholder rows that imply a scan happened.
        Text {
          text: "No checks have run yet."
          color: Qt.darker(root.foreground, 1.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          width: parent.width
        }

        PanelSeparator { width: parent.width }

        Row {
          spacing: Style.space(10)

          Button {
            text: "Full report"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            focusable: true
            onClicked: root.openOverlay()
          }
        }
      }
    }
  }
}
