import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Agent Usage Tracker popup.
//
// Built from Omarchy's shell UI kit — PanelHero, PanelActionButton,
// BorderSurface, KeyboardPanel, and the Style spacing/type tokens — so the
// popup follows the active theme exactly like a first-party panel instead of
// hand-rolled chrome. Surfaces are a few percent of the foreground, so the
// cards lighten on dark themes and darken on light ones without leaving the
// theme's palette.
Panel {
  id: root
  moduleName: "davedes.agent-usage-tracker"
  ipcTarget: "davedes.agent-usage-tracker"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var stats: ({})
  property string windowKey: "today"

  Component.onCompleted: {
    // Pull stats from the host widget if available
    if (hostWidget && typeof hostWidget.stats !== "undefined") {
      stats = hostWidget.stats
    }
  }
  // ---- theme-derived colours
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color textDim1: Qt.darker(contentForeground, 1.5)
  readonly property color textDim2: Qt.darker(contentForeground, 1.85)
  readonly property color accentColor: Commons.Color.accent
  readonly property color trackFill: Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.11)

  // ---- surfaces
  // Subtle tinted cards that work on both light and dark themes: the overlay
  // is a few percent of the foreground, so it lightens on dark and darkens on
  // light without ever leaving the theme's palette.
  readonly property color cardFill: Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.05)
  readonly property color cardBorder: Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.09)
  readonly property color hoverFill: Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.07)
  readonly property color accentSoft: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.14)
  readonly property real cardRadius: Math.max(8, Style.cornerRadius)

  // Short logo-ish badge for a provider row: two letters at most, so the row
  // reads at a glance without a full logo asset.
  function providerBadge(name) {
    var n = String(name || "").toLowerCase()
    if (n.indexOf("google") === 0) return "G"
    if (n.indexOf("openrouter") === 0) return "R"
    if (n.indexOf("opencode") === 0) return "C"
    if (n.indexOf("groq") === 0) return "Q"
    if (n.indexOf("ollama") === 0) return "O"
    if (n.indexOf("openai") === 0) return "AI"
    if (n.indexOf("anthropic") === 0) return "A"
    if (n.indexOf("deepseek") === 0) return "D"
    return (n.charAt(0) || "?").toUpperCase()
  }

  function n(value) {
    var x = Number(value)
    return isFinite(x) ? x : 0
  }

  function refresh() {
    if (hostWidget && typeof hostWidget.refresh === "function") hostWidget.refresh()
  }

  function scrollFlick(dy) {
    var max = Math.max(0, scroller.contentHeight - scroller.height)
    scroller.contentY = dy > 0
      ? Math.min(max, scroller.contentY + Style.space(46))
      : Math.max(0, scroller.contentY - Style.space(46))
  }

  // ---- data views
  readonly property bool hasData: !!(stats && stats.windows)
  readonly property var windows: hasData ? stats.windows : ({})
  readonly property var w: windows[windowKey] || ({})

  readonly property real wSpend: n(w.cost)
  readonly property real wProcessed: n(w.input) + n(w.output) + n(w.reasoning)
  readonly property real wCache: n(w.cache_read) + n(w.cache_write)
  readonly property int wSessions: n(w.sessions)

  readonly property string windowLabel: windowKey === "today" ? "TODAY"
    : windowKey === "week" ? "LAST 7 DAYS"
    : windowKey === "month" ? "LAST 30 DAYS"
    : "LIFETIME"

  readonly property string updatedLabel: hasData
    ? Model.fmtAgo(stats.generated_at || 0).toUpperCase()
    : ""

  readonly property var providerRows: {
    var _ = windowKey
    if (!hasData) return []
    var byWindow = stats.providers_by_window
    if (byWindow && byWindow[windowKey]) return byWindow[windowKey]
    // Older collector output only carried the today and all-time lists.
    if (windowKey === "today") return stats.providers_today || []
    return stats.providers || []
  }
  readonly property real providerTotalCost: {
    var total = 0
    for (var i = 0; i < providerRows.length; i++) total += n(providerRows[i].cost)
    return total
  }
  readonly property real providerTotalTokens: {
    var total = 0
    for (var i = 0; i < providerRows.length; i++)
      total += n(providerRows[i].input) + n(providerRows[i].output)
    return total
  }

  function rowShare(row) {
    if (providerTotalCost > 0) return Model.pct(n(row.cost), providerTotalCost)
    return Model.pct(n(row.input) + n(row.output), providerTotalTokens)
  }

  readonly property var modelRows: {
    var _ = windowKey
    return hasData ? (stats.models[windowKey] || []) : []
  }
  readonly property real modelMaxTokens: {
    var best = 0
    for (var i = 0; i < modelRows.length; i++) {
      var t = n(modelRows[i].input) + n(modelRows[i].output)
      if (t > best) best = t
    }
    return best
  }
  function modelShare(row) {
    if (modelMaxTokens <= 0) return 0
    return Model.pct(n(row.input) + n(row.output), modelMaxTokens)
  }
  readonly property var recentRows: hasData ? (stats.recent || []) : []
  readonly property var or: (hasData && stats.openrouter) ? stats.openrouter : ({})

  readonly property real orRemaining: Math.max(0, n(or.credits_total) - n(or.credits_used))
  readonly property real orBudget: n(or.budget_limit)
  readonly property bool orLow: n(or.credits_total) > 0
    && orRemaining / n(or.credits_total) < 0.15

  // ---- shared bits

  component SectionTitle: Item {
    id: section
    property string text: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(sectionLabel.implicitHeight, Style.space(14))

    Rectangle {
      width: Style.space(3)
      height: Math.max(Style.space(7), sectionLabel.implicitHeight * 0.55)
      radius: width / 2
      color: root.accentColor
      opacity: 0.9
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: sectionLabel
      textFormat: Text.PlainText
      text: section.text
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
      anchors.left: parent.left
      anchors.leftMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
    }

    Rectangle {
      height: 1
      color: root.trackFill
      opacity: 0.7
      anchors.left: sectionLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component StatTile: BorderSurface {
    id: tile
    property string caption: ""
    property string value: ""
    property string sub: ""
    property bool urgent: false

    width: parent ? parent.width : 0
    radius: root.cardRadius
    color: root.cardFill
    borderSpec: Border.flat(root.cardBorder, 1)
    padding: Style.space(10)
    implicitHeight: tileCol.implicitHeight + contentTopInset + contentBottomInset

    Column {
      id: tileCol
      spacing: Style.space(2)
      anchors.left: parent.left
      anchors.leftMargin: parent.contentLeftInset
      anchors.right: parent.right
      anchors.rightMargin: parent.contentRightInset
      anchors.top: parent.top
      anchors.topMargin: parent.contentTopInset

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.caption
        color: root.textDim2
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.value
        color: tile.urgent ? Commons.Color.urgent : root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.sub
        visible: text !== ""
        color: root.textDim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component ShareTrack: Rectangle {
    id: track
    property real fraction: 0
    property color fillColor: root.contentForeground
    property real thickness: Style.space(3)
    width: parent ? parent.width : 0
    height: thickness
    radius: Math.round(thickness / 2)
    color: root.trackFill

    Rectangle {
      width: Math.max(0, Math.round(track.width * (Math.max(0, Math.min(100, track.fraction)) / 100)))
      height: parent.height
      radius: parent.radius
      color: track.fillColor
      Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    }
  }

  // Window selector pill: matches netspeed's WindowChip — selected chip uses
  // the accent fill with background-coloured text, hover state on the rest.
  component WindowChip: BorderSurface {
    id: chip
    property string caption: ""
    property string key: ""
    readonly property bool selected: root.windowKey === chip.key

    implicitWidth: chipLabel.implicitWidth + Style.space(18)
    implicitHeight: Style.space(22)
    radius: Math.round(height / 2)
    color: chip.selected
      ? root.accentColor
      : (chipMouse.containsMouse ? root.hoverFill : "transparent")
    borderSpec: chip.selected
      ? Border.controlSpec("selected", root.contentForeground, Commons.Color.accent)
      : (chipMouse.containsMouse
        ? Border.controlSpec("hover-cursor", root.contentForeground, Commons.Color.accent)
        : Border.none())
    scale: chipMouse.containsMouse && !chip.selected ? 1.035 : 1.0
    transformOrigin: Item.Center
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    Behavior on scale {
      NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
    }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.caption
      textFormat: Text.PlainText
      color: chip.selected ? Commons.Color.background : root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.selected
      font.letterSpacing: 0.6
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.windowKey = chip.key
    }
  }

  component InfoLine: Item {
    id: info
    property string label: ""
    property string value: ""
    property color valueColor: root.contentForeground
    width: parent ? parent.width : 0
    implicitHeight: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)

    Text {
      id: infoLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: info.label
      textFormat: Text.PlainText
      color: root.textDim1
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: infoValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - infoLabel.implicitWidth - Style.space(16))
      text: info.value
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      color: info.valueColor
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // Provider row with a small logo badge, hover state, and an accent share bar.
  component ProviderRow: Item {
    id: prow
    required property var rowData
    property int rank: 0
    width: parent ? parent.width : 0
    implicitHeight: prowCol.implicitHeight + Style.space(8)

    readonly property real cost: root.n(prow.rowData.cost)
    readonly property real tokens: root.n(prow.rowData.input) + root.n(prow.rowData.output)
    readonly property bool paid: prow.cost > 0

    Column {
      id: prowCol
      width: parent.width
      spacing: Style.space(4)

      Item {
        width: parent.width
        height: Math.max(prowBadge.height, prowName.implicitHeight, prowCost.implicitHeight)

        Rectangle {
          id: prowBadge
          width: Style.space(19)
          height: Style.space(19)
          radius: Math.round(Style.space(19) * 0.34)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          color: prow.paid ? root.accentSoft : root.hoverFill
          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.providerBadge(prow.rowData.name)
            color: prow.paid ? root.accentColor : root.textDim1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          id: prowName
          anchors.left: prowBadge.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: prow.rowData.name || "Unknown"
          textFormat: Text.PlainText
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          width: Math.max(0, parent.width - prowBadge.width - Style.space(8)
            - prowTokens.implicitWidth - prowCost.implicitWidth - Style.space(22))
        }
        Text {
          id: prowTokens
          anchors.right: prowCost.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: Model.fmtTokens(prow.tokens)
          textFormat: Text.PlainText
          color: root.textDim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          id: prowCost
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.fmtCost(prow.cost)
          textFormat: Text.PlainText
          color: prow.paid ? root.accentColor : root.textDim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }
      ShareTrack {
        fraction: root.rowShare(prow.rowData)
        thickness: Style.space(3)
        fillColor: prow.rank === 0
          ? root.accentColor
          : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.45)
      }
    }
  }

  component ModelRow: Item {
    id: mrow
    required property var rowData
    width: parent ? parent.width : 0
    implicitHeight: mrowCol.implicitHeight + Style.space(3)

    readonly property real tokens: root.n(mrow.rowData.input) + root.n(mrow.rowData.output)

    Column {
      id: mrowCol
      width: parent.width
      spacing: Style.space(3)

      Item {
        width: parent.width
        height: Math.max(mrowName.implicitHeight, mrowValue.implicitHeight)

        Text {
          id: mrowName
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - mrowValue.implicitWidth - Style.space(16))
          text: Model.shortModel(mrow.rowData.id)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          id: mrowValue
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.fmtTokens(mrow.tokens) + "  ·  " + Model.fmtCost(mrow.rowData.cost)
          textFormat: Text.PlainText
          color: root.textDim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ShareTrack {
        fraction: root.modelShare(mrow.rowData)
        thickness: Style.space(2)
        fillColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.55)
      }
    }
  }

  // Recent session row: a soft card that lifts on hover, with a left accent
  // bar when the session actually spent something.
  component RecentRow: Item {
    id: rrow
    required property var rowData
    width: parent ? parent.width : 0
    implicitHeight: rrowCol.implicitHeight + Style.space(8)

    Rectangle {
      anchors.fill: parent
      radius: root.cardRadius
      color: rrowHover.hovered ? root.hoverFill : "transparent"
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }
    HoverHandler { id: rrowHover }

    Rectangle {
      width: Style.space(2)
      radius: width / 2
      color: rrow.rowData.cost > 0 ? root.accentColor : root.trackFill
      opacity: rrow.rowData.cost > 0 ? 0.9 : 0.6
      anchors.left: parent.left
      anchors.leftMargin: Style.space(3)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.space(5)
      anchors.bottomMargin: Style.space(5)
    }

    Column {
      id: rrowCol
      anchors.left: parent.left
      anchors.leftMargin: Style.space(11)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: (rrow.rowData.title && rrow.rowData.title !== "") ? rrow.rowData.title : "Untitled session"
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }
      Item {
        width: parent.width
        height: Math.max(rrowMeta.implicitHeight, rrowWhen.implicitHeight)
        Text {
          id: rrowMeta
          anchors.left: parent.left
          anchors.right: rrowWhen.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: (rrow.rowData.provider || "Unknown")
            + ((rrow.rowData.model && rrow.rowData.model !== "") ? "  ·  " + Model.shortModel(rrow.rowData.model) : "")
            + "  ·  " + Model.fmtTokens(root.n(rrow.rowData.input) + root.n(rrow.rowData.output)) + " tok"
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.textDim2
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          id: rrowWhen
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.fmtCost(rrow.rowData.cost) + "  ·  " + Model.fmtAgo(rrow.rowData.updated)
          textFormat: Text.PlainText
          color: rrow.rowData.cost > 0 ? root.accentColor : root.textDim1
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: rrow.rowData.cost > 0
        }
      }
    }
  }

  // Small keycap for the footer hints.
  component KeyHint: Row {
    property string key: ""
    property string label: ""
    spacing: Style.space(4)

    Rectangle {
      id: keyCap
      width: Math.max(Style.space(18), keyText.implicitWidth + Style.space(8))
      height: Math.max(Style.space(16), keyText.implicitHeight + Style.space(4))
      radius: height / 2
      color: root.hoverFill
      border.color: root.cardBorder
      border.width: 1

      Text {
        id: keyText
        anchors.centerIn: parent
        text: key
        textFormat: Text.PlainText
        color: root.textDim1
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      height: keyCap.height
      verticalAlignment: Text.AlignVCenter
      text: label
      textFormat: Text.PlainText
      color: root.textDim2
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ------------------------------------------------------------ popup body

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(contentCol.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.scrollFlick(dy) }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "1") root.windowKey = "today"
        else if (t === "2") root.windowKey = "week"
        else if (t === "3") root.windowKey = "month"
        else if (t === "4") root.windowKey = "all"
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: contentCol.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar {
          id: vScroll
          policy: ScrollBar.AsNeeded
          width: Style.spacing.sm
        }

        Column {
          id: contentCol
          width: parent.width
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: vScroll.width
          spacing: Style.spacing.xxl

          // ---- Hero
          PanelHero {
            id: hero
            width: parent.width
            title: "Agent Usage"
            meta: root.hasData
              ? root.windowLabel + "  ·  " + root.wSessions + (root.wSessions === 1 ? " SESSION" : " SESSIONS") + "  ·  " + root.updatedLabel
              : "COLLECTING USAGE"
            detail: (root.hasData && root.or.ok === true) ? Model.fmtCost(root.orRemaining) + " left" : ""
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconOpacity: root.hasData ? 1.0 : 0.5

            iconComponent: Component {
              Rectangle {
                width: Style.space(36)
                height: Style.space(36)
                radius: Math.round(Style.space(36) * 0.30)
                color: root.accentSoft
                border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
                border.width: 1
                Text {
                  anchors.centerIn: parent
                  text: "󰚩"
                  textFormat: Text.PlainText
                  color: root.accentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xxs

                PanelActionButton {
                  iconText: "󰑓"
                  tooltipText: "Refresh (R)"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: root.refresh()
                }
                PanelActionButton {
                  iconText: "󰅖"
                  tooltipText: "Close (Esc)"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: root.close()
                }
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Window picker + headline figures
          Column {
            width: parent.width
            spacing: Style.spacing.lg

            Item {
              width: parent.width
              height: Math.max(chipsRow.implicitHeight, lifetimeText.implicitHeight)

              Row {
                id: chipsRow
                spacing: Style.spacing.sm
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter

                Repeater {
                  model: [
                    { caption: "Today", key: "today" },
                    { caption: "7 days", key: "week" },
                    { caption: "30 days", key: "month" },
                    { caption: "All", key: "all" }
                  ]
                  delegate: WindowChip {
                    required property var modelData
                    caption: modelData.caption
                    key: modelData.key
                  }
                }
              }

              Text {
                id: lifetimeText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.hasData ? "Lifetime " + Model.fmtCost(root.n((root.windows.all || {}).cost)) : ""
                textFormat: Text.PlainText
                color: root.textDim2
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              StatTile {
                width: Math.max(0, (parent.width - Style.spacing.sm * 2) / 3)
                caption: "SPEND"
                value: root.hasData ? Model.fmtCost(root.wSpend) : "—"
                sub: root.hasData
                  ? (root.wSessions > 0 ? Model.fmtCost(root.wSpend / root.wSessions) + " / session" : "no sessions")
                  : ""
                urgent: root.wSpend >= 5
              }
              StatTile {
                width: Math.max(0, (parent.width - Style.spacing.sm * 2) / 3)
                caption: "TOKENS"
                value: root.hasData ? Model.fmtTokens(root.wProcessed) : "—"
                sub: root.hasData && root.wCache > 0 ? Model.fmtTokens(root.wCache) + " cached" : "in + out"
              }
              StatTile {
                width: Math.max(0, (parent.width - Style.spacing.sm * 2) / 3)
                caption: "SESSIONS"
                value: root.hasData ? Model.fmtInt(root.wSessions) : "—"
                sub: root.hasData && root.providerRows.length > 0 ? root.providerRows.length + " providers" : ""
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Providers
          Column {
            width: parent.width
            spacing: Style.spacing.md

            SectionTitle {
              text: "PROVIDERS  ·  " + root.windowLabel
            }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.providerRows.length > 0

              Repeater {
                model: root.providerRows
                delegate: ProviderRow {
                  required property var modelData
                  required property int index
                  rowData: modelData
                  rank: index
                }
              }
            }

            Text {
              width: parent.width
              visible: root.hasData && root.providerRows.length === 0
              text: "No provider activity in this window."
              textFormat: Text.PlainText
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- OpenRouter
          Column {
            width: parent.width
            spacing: Style.spacing.md

            SectionTitle { text: "OPENROUTER" }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.or.ok === true

              BorderSurface {
                width: parent.width
                radius: root.cardRadius
                color: root.cardFill
                borderSpec: Border.flat(root.cardBorder, 1)
                padding: Style.space(12)
                implicitHeight: orcCardCol.implicitHeight + contentTopInset + contentBottomInset

                Column {
                  id: orcCardCol
                  anchors.left: parent.left
                  anchors.leftMargin: parent.contentLeftInset
                  anchors.right: parent.right
                  anchors.rightMargin: parent.contentRightInset
                  anchors.top: parent.top
                  anchors.topMargin: parent.contentTopInset
                  spacing: Style.spacing.md

                  Item {
                    width: parent.width
                    height: Math.max(orcLeft.implicitHeight, orcRight.implicitHeight)

                    Column {
                      id: orcLeft
                      anchors.left: parent.left
                      spacing: Style.space(1)

                      Text {
                        textFormat: Text.PlainText
                        text: "REMAINING"
                        color: root.textDim2
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1.2
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: Model.fmtCost(root.orRemaining)
                        color: root.orLow ? Commons.Color.urgent : root.accentColor
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.display
                        font.bold: true
                      }
                    }

                    Column {
                      id: orcRight
                      anchors.right: parent.right
                      spacing: Style.space(1)

                      Text {
                        textFormat: Text.PlainText
                        text: "USED"
                        horizontalAlignment: Text.AlignRight
                        color: root.textDim2
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1.2
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: Model.fmtCost(root.n(root.or.credits_used))
                        horizontalAlignment: Text.AlignRight
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                    }
                  }

                  ShareTrack {
                    fraction: Model.pct(root.n(root.or.credits_used), root.n(root.or.credits_total))
                    fillColor: root.orLow ? Commons.Color.urgent : root.accentColor
                    thickness: Style.space(5)
                  }

                  InfoLine {
                    visible: root.n(root.or.daily) > 0 || root.n(root.or.weekly) > 0 || root.n(root.or.monthly) > 0
                    label: "Key usage (day / week / month)"
                    value: Model.fmtCost(root.n(root.or.daily)) + "  ·  "
                      + Model.fmtCost(root.n(root.or.weekly)) + "  ·  "
                      + Model.fmtCost(root.n(root.or.monthly))
                  }

                  InfoLine {
                    visible: root.n(root.or.free_limit) > 0
                    label: "Free models today"
                    value: Model.fmtInt(root.n(root.or.free_used)) + " / " + Model.fmtInt(root.n(root.or.free_limit))
                  }

                  ShareTrack {
                    visible: root.n(root.or.free_limit) > 0
                    fraction: Model.pct(root.n(root.or.free_used), root.n(root.or.free_limit))
                    fillColor: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.45)
                    thickness: Style.space(3)
                  }

                  InfoLine {
                    visible: root.orBudget > 0
                    label: "Budget"
                    value: Model.fmtCost(root.n(root.or.budget_spend)) + " of " + Model.fmtCost(root.orBudget)
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.hasData && root.or.ok !== true
              text: root.or.error ? ("OpenRouter unavailable — " + root.or.error) : "OpenRouter is not configured."
              textFormat: Text.PlainText
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Top models
          Column {
            width: parent.width
            spacing: Style.spacing.md

            SectionTitle { text: "TOP MODELS  ·  " + root.windowLabel }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.modelRows.length > 0

              Repeater {
                model: root.modelRows
                delegate: ModelRow {
                  required property var modelData
                  rowData: modelData
                }
              }
            }

            Text {
              width: parent.width
              visible: root.hasData && root.modelRows.length === 0
              text: "No model activity in this window."
              textFormat: Text.PlainText
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Recent sessions
          Column {
            width: parent.width
            spacing: Style.spacing.md

            SectionTitle { text: "RECENT SESSIONS" }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.recentRows.length > 0

              Repeater {
                model: root.recentRows
                delegate: RecentRow {
                  required property var modelData
                  rowData: modelData
                }
              }
            }

            Text {
              width: parent.width
              visible: root.hasData && root.recentRows.length === 0
              text: "No sessions recorded yet."
              textFormat: Text.PlainText
              color: root.textDim2
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---- Footer hint
          Item {
            width: parent.width
            implicitHeight: footerRow.implicitHeight

            Row {
              id: footerRow
              anchors.centerIn: parent
              spacing: Style.spacing.md

              KeyHint { key: "R"; label: "refresh" }
              KeyHint { key: "1–4"; label: "window" }
              KeyHint { key: "Esc"; label: "close" }
            }
          }
        }
      }
    }
  }
}