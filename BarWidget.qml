pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "ui" as Preflight
import "ui/Vocabulary.js" as Vocabulary
import "core/ResultModel.js" as R

// OmaPreflight bar surface: a readiness badge in the bar plus the quick panel
// that hangs off it.
//
// Root type is qs.Ui.Panel — the base built for "a bar button plus a popup from
// one QML entry point". It supplies the opened/open()/close()/toggle()
// lifecycle the shell and the marketplace checklist expect.
//
// The quick panel gets its own IPC target, distinct from the service's. The
// shell permits one handler per target name, so `p134c0d3.omapreflight` stays
// the service's (run/status/cancel/results) and the panel answers on
// `p134c0d3.omapreflight.panel` (open/close/toggle). That separation is also
// the only way to reach this surface without a mouse: because the manifest
// declares kind `overlay`, `omarchy-shell shell toggle <id>` opens the overlay,
// not this panel.
Panel {
  id: root
  moduleName: "p134c0d3.omapreflight"
  ipcTarget: "p134c0d3.omapreflight.panel"

  // The service is the shared store (ADR-001). It may briefly be null while the
  // shell mounts plugins, so every read below is guarded.
  readonly property var service: bar?.shell?.serviceFor("p134c0d3.omapreflight") ?? null
  readonly property var store: service ? service.store : null

  readonly property string readiness: store ? String(store.readiness) : "neutral"
  readonly property bool scanRunning: store ? store.scanRunning === true : false
  readonly property var lastScanAt: store ? store.lastScanAt : null
  readonly property var counts: store ? store.countsByStatus() : null

  // The quick panel is a summary surface (§7.2): it shows what needs attention,
  // and sends you to the overlay for everything else. Passing checks are
  // counted, not listed.
  readonly property var findings: {
    if (!store || !store.results) return []
    var list = []
    for (var i = 0; i < store.results.length; i++) {
      var result = store.results[i]
      if (!result) continue
      if (result.status === "pass" || result.status === "skipped") continue
      list.push(result)
    }
    list.sort(function (a, b) { return R.statusRank(a.status) - R.statusRank(b.status) })
    return list
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Status is carried by glyph *and* label, never by colour alone (§27.1).
  readonly property string stateGlyph: Vocabulary.readinessGlyph(readiness, scanRunning)
  readonly property string stateLabel: Vocabulary.readinessLabel(readiness, scanRunning)
  readonly property bool stateDim: !scanRunning && Vocabulary.readinessIsNeutral(readiness)

  // The bar sizes each slot from the widget root's implicit size
  // (Bar.qml: `implicitWidth: activeItem.implicitWidth`). The button is
  // anchored to fill this root, so without forwarding its implicit size the
  // slot collapses to zero width and the widget never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color barIconColor: stateDim
    ? Qt.darker(barForeground, 1.55)
    : barForeground

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

  function cancelPreflight() {
    if (service && typeof service.cancelPreflight === "function") service.cancelPreflight()
  }

  // Only runs while the panel is open, and only once a minute: it keeps
  // "scanned 3 minutes ago" honest without waking anything up for the other
  // 59 seconds.
  Timer {
    id: tick
    property real now: Date.now()
    interval: 60000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: tick.now = Date.now()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.stateGlyph
    foreground: root.barIconColor
    tooltipText: "OmaPreflight — " + root.stateLabel
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
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

        // ---------- Hero: readiness verdict ----------
        Preflight.ReadinessBadge {
          width: parent.width
          readiness: root.readiness
          scanning: root.scanRunning
          counts: root.counts
          lastScanText: root.lastScanAt
            ? "scanned " + Vocabulary.relativeTime(root.lastScanAt, tick.now)
            : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // ---------- Progress, while a scan is in flight ----------
        Text {
          visible: root.scanRunning
          width: parent.width
          text: root.store && root.store.scanPhase ? root.store.scanPhase : "Starting"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        PanelSeparator { width: parent.width }

        // ---------- Findings ----------
        PanelSectionHeader {
          visible: root.findings.length > 0
          text: root.findings.length === 1 ? "1 FINDING" : root.findings.length + " FINDINGS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            // Capped on purpose. The quick panel is a glance surface; the
            // overlay is where the full list lives.
            model: root.findings.slice(0, 4)

            delegate: Row {
              id: findingRow
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: Vocabulary.statusGlyph(findingRow.modelData.status)
                color: findingRow.modelData.status === "fail"
                  ? Color.urgent
                  : (findingRow.modelData.status === "warn"
                      ? Color.accent
                      : Qt.darker(root.foreground, 1.6))
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(20)
              }

              Column {
                width: parent.width - Style.space(28)
                spacing: Style.space(1)

                Text {
                  text: findingRow.modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: findingRow.modelData.summary
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }
            }
          }

          Text {
            visible: root.findings.length > 4
            text: "+" + (root.findings.length - 4) + " more in the full report"
            color: Qt.darker(root.foreground, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
          }
        }

        // ---------- Nothing to report ----------
        Text {
          visible: root.findings.length === 0
          width: parent.width
          text: {
            if (root.scanRunning) return "Checks are running."
            if (!root.store || !root.store.results || root.store.results.length === 0)
              return "No checks have run yet."
            return "Nothing needs attention."
          }
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        PanelSeparator { width: parent.width }

        Row {
          spacing: Style.space(10)

          Button {
            text: root.scanRunning ? "Cancel" : "Run scan"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            focusable: true
            onClicked: root.scanRunning ? root.cancelPreflight() : root.runPreflight()
          }

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
