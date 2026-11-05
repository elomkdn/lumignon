import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

// Lumignon, a little candle drawn pixel by pixel. Its wax is the gauge: `level`
// is the share of the quota that is left, and the candle melts as it is used.
Canvas {
    id: candle

    property string mood: "idle"   // idle work think happy wave tired sleep ko
    property real level: 1

    readonly property int cols: 15
    readonly property int rows: 9
    readonly property color wax: "#EFE3C8"
    readonly property color waxShade: "#D6C4A0"
    readonly property color dish: "#8FA3B8"
    readonly property color wick: "#5A4A3A"
    readonly property color eyeDark: "#2A2118"
    readonly property color flameOuter: "#F2762E"
    readonly property color flameInner: "#F6B73C"
    readonly property color spark: "#F6D77A"
    readonly property color sweat: "#7FC8E8"
    readonly property color smoke: Qt.rgba(0.64, 0.70, 0.76, 0.8)
    readonly property bool motion: Kirigami.Units.longDuration > 0

    property int frame: 0
    property bool blink: false
    property int look: 0

    readonly property bool lively: mood === "work" || mood === "think" || mood === "happy" || mood === "wave"

    implicitWidth: 15 * 3
    implicitHeight: 9 * 3
    canvasSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
    smooth: false

    onMoodChanged: { frame = 0; requestPaint() }
    onLevelChanged: requestPaint()
    onFrameChanged: requestPaint()
    onBlinkChanged: requestPaint()
    onLookChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: requestPaint()
    Kirigami.Theme.onTextColorChanged: requestPaint()

    Timer {  // the flame never stands completely still
        running: candle.visible && candle.motion
        repeat: true
        interval: candle.mood === "wave" ? 220 : (candle.mood === "think" || candle.mood === "happy") ? 180
            : candle.mood === "work" ? 380 : 700
        onTriggered: candle.frame = (candle.frame + 1) % 12
    }
    Timer {
        running: candle.visible && candle.motion && (candle.mood === "idle" || candle.mood === "tired")
        repeat: true
        interval: 3400
        onTriggered: {
            candle.blink = true
            blinkEnd.restart()
            const r = Math.random()
            candle.look = r < 0.14 ? -1 : (r < 0.28 ? 1 : 0)
        }
    }
    Timer {
        id: blinkEnd
        interval: 130
        onTriggered: candle.blink = false
    }

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const unit = Math.max(1, Math.floor(Math.min(canvasSize.width / cols, canvasSize.height / rows)))
        const ox = Math.floor((canvasSize.width - unit * cols) / 2)
        const oy = Math.floor((canvasSize.height - unit * rows) / 2)
        const f = motion ? frame : 0

        // The wax is 1 to 5 rows tall. From the flame's tip to the dish, the candle takes
        // h + 4 of the 9 rows: it is lifted so as to stay centered while it melts.
        const h = Math.max(1, Math.round(Math.max(0, Math.min(1, level)) * 5))
        const lift = Math.ceil((5 - h) / 2)

        function px(x, y, color, w, height) {
            const row = y - lift
            if (row < 0) return
            ctx.fillStyle = color
            ctx.fillRect(ox + x * unit, oy + row * unit, (w || 1) * unit, (height || 1) * unit)
        }

        // Dish and wax
        const top = 8 - h
        px(3, 8, dish, 9, 1)
        px(4, top, wax, 6, h)
        px(10, top, waxShade, 1, h)
        if (h <= 3) { px(3, 8, wax); px(11, 8, wax) }  // melted wax pooling at the dish's ends

        // Eyes: two rows tall while the wax allows it, one row on a low candle
        const eyeRows = h >= 3 ? 2 : 1
        const ey = h >= 3 ? top + 1 : top
        const low = ey + eyeRows - 1
        if (mood === "sleep" || mood === "ko") {
            px(4, low, eyeDark, 2, 1); px(9, low, eyeDark, 2, 1)
        } else if (mood === "tired") {
            px(4 + look, ey, eyeDark, 2, 1); px(9 + look, ey, eyeDark, 2, 1)
            if (eyeRows === 2 && !blink) { px(5 + look, low, eyeDark); px(9 + look, low, eyeDark) }
        } else {
            const dx = mood === "think" ? 1 : (mood === "work" ? (f % 4 < 2 ? -1 : 1) : look)
            if (blink) {
                px(5 + dx, low, eyeDark); px(9 + dx, low, eyeDark)
            } else {
                px(5 + dx, ey, eyeDark, 1, eyeRows); px(9 + dx, ey, eyeDark, 1, eyeRows)
            }
        }

        // Wick and flame
        px(7, top - 1, wick)
        const fy = top - 2
        if (mood === "ko") {
            px(7 + f % 2, fy, smoke)
            px(8 - f % 2, fy - 1, smoke)
        } else if (mood === "sleep") {
            px(7, fy, flameOuter)
            const z = f % 3
            px(12, fy, Kirigami.Theme.textColor)
            if (z >= 1) px(13, fy - 1, Kirigami.Theme.textColor)
            if (z >= 2) px(14, fy - 1, Kirigami.Theme.textColor)
        } else if (mood === "tired") {
            px(7, fy, flameOuter)
            px(12, top + f % 2, sweat)
        } else {
            // A teardrop: yellow core on the wick, orange tip leaning with the draught
            const sway = mood === "wave" ? (f % 2 ? -1 : 1) : (mood === "work" ? f % 2 : (f % 3 === 0 ? 1 : 0))
            px(7, fy, flameInner)
            px(sway < 0 ? 8 : 6, fy, flameOuter)
            px(7 + sway, fy - 1, flameOuter)
            if (mood === "think") {
                px(7, fy - 2, spark)
                px(f % 2 ? 2 : 12, fy - 1 + f % 3, spark)
                px(f % 2 ? 12 : 2, fy + 1 - f % 3, spark)
            } else if (mood === "happy") {
                px(2, fy - 1, spark, 1, 2); px(12, fy - 1, spark, 1, 2)
            }
        }
    }
}
