import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

// The popup is exactly as tall as what it shows: a small bar when idle, and it
// only grows with the conversation. Fixed bounds also override the size that
// Plasma saves for popups.
ColumnLayout {
    id: full

    required property var app

    readonly property int popupWidth: Kirigami.Units.gridUnit * 18
    readonly property int maxConversationHeight: Kirigami.Units.gridUnit * 14
    readonly property int maxDay: Math.max.apply(null, app.days.concat([1]))
    readonly property string paceWarning: {
        const w = app.mainWindow
        const used = app.usedMain
        if (!w || !w.length || w.resetsAt <= app.now || used <= 0 || app.limited) return ""
        const elapsed = 1 - (w.resetsAt - app.now) / w.length
        if (elapsed < 0.15) return ""
        const emptyIn = (1 - used) * (elapsed * w.length / used)
        if (app.now + emptyIn >= w.resetsAt) return ""
        return i18n("Out of quota around %1 at this pace", new Date((app.now + emptyIn) * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
    }
    readonly property string infoText: {
        if (app.busy) return app.activity || i18n("%1 is thinking…", app.agentName)
        if (paceWarning) return paceWarning
        let text = i18n("%1 tokens today", formatTokens(app.days[6] || 0))
        if (app.current.costToday > 0)
            text += " · " + Number(app.current.costToday).toLocaleString(Qt.locale(), "f", 2) + " $"
        if (!app.hasQuota) return i18n("No known limit · %1", text)
        const w = app.mainWindow
        return w && w.resetsAt > app.now ? app.resetPhrase(w) + " · " + text : text
    }

    Layout.minimumWidth: popupWidth
    Layout.preferredWidth: popupWidth
    Layout.maximumWidth: popupWidth
    Layout.minimumHeight: implicitHeight
    Layout.preferredHeight: implicitHeight
    Layout.maximumHeight: implicitHeight
    spacing: Kirigami.Units.smallSpacing

    function formatTokens(n) {
        if (n >= 1000000) return Number(n / 1000000).toLocaleString(Qt.locale(), "f", 1) + " M"
        if (n >= 1000) return Math.round(n / 1000) + " k"
        return String(n)
    }
    function send() {
        if (app.busy || !input.text.trim()) return
        app.ask(input.text)
        input.clear()
    }
    // An answer can carry text written by someone else (a web page, a file): outside code,
    // images become plain links, so that nothing is fetched without a click.
    function safeMarkdown(text) {
        const parts = text.split(new RegExp("(```[\\s\\S]*?(?:```|$)|~~~[\\s\\S]*?(?:~~~|$)|`[^`\\n]*`)"))
        return parts.map((part, i) => i % 2 ? part
            : part.split("![").join("[").replace(new RegExp("<img", "gi"), "&lt;img")).join("")
    }

    Connections {
        target: full.app
        function onExpandedChanged() {
            if (full.app.expanded) input.forceActiveFocus()
        }
        function onAgentChanged() {
            agentBar.currentIndex = full.app.installedAgents.indexOf(full.app.agent)
        }
    }
    Component.onCompleted: input.forceActiveFocus()

    // ---- Agent switch ----
    PC3.TabBar {
        id: agentBar
        visible: full.app.installedAgents.length > 1
        Layout.fillWidth: true
        currentIndex: full.app.installedAgents.indexOf(full.app.agent)

        Repeater {
            model: full.app.installedAgents
            PC3.TabButton {
                required property string modelData
                text: full.app.agentNames[modelData]
                enabled: !full.app.busy || modelData === full.app.agent
                onClicked: full.app.setAgent(modelData)
            }
        }
    }

    // ---- Usage of the current agent ----
    RowLayout {
        visible: full.app.hasQuota
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        Repeater {
            model: full.app.windows
            UsageMeter {
                required property var modelData
                title: full.app.windowLabel(modelData)
                windowData: modelData
                windowLength: modelData.length || 0
                used: full.app.currentUse(modelData)
                now: full.app.now
                resetPhrase: full.app.resetPhrase(modelData)
                Layout.preferredWidth: 1
            }
        }
    }

    // ---- What is going on: activity, pace warning, or reset and tokens ----
    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        Candle {
            visible: full.app.busy
            mood: "think"
            level: 1 - full.app.usedMain
            Layout.preferredWidth: 15
            Layout.preferredHeight: 9
        }
        PC3.Label {
            text: full.infoText
            color: !full.app.busy && full.paceWarning ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
            opacity: !full.app.busy && full.paceWarning ? 1 : 0.7
            font: Kirigami.Theme.smallFont
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Row {  // the last 7 days
            spacing: 1
            Layout.alignment: Qt.AlignBottom
            Repeater {
                model: 7
                Item {
                    required property int index
                    width: 4
                    height: 12
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(1, Math.round(12 * (full.app.days[parent.index] || 0) / full.maxDay))
                        color: "#F2762E"
                        opacity: parent.index === 6 ? 1 : 0.5
                    }
                }
            }
        }
    }

    // ---- Conversation, only when there is one ----
    PC3.ScrollView {
        visible: full.app.messages.count > 0
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(list.contentHeight, full.maxConversationHeight)

        ListView {
            id: list
            model: full.app.messages
            clip: true
            spacing: Kirigami.Units.smallSpacing
            onCountChanged: Qt.callLater(positionViewAtEnd)
            onContentHeightChanged: if (atYEnd || full.app.busy) Qt.callLater(positionViewAtEnd)

            delegate: Item {
                id: bubbleRow
                required property string role
                required property string text
                readonly property bool mine: role === "user"

                width: ListView.view.width - Kirigami.Units.largeSpacing
                implicitHeight: role === "agent" && text === "" ? 0 : bubble.height

                Rectangle {
                    id: bubble
                    anchors.right: bubbleRow.mine ? parent.right : undefined
                    width: bubbleRow.mine
                        ? Math.min(parent.width * 0.85, content.implicitWidth + Kirigami.Units.largeSpacing * 2)
                        : parent.width
                    height: content.height + Kirigami.Units.smallSpacing * 2
                    radius: 3
                    color: bubbleRow.role === "error" ? Qt.rgba(Kirigami.Theme.negativeTextColor.r, Kirigami.Theme.negativeTextColor.g, Kirigami.Theme.negativeTextColor.b, 0.15)
                        : bubbleRow.mine ? Qt.rgba(0.95, 0.46, 0.18, 0.2)
                        : "transparent"

                    TextEdit {
                        id: content
                        x: bubbleRow.mine ? Kirigami.Units.largeSpacing : Kirigami.Units.smallSpacing
                        y: Kirigami.Units.smallSpacing
                        width: bubble.width - x * 2
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        color: Kirigami.Theme.textColor
                        selectionColor: Kirigami.Theme.highlightColor
                        selectedTextColor: Kirigami.Theme.highlightedTextColor
                        font: Kirigami.Theme.defaultFont
                        textFormat: bubbleRow.role === "agent" ? TextEdit.MarkdownText : TextEdit.PlainText
                        text: bubbleRow.role === "agent" ? full.safeMarkdown(bubbleRow.text) : bubbleRow.text
                        onLinkActivated: (link) => {
                            if (link.startsWith("https://") || link.startsWith("http://")) Qt.openUrlExternally(link)
                        }
                        HoverHandler {
                            enabled: parent.hoveredLink !== ""
                            cursorShape: Qt.PointingHandCursor
                        }
                        // where a link really goes, whatever its text says
                        PC3.ToolTip.text: hoveredLink
                        PC3.ToolTip.visible: hoveredLink !== ""
                    }
                }
            }
        }
    }

    // ---- Question ----
    PC3.ScrollView {
        Layout.fillWidth: true
        Layout.maximumHeight: Kirigami.Units.gridUnit * 5

        PC3.TextArea {
            id: input
            placeholderText: full.app.limited ? i18n("Limit reached…") : i18n("Ask %1…", full.app.agentName)
            wrapMode: TextEdit.Wrap
            Keys.onPressed: (event) => {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                    event.accepted = true
                    full.send()
                }
            }
        }
    }

    // ---- Tools ----
    RowLayout {
        Layout.fillWidth: true
        spacing: 0

        PC3.ComboBox {
            visible: full.app.agent === "claude"
            model: [
                { value: "", label: i18nc("the agent's default model", "Default") },
                { value: "haiku", label: "Haiku" },
                { value: "sonnet", label: "Sonnet" },
                { value: "opus", label: "Opus" }
            ]
            textRole: "label"
            valueRole: "value"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(full.app.model))
            onActivated: Plasmoid.configuration.model = currentValue
        }
        Item { Layout.fillWidth: true }
        PC3.ToolButton {
            icon.name: "view-refresh"
            enabled: !full.app.refreshing
            display: PC3.AbstractButton.IconOnly
            text: i18n("Refresh usage")
            PC3.ToolTip.text: full.app.agent === "claude" ? i18n("Refresh usage (a tiny Haiku request)") : text
            PC3.ToolTip.visible: hovered
            PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
            onClicked: full.app.refreshNow()
        }
        PC3.ToolButton {
            icon.name: "list-add"
            enabled: !full.app.busy && full.app.messages.count > 0
            display: PC3.AbstractButton.IconOnly
            text: i18n("New conversation")
            PC3.ToolTip.text: text
            PC3.ToolTip.visible: hovered
            PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
            onClicked: full.app.newConversation()
        }
        PC3.ToolButton {
            icon.name: "utilities-terminal"
            display: PC3.AbstractButton.IconOnly
            text: full.app.session ? i18n("Continue in a terminal") : i18n("Open %1 in a terminal", full.app.agentName)
            PC3.ToolTip.text: i18n("%1 (here, the agent can only read and search)", text)
            PC3.ToolTip.visible: hovered
            PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
            onClicked: {
                full.app.openTerminal()
                full.app.expanded = false
            }
        }
        PC3.ToolButton {
            icon.name: full.app.busy ? "process-stop" : "document-send"
            enabled: full.app.busy || input.text.trim() !== ""
            display: PC3.AbstractButton.IconOnly
            text: full.app.busy ? i18n("Stop") : i18n("Send")
            PC3.ToolTip.text: text
            PC3.ToolTip.visible: hovered
            PC3.ToolTip.delay: Kirigami.Units.toolTipDelay
            onClicked: full.app.busy ? full.app.stop() : full.send()
        }
    }
}
