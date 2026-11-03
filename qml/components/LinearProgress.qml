import QtQuick
import QtQuick.Shapes
import Dogear

// Copied from Seedling (082d977); ours now.
// Material 3 Expressive linear progress indicator: a thick rounded
// indicator, a gap, then the track with a stop dot at its end. `wavy`
// draws the indicator as a flowing wave, as Android 16 does for ongoing
// work; it flattens out once the work is done. `indeterminate` sends a
// segment of indicator travelling along the track instead, for work with
// no known end.
Item {
    id: root

    // 0 to 1
    property real progress: 0
    property bool indeterminate: false
    property real thickness: 8
    property bool wavy: false
    property color color: Theme.primary
    property color trackColor: Theme.primary_container

    readonly property real gap: 4
    readonly property real wavelength: 32
    // Room for the wave's swing above and below the stroke
    property real amplitude: wavy && (indeterminate || progress < 1) ? thickness * 0.45 : 0
    property real phase: 0

    // Where along the bar the travelling segment's head is, 0 to 1.4 so
    // it runs fully off the end before coming round again
    property real sweep: 0
    readonly property real segment: 0.4

    // The indicator's span, in pixels
    readonly property real from: indeterminate ? Math.max(0, sweep - segment) * width : 0
    readonly property real to: indeterminate ? Math.min(1, sweep) * width : Math.max(thickness, Math.min(1, progress) * (width - gap))
    readonly property bool showIndicator: to - from >= thickness

    implicitHeight: thickness + 2 * thickness * 0.45 + 2

    Behavior on amplitude {
        NumberAnimation {
            duration: 400
            easing.type: Easing.OutCubic
        }
    }

    NumberAnimation on phase {
        running: root.wavy && root.amplitude > 0 && root.visible
        loops: Animation.Infinite
        from: 0
        to: 2 * Math.PI
        duration: 1600
    }

    NumberAnimation on sweep {
        running: root.indeterminate && root.visible
        loops: Animation.Infinite
        from: 0
        to: 1 + root.segment
        duration: 1800
        easing.type: Easing.InOutCubic
    }

    // Track before the indicator (only while a segment travels)
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: root.showIndicator ? Math.max(0, root.from - root.gap) : 0
        visible: width >= root.thickness
        height: root.thickness
        radius: height / 2
        color: root.trackColor
    }

    // Track after the indicator, with the stop dot when there's an end
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        width: Math.max(0, root.width - (root.showIndicator ? root.to + root.gap : 0))
        visible: width >= root.thickness
        height: root.thickness
        radius: height / 2
        color: root.trackColor

        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: (root.thickness - width) / 2
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.indeterminate
            width: Math.max(4, root.thickness / 3)
            height: width
            radius: width / 2
            color: root.color
        }
    }

    // Flat indicator
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showIndicator && root.amplitude === 0
        x: root.from
        width: root.to - root.from
        height: root.thickness
        radius: height / 2
        color: root.color
    }

    // Wavy indicator: a thick stroke along a sine, round at both ends
    Shape {
        anchors.fill: parent
        visible: root.showIndicator && root.amplitude > 0
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.color
            strokeWidth: root.thickness
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin

            PathPolyline {
                path: {
                    const start = root.from + root.thickness / 2;
                    const end = Math.max(start, root.to - root.thickness / 2);
                    const mid = root.height / 2;
                    const wave = x => mid + root.amplitude * Math.sin(x / root.wavelength * 2 * Math.PI - root.phase);
                    const points = [];
                    for (let x = start; x < end; x += 2)
                        points.push(Qt.point(x, wave(x)));
                    points.push(Qt.point(end, wave(end)));
                    return points;
                }
            }
        }
    }
}
