import QtQuick
import Dogear

// Copied from Seedling (082d977); ours now.
// Text in the bar's font. The default weight (Medium) renders at
// Theme.bodyWeight through the font's weight axis; any other weight set on
// a Label is used as is. `roundness` (0-100) rounds the letters' ends
// through the font's ROND axis, for titles.
Text {
    anchors.verticalCenter: parent?.verticalCenter
    color: Theme.on_background
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSize
    font.weight: Font.Medium

    property real roundness: 0
    onRoundnessChanged: applyWeight()

    // Set rather than bound: a binding on one part of `font` that reads
    // another part re-triggers itself
    function applyWeight() {
        const want = font.weight === Font.Medium ? Theme.bodyWeight : font.weight;
        if (font.variableAxes["wght"] !== want || (font.variableAxes["ROND"] ?? 0) !== roundness)
            font.variableAxes = {
                "wght": want,
                "ROND": roundness
            };
    }

    Component.onCompleted: applyWeight()
    onFontChanged: applyWeight()

    Behavior on color {
        ColorAnimation {
            duration: Theme.animNormal
        }
    }
}
