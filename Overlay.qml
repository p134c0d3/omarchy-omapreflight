import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

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

  readonly property string readinessLabel: {
    switch (readiness) {
      case "ready":           return "READY"
      case "review":          return "REVIEW"
      case "not_recommended": return "NOT RECOMMENDED"
      case "unknown":         return "UNKNOWN"
      default:                return "NO SCAN YET"
    }
  }

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
      height: Math.min(Style.space(620), window.height - Style.gapsOut * 2)
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
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          }
        }

        Column {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(16)

          Item {
            width: parent.width
            implicitHeight: Math.max(title.implicitHeight, badge.implicitHeight)

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

            Text {
              id: badge
              text: root.readinessLabel
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 1.4
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSeparator { width: parent.width }

          // The result list, category navigation, evidence blocks and report
          // actions land here in M1/M2. Until the check engine exists this
          // surface states what it knows rather than implying a scan ran.
          Text {
            text: "No checks have run yet.\n\nThe diagnostic engine arrives in the next milestone. "
                + "This surface is the runtime spike: it proves the overlay mounts, summons, "
                + "takes keyboard focus, and closes cleanly."
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Text {
            text: "Esc  close"
            color: Qt.darker(root.foreground, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
