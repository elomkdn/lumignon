import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid

MouseArea {
    id: compact

    required property var app
    readonly property bool horizontal: Plasmoid.formFactor === 2  // PlasmaCore.Types.Horizontal
    readonly property bool inPanel: Plasmoid.formFactor === 2 || Plasmoid.formFactor === 3

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    onContainsMouseChanged: app.hovered = containsMouse
    onClicked: (mouse) => {
        if (mouse.button === Qt.MiddleButton) app.openTerminal()
        else app.expanded = !app.expanded
    }

    Layout.minimumWidth: horizontal ? candle.width : -1
    Layout.preferredWidth: horizontal ? candle.width : -1
    Layout.maximumWidth: horizontal ? candle.width : -1

    Candle {
        id: candle
        anchors.centerIn: parent
        mood: compact.app.mood
        level: 1 - compact.app.usedMain
        // In a panel: about 65% of its thickness, on a whole number of pixels per block
        height: compact.inPanel ? Math.max(1, Math.round(compact.height * 0.65 / 9)) * 9 : Math.min(compact.width, compact.height)
        width: Math.round(height * 15 / 9)
    }
}
