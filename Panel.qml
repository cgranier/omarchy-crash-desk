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
  property var expanded: []        // exe paths opened to show each crash
  property bool pickingAgent: false
  property int agentIndex: 0
  property var pickFor: null       // the row an agent is being picked for

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool showInBar: desk.fresh > 0 || opened || setting("alwaysShow", false) === true

  readonly property var rows: Model.buildRows(desk.groups, desk.mutedGroups, expanded)
  readonly property var cursorRows: Model.cursorRows(rows)

  function refresh() { desk.refresh() }

  function clampCursor() {
    cursorIndex = Math.max(0, Math.min(cursorIndex, Math.max(0, cursorRows.length - 1)))
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorIndex += dy
    clampCursor()
    scrollCursorIntoView()
  }

  function selectedRow() {
    if (cursorRows.length === 0) return null
    clampCursor()
    return cursorRows[cursorIndex]
  }

  function selectedGroup() {
    var row = selectedRow()
    return row ? row.group : null
  }

  // A program row diagnoses from its best crash; a crash row, that crash.
  function diagnose(row) {
    if (!row || !desk.agentAvailable) return
    desk.diagnose(row.group, row.type === "crash" ? row.crash : null)
    root.close()
  }

  function setExpanded(exe, open) {
    var next = expanded.filter(function(e) { return e !== exe })
    if (open) next.push(exe)
    expanded = next
    // Keep the cursor on the same program when its crashes fold away.
    clampCursor()
    scrollCursorIntoView()
  }

  function toggleExpanded(row) {
    if (!row || row.muted) return
    setExpanded(row.group.exe, !(expanded.indexOf(row.group.exe) !== -1))
  }

  function expandKey(open) {
    var row = selectedRow()
    if (!row) return
    if (row.type === "crash") {
      if (!open) { setExpanded(row.group.exe, false); moveCursorToGroup(row.group) }
      return
    }
    setExpanded(row.group.exe, open)
  }

  function moveCursorToGroup(group) {
    for (var i = 0; i < cursorRows.length; i++) {
      if (cursorRows[i].type === "group" && cursorRows[i].group.exe === group.exe) { cursorIndex = i; return }
    }
  }

  function startPick(row) {
    if (!row || desk.installedAgents.length === 0) return
    pickFor = row
    agentIndex = Math.max(0, desk.installedAgents.indexOf(desk.defaultAgent))
    pickingAgent = true
  }

  function finishPick() {
    var agent = desk.installedAgents[agentIndex]
    var row = pickFor
    pickingAgent = false
    pickFor = null
    if (!agent || !row) return
    desk.diagnoseWith(agent, row.group, row.type === "crash" ? row.crash : null)
    root.close()
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      for (var i = 0; i < rowColumn.children.length; i++) {
        var item = rowColumn.children[i]
        if (!item || item.cursorIndex !== root.cursorIndex) continue
        var margin = Style.space(6)
        var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
        var bottom = top + item.height
        var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
        if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
        else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
        return
      }
    })
  }

  visible: showInBar
  implicitWidth: showInBar ? button.implicitWidth : 0
  implicitHeight: showInBar ? button.implicitHeight : 0

  // The "new" marks stay up while you read, and clear when you close.
  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      pickingAgent = false
      panelFlick.contentY = 0
      desk.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      pickingAgent = false
      desk.markSeen()
    }
  }

  Service {
    id: desk
    settings: root.settings
  }

  onCursorRowsChanged: clampCursor()

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
        muted: desk.muted, fresh: desk.fresh, seenMs: desk.seenMs, agent: desk.defaultAgent, agents: desk.installedAgents,
        days: desk.windowDays(), frames: Object.keys(desk.frames).length, rows: root.rows.length })
    }
    function markSeen(): string { desk.markSeen(); return "ok" }
    function range(): string { desk.cycleRange(); return String(desk.windowDays()) }
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
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.pickingAgent) {
          if (dy !== 0) root.agentIndex = Math.max(0, Math.min(desk.installedAgents.length - 1, root.agentIndex + dy))
          return
        }
        if (dx !== 0) { root.expandKey(dx > 0); return }
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; root.clampCursor(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.pickingAgent) root.finishPick()
        else if (root.cursorActive) root.diagnose(root.selectedRow())
      }
      onCloseRequested: {
        if (root.pickingAgent) { root.pickingAgent = false; root.pickFor = null }
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.pickingAgent) {
          if (t === "j") root.agentIndex = Math.min(desk.installedAgents.length - 1, root.agentIndex + 1)
          else if (t === "k") root.agentIndex = Math.max(0, root.agentIndex - 1)
          return
        }
        if (t === "r" || t === "R") desk.refresh()
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "l") root.expandKey(true)
        else if (t === "h") root.expandKey(false)
        else if (t === " ") root.toggleExpanded(root.selectedRow())
        else if (t === "m" || t === "M") {
          // The program moves between the list and the footer; follow it.
          var muteGroup = root.selectedGroup()
          desk.toggleMute(muteGroup)
          if (muteGroup) Qt.callLater(function() { root.moveCursorToGroup(muteGroup); root.scrollCursorIntoView() })
        }
        else if (t === "t" || t === "T") desk.cycleRange()
        else if (t === "a" || t === "A") root.startPick(root.selectedRow())
        else if (t === "c" || t === "C") desk.copyReport(root.selectedGroup())
        else if (t === "i" || t === "I") {
          var row = root.selectedRow()
          if (row) { desk.showInfo(row.group, row.type === "crash" ? row.crash : null); root.close() }
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
              : !desk.agentAvailable && desk.loaded ? "No default coding agent is set: enter is off, but a picks any installed agent."
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: desk.loaded && root.rows.length === 0
            width: parent.width
            text: "Nothing has crashed. Enjoy it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          // ---- agent picker ----------------------------------------------
          Column {
            visible: root.pickingAgent
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader {
              text: "DIAGNOSE WITH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.pickingAgent ? desk.installedAgents : []

              CursorSurface {
                id: agentSurface
                required property var modelData
                required property int index
                width: parent.width
                hasCursor: root.agentIndex === index
                foreground: root.foreground
                implicitHeight: agentText.implicitHeight + Style.space(12)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.agentIndex = agentSurface.index
                  onClicked: { root.agentIndex = agentSurface.index; root.finishPick() }
                }

                Text {
                  id: agentText
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.agentName(agentSurface.modelData) + (agentSurface.modelData === desk.defaultAgent ? "  · default" : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }

          // ---- programs and their crashes ----------------------------------
          Column {
            id: rowColumn
            visible: root.rows.length > 0 && !root.pickingAgent
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              Loader {
                required property var modelData
                readonly property int cursorIndex: modelData.cursorIndex === undefined ? -1 : modelData.cursorIndex
                width: rowColumn.width
                sourceComponent: modelData.type === "header" ? headerRow : modelData.type === "crash" ? crashRow : groupRow
                onLoaded: item.row = modelData
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.rows.length > 0
            width: parent.width
            text: root.pickingAgent ? "enter launch · esc back"
              : (desk.agentAvailable ? "enter diagnose · " : "") + "a pick agent · l/h open/close · m mute · t " + Model.rangeLabel(desk.windowDays()) + " · i details · c copy"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  Component {
    id: headerRow

    Item {
      property var row: null
      implicitHeight: headerText.implicitHeight + Style.space(10)

      PanelSectionHeader {
        id: headerText
        anchors.bottom: parent.bottom
        text: row ? row.text : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  Component {
    id: groupRow

    CursorSurface {
      id: surface
      property var row: null
      readonly property var group: row ? row.group : null
      readonly property bool muted: row ? row.muted : false

      hasCursor: root.cursorActive && row !== null && root.cursorIndex === row.cursorIndex
      foreground: root.foreground
      implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
      opacity: muted ? 0.55 : 1.0

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (surface.row) { root.cursorActive = true; root.cursorIndex = surface.row.cursorIndex }
        onClicked: root.toggleExpanded(surface.row)
        onDoubleClicked: root.diagnose(surface.row)
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
          text: !surface.group ? "" : surface.muted ? Model.GLYPHS.muted : surface.row.open ? Model.GLYPHS.open : Model.GLYPHS.closed
          color: root.foreground
          opacity: 0.6
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
            text: !surface.group ? "" : surface.group.name + (surface.group.fresh > 0 && !surface.muted ? "  · " + surface.group.fresh + " new" : "")
            color: surface.group && surface.group.fresh > 0 && !surface.muted ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: surface.group ? Model.groupMeta(surface.group, desk.now) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // Where the newest crash died, once coredumpctl info has answered.
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== "" && !(surface.row && surface.row.open)
            text: surface.group ? desk.frameFor(surface.group.newest) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }
      }
    }
  }

  Component {
    id: crashRow

    CursorSurface {
      id: crashSurface
      property var row: null
      readonly property var crash: row ? row.crash : null

      hasCursor: root.cursorActive && row !== null && root.cursorIndex === row.cursorIndex
      foreground: root.foreground
      implicitHeight: crashContent.implicitHeight + Style.space(10)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (crashSurface.row) { root.cursorActive = true; root.cursorIndex = crashSurface.row.cursorIndex }
        onClicked: root.diagnose(crashSurface.row)
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(34)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: crashSurface.crash ? (crashSurface.crash.hasCore ? Model.GLYPHS.core : Model.GLYPHS.noCore) : ""
          color: root.foreground
          opacity: crashSurface.crash && crashSurface.crash.hasCore ? 1.0 : 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(14)
          horizontalAlignment: Text.AlignHCenter
        }

        ColumnLayout {
          id: crashContent
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: crashSurface.crash ? Model.crashMeta(crashSurface.crash, "", desk.now) : ""
            color: crashSurface.crash && crashSurface.crash.timeMs > desk.seenMs ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: text !== ""
            text: crashSurface.crash ? desk.frameFor(crashSurface.crash) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }
      }
    }
  }
}
