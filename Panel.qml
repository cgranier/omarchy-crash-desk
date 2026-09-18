import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Crash Desk: what crashed, how often, and a one-key handoff to an agent. The
// bar icon only shows up when there is something new since you last looked.
Panel {
  id: root
  moduleName: "cgranier.crashdesk"
  ipcTarget: "cgranier.crashdesk"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool showInBar: desk.fresh > 0 || opened || setting("alwaysShow", false) === true

  function refresh() { desk.refresh() }

  function clampCursor() {
    cursorIndex = Math.max(0, Math.min(cursorIndex, Math.max(0, desk.groups.length - 1)))
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorIndex += dy
    clampCursor()
    scrollCursorIntoView()
  }

  function selectedGroup() {
    if (desk.groups.length === 0) return null
    clampCursor()
    return desk.groups[cursorIndex]
  }

  function diagnose(group) {
    if (!group || !desk.agentAvailable) return
    desk.diagnose(group)
    root.close()
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      var item = rowColumn.children[root.cursorIndex]
      if (!item) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  visible: showInBar
  implicitWidth: showInBar ? button.implicitWidth : 0
  implicitHeight: showInBar ? button.implicitHeight : 0

  // The "new" marks stay up while you read, and clear when you close.
  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      panelFlick.contentY = 0
      desk.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      desk.markSeen()
    }
  }

  Service {
    id: desk
    settings: root.settings
  }

  Connections {
    target: desk
    function onGroupsChanged() { root.clampCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { desk.refresh(); return "ok" }
    function status(): string { return desk.summary }
    function state(): string {
      return JSON.stringify({ loaded: desk.loaded, crashes: desk.crashes.length, programs: desk.groups.length,
        fresh: desk.fresh, seenMs: desk.seenMs, agent: desk.agentAvailable, days: desk.days })
    }
    function markSeen(): string { desk.markSeen(); return "ok" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: desk.fresh > 0 && !root.vertical ? Model.GLYPHS.crash + " " + desk.fresh : Model.GLYPHS.crash
    active: desk.fresh > 0
    dimmed: desk.fresh === 0
    tooltipText: root.opened ? "" : (desk.fresh > 0 ? desk.fresh + " new · " : "") + desk.summary

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) desk.markSeen()
      else if (buttonCode === Qt.MiddleButton) desk.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; root.clampCursor(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.diagnose(root.selectedGroup())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") desk.refresh()
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "c" || t === "C") desk.copyReport(root.selectedGroup())
        else if (t === "i" || t === "I") { desk.showInfo(root.selectedGroup()); root.close() }
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

          PanelHero {
            width: parent.width
            title: "Crash Desk"
            meta: desk.summary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: desk.crashes.length > 0 ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.GLYPHS.crash
                color: desk.fresh > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: desk.actionStatus !== "" ? desk.actionStatus
              : !desk.agentAvailable && desk.loaded ? "No default coding agent is set, so diagnosis is off. Pick one in the Omarchy menu."
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: desk.loaded && desk.groups.length === 0
            width: parent.width
            text: "Nothing has crashed. Enjoy it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: rowColumn
            visible: desk.groups.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: desk.groups

              CursorSurface {
                id: surface
                required property var modelData
                required property int index

                width: rowColumn.width
                hasCursor: root.cursorActive && root.cursorIndex === index
                foreground: root.foreground
                implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.cursorIndex = surface.index }
                  onClicked: root.diagnose(surface.modelData)
                }

                RowLayout {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    text: surface.modelData.newestWithCore ? Model.GLYPHS.core : Model.GLYPHS.noCore
                    color: root.foreground
                    opacity: surface.modelData.newestWithCore ? 1.0 : 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Style.space(18)
                    horizontalAlignment: Text.AlignHCenter
                  }

                  ColumnLayout {
                    id: content
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: surface.modelData.name + (surface.modelData.fresh > 0 ? "  · " + surface.modelData.fresh + " new" : "")
                      color: surface.modelData.fresh > 0 ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: Model.groupMeta(surface.modelData, desk.now)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: desk.groups.length > 0
            width: parent.width
            text: (desk.agentAvailable ? "enter diagnose · " : "") + "i details · c copy report · r refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
