pragma Singleton

import QtQuick
import Dogear

// The app's look: Material 3 colour roles, fonts, radii and motion, as
// quickbar's menus (via margin, whose opaque window version this follows).
//
// Colours come from $XDG_CONFIG_HOME/dogear/colors.css when it exists:
// `@define-color NAME rgba(…)` lines, which matugen writes from the
// wallpaper. It's watched, so a wallpaper change recolours the app live.
// Without it, Material's baseline palette, light or dark as the system
// asks.
QtObject {
    id: root

    readonly property string fontFamily: "Google Sans Flex"
    readonly property int bodyWeight: 450
    readonly property int titleWeight: 620
    readonly property real titleRoundness: 100
    readonly property string monoFamily: "SF Mono"
    readonly property int fontSize: 14
    readonly property int radius: 10
    readonly property int cardRadius: 16
    readonly property int gap: 10

    readonly property int animFast: 150
    readonly property int animNormal: 280
    readonly property var emphasizedDecel: [0.05, 0.7, 0.1, 1, 1, 1]
    readonly property var emphasizedAccel: [0.3, 0, 0.8, 0.15, 1, 1]

    // Whether the palette is a dark one (matugen's are; else the system's)
    readonly property bool dark: colorsFile.exists ? luminance(surface) < 0.5 : Application.styleHints.colorScheme !== Qt.ColorScheme.Light

    property color background
    property color on_background
    property color surface
    property color on_surface
    property color on_surface_variant
    property color surface_container_lowest
    property color surface_container_low
    property color surface_container
    property color surface_container_high
    property color surface_container_highest
    property color inverse_surface
    property color inverse_on_surface
    property color inverse_primary
    property color outline
    property color outline_variant
    property color primary
    property color on_primary
    property color primary_container
    property color on_primary_container
    property color secondary
    property color on_secondary
    property color secondary_container
    property color on_secondary_container
    property color tertiary
    property color tertiary_container
    property color on_tertiary_container
    property color tertiary_fixed
    property color error
    property color on_error

    // Material's baseline scheme (seed #6750A4)
    readonly property var baselineDark: ({
            background: "#141218",
            on_background: "#e6e0e9",
            surface: "#141218",
            on_surface: "#e6e0e9",
            on_surface_variant: "#cac4d0",
            surface_container_lowest: "#0f0d13",
            surface_container_low: "#1d1b20",
            surface_container: "#211f26",
            surface_container_high: "#2b2930",
            surface_container_highest: "#36343b",
            inverse_surface: "#e6e0e9",
            inverse_on_surface: "#322f35",
            inverse_primary: "#6750a4",
            outline: "#938f99",
            outline_variant: "#49454f",
            primary: "#d0bcff",
            on_primary: "#381e72",
            primary_container: "#4f378b",
            on_primary_container: "#eaddff",
            secondary: "#ccc2dc",
            on_secondary: "#332d41",
            secondary_container: "#4a4458",
            on_secondary_container: "#e8def8",
            tertiary: "#efb8c8",
            tertiary_container: "#633b48",
            on_tertiary_container: "#ffd8e4",
            tertiary_fixed: "#ffd8e4",
            error: "#f2b8b5",
            on_error: "#601410"
        })
    readonly property var baselineLight: ({
            background: "#fef7ff",
            on_background: "#1d1b20",
            surface: "#fef7ff",
            on_surface: "#1d1b20",
            on_surface_variant: "#49454f",
            surface_container_lowest: "#ffffff",
            surface_container_low: "#f7f2fa",
            surface_container: "#f3edf7",
            surface_container_high: "#ece6f0",
            surface_container_highest: "#e6e0e9",
            inverse_surface: "#322f35",
            inverse_on_surface: "#f5eff7",
            inverse_primary: "#d0bcff",
            outline: "#79747e",
            outline_variant: "#cac4d0",
            primary: "#6750a4",
            on_primary: "#ffffff",
            primary_container: "#eaddff",
            on_primary_container: "#21005d",
            secondary: "#625b71",
            on_secondary: "#ffffff",
            secondary_container: "#e8def8",
            on_secondary_container: "#1d192b",
            tertiary: "#7d5260",
            tertiary_container: "#ffd8e4",
            on_tertiary_container: "#31111d",
            tertiary_fixed: "#ffd8e4",
            error: "#b3261e",
            on_error: "#ffffff"
        })

    function luminance(c) {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }

    function apply() {
        const base = Application.styleHints.colorScheme === Qt.ColorScheme.Light ? baselineLight : baselineDark;
        for (const name in base)
            root[name] = base[name];
        if (!colorsFile.exists)
            return;
        // Opaque: Dogear is an ordinary window (Hyprland already sets its
        // opacity), so the file's alpha is dropped
        const re = /@define-color\s+(\w+)\s+rgba\((\d+),\s*(\d+),\s*(\d+),\s*[\d.]+\)/g;
        let m;
        while ((m = re.exec(colorsFile.text)) !== null) {
            if (base[m[1]] !== undefined)
                root[m[1]] = Qt.rgba(m[2] / 255, m[3] / 255, m[4] / 255, 1);
        }
    }

    property TextFile colorsFile: TextFile {
        path: configPath("colors.css")
        onTextChanged: root.apply()
    }

    property Connections schemeWatch: Connections {
        target: Application.styleHints
        function onColorSchemeChanged() {
            root.apply();
        }
    }

    Component.onCompleted: apply()
}
