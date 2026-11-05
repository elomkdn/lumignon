import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

// One quota window on a single line. The small tick marks how much of the window
// has gone by: a bar ahead of its tick means you are consuming faster than the pace.
RowLayout {
    id: meter

    required property string title
    required property var windowData
    required property real windowLength
    required property real used
    required property real now
    required property string resetPhrase

    readonly property real elapsed: windowLength > 0 && windowData && windowData.resetsAt > now
        ? Math.max(0, Math.min(1, 1 - (windowData.resetsAt - now) / windowLength)) : 0
    readonly property color barColor: used >= 0.9 ? Kirigami.Theme.negativeTextColor
        : used >= 0.7 ? Kirigami.Theme.neutralTextColor : "#F2762E"

    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true

    HoverHandler { id: hover }
    PC3.ToolTip.text: !windowData ? i18n("Not measured yet") : resetPhrase
    PC3.ToolTip.visible: hover.hovered
    PC3.ToolTip.delay: Kirigami.Units.toolTipDelay

    PC3.Label {
        text: meter.title
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }
    Item {
        Layout.fillWidth: true
        implicitHeight: 8

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1
            anchors.bottomMargin: 1
            radius: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.14)
            Rectangle {
                width: parent.width * Math.min(1, meter.used)
                height: parent.height
                radius: 1
                color: meter.barColor
                Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
            }
        }
        Rectangle {
            visible: meter.elapsed > 0
            x: Math.round(parent.width * meter.elapsed) - 1
            width: 2
            height: parent.height
            color: Kirigami.Theme.textColor
        }
    }
    PC3.Label {
        text: meter.windowData ? i18nc("a share of the quota", "%1%", Math.round(meter.used * 100)) : "—"
        font.features: { "tnum": 1 }
    }
}
