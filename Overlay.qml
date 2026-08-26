pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ui" as Preflight
import "ui/Vocabulary.js" as Vocabulary
import "checks/Registry.js" as Registry
import "core/ResultModel.js" as R

// OmaPreflight full-screen diagnostic overlay — the engineering surface (§7.3).
//
// Summoned through the host: `omarchy-shell shell toggle p134c0d3.omapreflight`.
// Because the manifest declares kind `overlay`, the shell's summon path routes
// here rather than to the bar widget's quick panel.
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
  readonly property color scrim: Color.menu.scrim

  // Themes make the menu tokens translucent because Omarchy's own surfaces are
  // blurred by a compositor layer rule — and those rules name first-party
  // namespaces explicitly, e.g. the current theme allows blur only for
  // ^(omarchy-bar|omarchy-menu|omarchy-clipboard|...)$. A third-party namespace
  // gets no blur, so the same token reads as "see-through" instead of
  // "frosted", with the desktop legible straight through the card.
  //
  // Keep the theme's hue and raise only the alpha floor. That looks correct on
  // any theme with no Hyprland configuration required, and stays correct for
  // users who do add a blur rule for this namespace (see README).
  readonly property color cardFill: Qt.rgba(background.r, background.g, background.b,
                                            Math.max(background.a, 0.97))
  readonly property color scrimFill: Qt.rgba(scrim.r, scrim.g, scrim.b,
                                             Math.max(scrim.a, 0.72))
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding

  readonly property string lastScanText: store && store.lastScanAt
    ? "scanned " + Vocabulary.relativeTime(store.lastScanAt, tick.now)
    : ""

  function open(payloadJson) {
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
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
    id: tick
    property real now: Date.now()
    interval: 60000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: tick.now = Date.now()
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omapreflight-overlay"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrimFill
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(900), window.width - Style.gapsOut * 2)
      height: Math.min(Style.space(680), window.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.cardFill
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // Swallow clicks on the card so they do not reach the dismiss scrim.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        // BorderSurface exposes padding as content insets rather than applying
        // them; consuming them here is what actually indents the content.
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
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

          // Progress is shown as a phase name and a count, not only as a bar:
          // "Hyprland configuration errors — 6 of 9" says something a moving
          // rectangle does not.
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
        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          text: "↑↓ move   ⏎ expand   R rescan   Esc close"
          color: Qt.darker(root.foreground, 1.7)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
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
