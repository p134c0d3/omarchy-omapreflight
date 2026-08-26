pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "ui" as Preflight
import "ui/Vocabulary.js" as Vocabulary
import "checks/Registry.js" as Registry
import "core/ResultModel.js" as R

// OmaPreflight diagnostic window — the engineering surface (§7.3).
//
// Summoned through the host: `omarchy-shell shell toggle p134c0d3.omapreflight`.
// Because the manifest declares kind `overlay`, the shell's summon path routes
// here rather than to the bar widget's quick panel.
//
// This is a real toplevel (`FloatingWindow`), not a layer-shell surface, and
// that is a deliberate correction. A layer surface cannot be moved or resized
// by the compositor: Omarchy binds `SUPER + mouse:272` to move and
// `SUPER + mouse:273` to resize, both consuming, and both act on *windows*.
// A layer surface never receives those events and Hyprland has nothing to do
// with them, so the gesture every other window on the system responds to would
// simply do nothing here — and re-implementing move and resize inside the
// surface would be a worse imitation of what the compositor already does well.
//
// Being a window also means normal focus, normal blur and opacity rules, and a
// place in the window list. What it gives up is the modal scrim, which a
// report you want to read alongside a terminal never wanted anyway.
//
// See docs/adr/ADR-005-window-not-layer-surface.md.
//
// `service`, `shell` and `manifest` are injected by the shell's panel loader.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false

  readonly property var store: service ? service.store : null
  readonly property string pluginVersion: service ? String(service.pluginVersion) : ""
  readonly property string readiness: store ? String(store.readiness) : "neutral"
  readonly property bool scanRunning: store ? store.scanRunning === true : false
  readonly property var results: store && store.results ? store.results : []
  readonly property var counts: store ? store.countsByStatus() : null

  // Category order first (the catalog's own reading order), then worst-first
  // inside each category. A diagnostic surface should put the thing that needs
  // attention where the eye lands.
  readonly property var orderedResults: {
    var list = root.results.slice()
    list.sort(function (a, b) {
      var byCategory = Registry.categoryOrder(a.category) - Registry.categoryOrder(b.category)
      if (byCategory !== 0) return byCategory
      var byStatus = R.statusRank(a.status) - R.statusRank(b.status)
      if (byStatus !== 0) return byStatus
      return String(a.id).localeCompare(String(b.id))
    })
    return list
  }

  // Expansion is keyed by check id rather than by row index so it survives a
  // rescan reordering the list.
  property var expandedIds: ({})
  property int selectedIndex: 0

  // Shares the [menu] surface tokens so themes style this like every other
  // Omarchy surface. No hard-coded light/dark assumptions (§27.1).
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))

  // As a window rather than a layer surface, this gets Omarchy's normal window
  // blur and opacity rules, so the theme's own token is used unmodified. The
  // alpha floor an earlier layer-shell version needed — because compositor
  // blur is granted per layer namespace, and only to first-party names — is
  // gone with the reason for it (ADR-004, superseded by ADR-005).
  readonly property color surfaceFill: background
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding

  readonly property string lastScanText: store && store.lastScanAt
    ? "scanned " + Vocabulary.relativeTime(store.lastScanAt, tick.now)
    : ""

  function open(payloadJson) {
    // Idempotent and already registered at service mount; this covers the case
    // where the compositor restarted underneath a running shell.
    if (service && typeof service.ensureWindowRule === "function") service.ensureWindowRule(null)
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Called by the host when it hides us. The flag keeps the window's own
  // onVisibleChanged from calling straight back into shell.hide().
  function close() {
    window.closingFromHost = true
    root.opened = false
    window.closingFromHost = false
  }

  // User-initiated dismissal routes through the host so its open-panel state
  // stays consistent; the host calls close() back on us.
  function dismiss() {
    var id = (manifest && manifest.id) ? String(manifest.id) : "p134c0d3.omapreflight"
    if (shell && typeof shell.hide === "function") shell.hide(id)
    else close()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function runScan() {
    if (service && typeof service.runPreflight === "function") service.runPreflight()
  }

  function cancelScan() {
    if (service && typeof service.cancelPreflight === "function") service.cancelPreflight()
  }

  // Reports are written locally and shared only by the user's own hand (§24).
  // The footer states where the file went, because "saved!" with no path is
  // not information.
  property string reportNotice: ""

  function saveReport() {
    if (!service || typeof service.saveReport !== "function") return
    root.reportNotice = "Writing report…"
    service.saveReport(function (result) {
      root.reportNotice = result.ok
        ? "Report written to " + root.shorten(result.path)
        : "Could not write the report: " + result.error
      noticeTimer.restart()
    })
  }

  function copyReport() {
    if (!service || typeof service.copyReport !== "function") return
    var outcome = service.copyReport()
    root.reportNotice = outcome === "copied"
      ? "Report copied to the clipboard — review it before posting."
      : "Nothing to copy yet."
    noticeTimer.restart()
  }

  function shorten(path) {
    var home = service && service.homeDir ? String(service.homeDir) : ""
    if (home.length > 0 && String(path).indexOf(home) === 0) return "~" + String(path).substring(home.length)
    return String(path)
  }

  function isExpanded(id) {
    return root.expandedIds[String(id)] === true
  }

  function toggleExpanded(id) {
    var key = String(id)
    // Reassigned rather than mutated: a var property only notifies on
    // assignment, and the rows bind to it.
    var next = {}
    for (var existing in root.expandedIds) next[existing] = root.expandedIds[existing]
    if (next[key]) delete next[key]
    else next[key] = true
    root.expandedIds = next
  }

  function moveSelection(delta) {
    var count = root.orderedResults.length
    if (count === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    root.selectedIndex = next
    root.ensureVisible(next)
  }

  function ensureVisible(index) {
    var item = rowRepeater.itemAt(index)
    if (!item) return
    var top = item.y
    var bottom = item.y + item.height
    if (top < listView.contentY) listView.contentY = Math.max(0, top - Style.space(8))
    else if (bottom > listView.contentY + listView.height)
      listView.contentY = Math.min(Math.max(0, listView.contentHeight - listView.height),
                                   bottom - listView.height + Style.space(8))
  }

  function activateSelected() {
    var result = root.orderedResults[root.selectedIndex]
    if (result) root.toggleExpanded(result.id)
  }

  // Only ticks while the overlay is open, and only once a minute: it exists to
  // keep "scanned 3 minutes ago" honest, not to animate anything.
  Timer {
    id: noticeTimer
    interval: 12000
    repeat: false
    onTriggered: root.reportNotice = ""
  }

  Timer {
    id: tick
    property real now: Date.now()
    interval: 60000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: tick.now = Date.now()
  }


  FloatingWindow {
    id: window
    title: "OmaPreflight"
    visible: root.opened
    color: root.surfaceFill

    // The window asks to be exactly as tall as its content and no taller, which
    // is what the user actually wanted from "show everything without
    // scrolling". Hyprland gets the final say — it always does — so the list
    // still scrolls if the compositor hands back something shorter.
    implicitWidth: Style.space(940)
    implicitHeight: Math.min(Style.space(1200), content.naturalHeight)
    minimumSize: Qt.size(Style.space(420), Style.space(260))

    // Closing the window with the compositor (or its own close button) has to
    // tell the host, or the shell keeps believing the panel is open and the
    // next summon does nothing.
    property bool closingFromHost: false

    onVisibleChanged: {
      if (visible) {
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
        return
      }
      if (window.closingFromHost) return
      root.opened = false
      var id = (root.manifest && root.manifest.id) ? String(root.manifest.id) : "p134c0d3.omapreflight"
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(id)
    }

    Item {
      id: content
      anchors.fill: parent
      anchors.margins: root.contentMargin

      readonly property real naturalHeight: root.contentMargin * 2
        + header.implicitHeight + footer.implicitHeight
        + resultsColumn.implicitHeight + Style.space(20)

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          switch (event.key) {
          case Qt.Key_Escape:
            root.dismiss()
            event.accepted = true
            break
          case Qt.Key_Down:
          case Qt.Key_J:
            root.moveSelection(1)
            event.accepted = true
            break
          case Qt.Key_Up:
          case Qt.Key_K:
            root.moveSelection(-1)
            event.accepted = true
            break
          case Qt.Key_Home:
            root.selectedIndex = 0
            root.ensureVisible(0)
            event.accepted = true
            break
          case Qt.Key_End:
            root.selectedIndex = Math.max(0, root.orderedResults.length - 1)
            root.ensureVisible(root.selectedIndex)
            event.accepted = true
            break
          case Qt.Key_Return:
          case Qt.Key_Enter:
          case Qt.Key_Space:
            root.activateSelected()
            event.accepted = true
            break
          case Qt.Key_R:
            if (!root.scanRunning) root.runScan()
            event.accepted = true
            break
          case Qt.Key_S:
            root.saveReport()
            event.accepted = true
            break
          case Qt.Key_C:
            root.copyReport()
            event.accepted = true
            break
          }
        }

        // ---- header -------------------------------------------------
        Column {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(14)

          Item {
            width: parent.width
            implicitHeight: Math.max(title.implicitHeight, actions.implicitHeight)

            Column {
              id: title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "OmaPreflight"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                font.bold: true
              }

              Text {
                text: root.pluginVersion ? "v" + root.pluginVersion : ""
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: actions
              spacing: Style.space(10)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Button {
                text: "Copy"
                // qs.Ui.Button has no disabled styling of its own, so the
                // opacity is what actually communicates the state.
                enabled: root.orderedResults.length > 0
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                focusable: true
                onClicked: root.copyReport()
              }

              Button {
                text: "Save report"
                enabled: root.orderedResults.length > 0
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                focusable: true
                onClicked: root.saveReport()
              }

              Button {
                text: root.scanRunning ? "Cancel" : "Run scan"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                focusable: true
                onClicked: root.scanRunning ? root.cancelScan() : root.runScan()
              }
            }
          }

          PanelSeparator { width: parent.width }

          Preflight.ReadinessBadge {
            width: parent.width
            readiness: root.readiness
            scanning: root.scanRunning
            counts: root.counts
            lastScanText: root.lastScanText
            foreground: root.foreground
            fontFamily: root.fontFamily
            glyphSize: Style.font.displayLarge
          }

          // Progress is shown as a phase name and a bar, not only as a bar:
          // "Hyprland configuration errors" says something a moving rectangle
          // does not.
          Item {
            width: parent.width
            visible: root.scanRunning
            implicitHeight: visible ? progressLabel.implicitHeight + Style.space(10) : 0

            Text {
              id: progressLabel
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              text: root.store && root.store.scanPhase
                ? root.store.scanPhase
                : "Starting"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: progressLabel.bottom
              anchors.topMargin: Style.space(6)
              height: Math.max(2, Style.space(3))
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * Math.max(0, Math.min(1, root.store ? root.store.scanProgress : 0))
                radius: parent.radius
                color: root.foreground
                Behavior on width { NumberAnimation { duration: 160 } }
              }
            }
          }

          PanelSeparator { width: parent.width }
        }

        // ---- footer -------------------------------------------------
        Column {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(4)

          Text {
            visible: root.reportNotice.length > 0
            width: parent.width
            text: root.reportNotice
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "↑↓ move   ⏎ expand   R rescan   S save   C copy   Esc close"
            color: Qt.darker(root.foreground, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // ---- results ------------------------------------------------
        Flickable {
          id: listView
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.bottom: footer.top
          anchors.topMargin: Style.space(10)
          anchors.bottomMargin: Style.space(10)
          clip: true
          contentWidth: width
          contentHeight: resultsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          // Scrolling exists only for the case the window could not grow into.
          interactive: contentHeight > height

          Column {
            id: resultsColumn
            width: listView.width
            spacing: Style.space(2)

            // States what it knows. An empty list is never dressed up as a
            // clean bill of health (§3.2).
            Text {
              visible: root.orderedResults.length === 0
              width: parent.width
              text: root.scanRunning
                ? "Running the first checks…"
                : "No checks have run yet. Press R, or use the Run scan button."
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              id: rowRepeater
              model: root.orderedResults

              delegate: Column {
                id: rowGroup
                required property int index
                required property var modelData

                width: resultsColumn.width
                spacing: Style.space(4)

                readonly property bool startsCategory: index === 0
                  || String(root.orderedResults[index - 1].category) !== String(modelData.category)

                PanelSectionHeader {
                  visible: rowGroup.startsCategory
                  height: visible ? implicitHeight + Style.space(10) : 0
                  text: Registry.categoryTitle(rowGroup.modelData.category).toUpperCase()
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  verticalAlignment: Text.AlignBottom
                }

                Preflight.CheckRow {
                  width: rowGroup.width
                  result: rowGroup.modelData
                  expanded: root.isExpanded(rowGroup.modelData.id)
                  selected: root.selectedIndex === rowGroup.index
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onActivated: {
                    root.selectedIndex = rowGroup.index
                    root.toggleExpanded(rowGroup.modelData.id)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
