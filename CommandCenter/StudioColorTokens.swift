import SwiftUI
import AppKit

// MARK: - Hex Color Support

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 1)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

// MARK: - Adaptive Color Support

extension Color {
    /// Creates a color that automatically adapts to the current system appearance.
    /// Uses NSColor dynamic provider — no EnvironmentObject or manual switching needed.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }

    /// Convenience for hex-based adaptive colors.
    static func adaptive(lightHex: String, darkHex: String) -> Color {
        adaptive(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }
}

// MARK: - Studio Surface Tokens (Base Layers)

enum StudioSurface {
    static let base       = Color.adaptive(lightHex: "#F5F2EF", darkHex: "#0B0D10")
    static let sidebar    = Color.adaptive(lightHex: "#EAE5E1", darkHex: "#0E1115")
    static let viewport   = Color(hex: "#08090C") // near-black with material presence — avoids "hole" against base
    static let searchPill = Color(hex: "#14181D") // recessed input field on sidebar
}

// MARK: - Studio Elevated Surfaces (Cards / Panels)

enum StudioSurfaceElevated {
    // Normal: semi-transparent overlays that adapt to light/dark.
    private static let _level1Default = Color.adaptive(
        light: Color(hex: "#FFFFFF").opacity(0.72),
        dark: Color.white.opacity(0.06)
    )
    private static let _level2Default = Color.adaptive(
        light: Color(hex: "#FFFFFF").opacity(0.88),
        dark: Color.white.opacity(0.10)
    )
    // Solid fallbacks for Reduce Transparency accessibility.
    private static let _level1Solid = Color.adaptive(lightHex: "#F8F6F3", darkHex: "#222120")
    private static let _level2Solid = Color.adaptive(lightHex: "#FBFAF8", darkHex: "#282726")

    static var level1: Color {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? _level1Solid : _level1Default
    }
    static var level2: Color {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? _level2Solid : _level2Default
    }
}

// MARK: - Studio Grouped Backgrounds (Apple-style sections)

enum StudioSurfaceGrouped {
    static let primary   = Color.adaptive(lightHex: "#ECE7E3", darkHex: "#222120")
    static let secondary = Color.adaptive(lightHex: "#E3DDD8", darkHex: "#2A2928")
}

// MARK: - Studio Separator System

enum StudioSeparator {
    private static let _subtleNormal = Color.adaptive(
        light: Color.black.opacity(0.06), dark: Color.white.opacity(0.06)
    )
    private static let _subtleHigh = Color.adaptive(
        light: Color.black.opacity(0.15), dark: Color.white.opacity(0.15)
    )
    private static let _strongNormal = Color.adaptive(
        light: Color.black.opacity(0.12), dark: Color.white.opacity(0.12)
    )
    private static let _strongHigh = Color.adaptive(
        light: Color.black.opacity(0.24), dark: Color.white.opacity(0.24)
    )

    /// Thin, barely-visible separator. Strengthens with Increase Contrast.
    static var subtle: Color {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? _subtleHigh : _subtleNormal
    }
    /// Heavier separator for group boundaries. Strengthens with Increase Contrast.
    static var strong: Color {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? _strongHigh : _strongNormal
    }
}

// MARK: - Surface Style Modifier

struct StudioSurfaceStyle: ViewModifier {
    let style: Style

    enum Style {
        case base
        case sidebar
        case viewport
        case elevated1
        case elevated2
        case groupedPrimary
        case groupedSecondary
    }

    func body(content: Content) -> some View {
        content
            .background(background)
    }

    private var background: Color {
        switch style {
        case .base:             return StudioSurface.base
        case .sidebar:          return StudioSurface.sidebar
        case .viewport:         return StudioSurface.viewport
        case .elevated1:        return StudioSurfaceElevated.level1
        case .elevated2:        return StudioSurfaceElevated.level2
        case .groupedPrimary:   return StudioSurfaceGrouped.primary
        case .groupedSecondary: return StudioSurfaceGrouped.secondary
        }
    }
}

extension View {
    func studioSurface(_ style: StudioSurfaceStyle.Style) -> some View {
        self.modifier(StudioSurfaceStyle(style: style))
    }
}

// MARK: - Studio Text Tokens (Light Surfaces)

enum StudioTextColor {
    static let primary   = Color.adaptive(lightHex: "#222120", darkHex: "#FFFFFF")
    static let secondary = Color.adaptive(lightHex: "#4A4846", darkHex: "#C7C7CC")
    static let tertiary  = Color.adaptive(lightHex: "#7A7672", darkHex: "#8E8E93")
    static let disabled  = Color.adaptive(lightHex: "#A1A1A6", darkHex: "#636363")
}

// MARK: - Studio Text Tokens (Dark Surfaces)

enum StudioTextColorDark {
    static let primary   = Color(hex: "#FFFFFF")
    static let secondary = Color(hex: "#C7C7CC")
    static let tertiary  = Color(hex: "#8E8E93")
}

// MARK: - Studio Accent

enum StudioAccentColor {
    static let primary = Color(hex: "#1CD1FF") // electric cyan
    static let muted   = Color(hex: "#8CF0FF") // light cyan
}

// MARK: - Studio Status Colors

enum StudioStatusColor {
    static let success        = Color(hex: "#3FAE5A")               // moss green (= accent)
    static let warning        = Color(hex: "#E2725B")               // rust ember
    static let danger         = Color(hex: "#E2725B")               // rust ember (= warning)
    static let successSurface = Color(hex: "#3FAE5A").opacity(0.12)
    static let warningSurface = Color(hex: "#E2725B").opacity(0.12)
    static let dangerSurface  = Color(hex: "#E2725B").opacity(0.12)
}

// MARK: - Surface Style

enum SurfaceStyle {
    case light
    case dark
}

// MARK: - Semantic Text Modifier

struct StudioTextStyle: ViewModifier {
    let level: Level
    let surface: SurfaceStyle

    enum Level {
        case primary
        case secondary
        case tertiary
        case disabled
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(color)
    }

    private var color: Color {
        switch surface {
        case .light:
            switch level {
            case .primary: return StudioTextColor.primary
            case .secondary: return StudioTextColor.secondary
            case .tertiary: return StudioTextColor.tertiary
            case .disabled: return StudioTextColor.disabled
            }
        case .dark:
            switch level {
            case .primary: return StudioTextColorDark.primary
            case .secondary: return StudioTextColorDark.secondary
            case .tertiary: return StudioTextColorDark.tertiary
            case .disabled: return StudioTextColorDark.tertiary
            }
        }
    }
}

extension View {
    func studioText(_ level: StudioTextStyle.Level,
                    surface: SurfaceStyle = .light) -> some View {
        self.modifier(StudioTextStyle(level: level, surface: surface))
    }
}

// MARK: - Studio Color Token

struct StudioColorToken: Sendable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Double

    init(red: Int, green: Int, blue: Int, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = max(0, min(alpha, 1))
    }

    var color: Color {
        Color(
            .sRGB,
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0,
            opacity: alpha
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
    }

    func withAlpha(_ alpha: Double) -> StudioColorToken {
        StudioColorToken(red: red, green: green, blue: blue, alpha: alpha)
    }

    func multipliedAlpha(_ factor: Double) -> StudioColorToken {
        StudioColorToken(red: red, green: green, blue: blue, alpha: alpha * factor)
    }
}

private struct StudioResolvedColorTokens: Sendable {
    struct Background: Sendable {
        struct Elevated: Sendable {
            let level1: StudioColorToken
            let level2: StudioColorToken
            let level3: StudioColorToken
        }

        let primary: StudioColorToken
        let secondary: StudioColorToken
        let elevated: Elevated
    }

    struct Text: Sendable {
        let primary: StudioColorToken
        let secondary: StudioColorToken
        let tertiary: StudioColorToken
        let placeholder: StudioColorToken
    }

    struct Accent: Sendable {
        let primary: StudioColorToken
        let muted: StudioColorToken
    }

    struct Warning: Sendable {
        let primary: StudioColorToken
    }

    struct Highlight: Sendable {
        let critical: StudioColorToken
    }

    struct Surface: Sendable {
        let bare: StudioColorToken
        let soft: StudioColorToken
        let emphasis: StudioColorToken
        let highlight: StudioColorToken
        let fill: StudioColorToken
        let panel: StudioColorToken
        let lifted: StudioColorToken
        let warm: StudioColorToken
        let terminal: StudioColorToken
        let dock: StudioColorToken
        let dashboard: StudioColorToken
    }

    struct Border: Sendable {
        let subtle: StudioColorToken
        let `default`: StudioColorToken
        let divider: StudioColorToken
        let accent: StudioColorToken
        let accentStrong: StudioColorToken
        let accentStroke: StudioColorToken
    }

    struct Status: Sendable {
        let success: StudioColorToken
        let warning: StudioColorToken
        let danger: StudioColorToken
        let successSurface: StudioColorToken
        let successStroke: StudioColorToken
        let warningSurface: StudioColorToken
        let warningStroke: StudioColorToken
        let dangerSurface: StudioColorToken
        let dangerStroke: StudioColorToken
    }

    struct Shadow: Sendable {
        let soft: StudioColorToken
        let accent: StudioColorToken
        let muted: StudioColorToken
    }

    struct Overlay: Sendable {
        let clear: StudioColorToken
        let matteHighlight: StudioColorToken
        let matteLowlight: StudioColorToken
        let chromeEdge: StudioColorToken
        let scrim: StudioColorToken
    }

    let background: Background
    let text: Text
    let accent: Accent
    let warning: Warning
    let highlight: Highlight
    let surface: Surface
    let border: Border
    let status: Status
    let shadow: Shadow
    let overlay: Overlay
}

private enum StudioResolvedColorSets {
    static let dark: StudioResolvedColorTokens = {
        let backgroundPrimary = StudioColorToken(red: 9, green: 9, blue: 11)
        let backgroundSecondary = StudioColorToken(red: 24, green: 24, blue: 27)
        let textPrimary = StudioColorToken(red: 250, green: 250, blue: 250)
        let textSecondary = StudioColorToken(red: 250, green: 250, blue: 250, alpha: 0.72)
        let accentPrimary = StudioColorToken(red: 63, green: 174, blue: 90)
        let accentMuted = StudioColorToken(red: 139, green: 168, blue: 136)
        let warningPrimary = StudioColorToken(red: 226, green: 114, blue: 91)
        let criticalHighlight = StudioColorToken(red: 255, green: 221, blue: 68)
        let transparent = backgroundPrimary.withAlpha(0)

        return StudioResolvedColorTokens(
            background: .init(
                primary: backgroundPrimary,
                secondary: backgroundSecondary,
                elevated: .init(
                    level1: backgroundSecondary.withAlpha(0.76),
                    level2: backgroundSecondary.withAlpha(0.82),
                    level3: backgroundSecondary.withAlpha(0.88)
                )
            ),
            text: .init(
                primary: textPrimary,
                secondary: textSecondary,
                tertiary: textSecondary.multipliedAlpha(0.82),
                placeholder: textSecondary.multipliedAlpha(0.78)
            ),
            accent: .init(
                primary: accentPrimary,
                muted: accentMuted
            ),
            warning: .init(primary: warningPrimary),
            highlight: .init(critical: criticalHighlight),
            surface: .init(
                bare: textPrimary.withAlpha(0.05),
                soft: textPrimary.withAlpha(0.08),
                emphasis: textPrimary.withAlpha(0.11),
                highlight: textPrimary.withAlpha(0.14),
                fill: textPrimary.withAlpha(0.05),
                panel: StudioColorToken(red: 138, green: 121, blue: 121),
                lifted: backgroundSecondary,
                warm: backgroundSecondary.withAlpha(0.72),
                terminal: backgroundSecondary.withAlpha(0.76),
                dock: transparent,
                dashboard: backgroundSecondary.withAlpha(0.84)
            ),
            border: .init(
                subtle: textPrimary.withAlpha(0.08),
                default: textPrimary.withAlpha(0.12),
                divider: textPrimary.withAlpha(0.08),
                accent: accentPrimary.withAlpha(0.28),
                accentStrong: accentPrimary.withAlpha(0.40),
                accentStroke: accentPrimary.withAlpha(0.32)
            ),
            status: .init(
                success: accentPrimary,
                warning: warningPrimary,
                danger: warningPrimary,
                successSurface: accentPrimary.withAlpha(0.12),
                successStroke: accentPrimary.withAlpha(0.28),
                warningSurface: warningPrimary.withAlpha(0.12),
                warningStroke: warningPrimary.withAlpha(0.28),
                dangerSurface: warningPrimary.withAlpha(0.12),
                dangerStroke: warningPrimary.withAlpha(0.28)
            ),
            shadow: .init(
                soft: backgroundPrimary.withAlpha(0.18),
                accent: backgroundPrimary.withAlpha(0.10),
                muted: backgroundPrimary.withAlpha(0.08)
            ),
            overlay: .init(
                clear: transparent,
                matteHighlight: textPrimary.withAlpha(0.03),
                matteLowlight: backgroundPrimary.withAlpha(0.06),
                chromeEdge: textPrimary.withAlpha(0.08),
                scrim: backgroundPrimary.withAlpha(0.46)
            )
        )
    }()

    static let light: StudioResolvedColorTokens = {
        let backgroundPrimary = StudioColorToken(red: 245, green: 242, blue: 239)   // #F5F2EF
        let backgroundSecondary = StudioColorToken(red: 234, green: 229, blue: 225) // #EAE5E1
        let textPrimary = StudioColorToken(red: 34, green: 33, blue: 32)            // #222120
        let textSecondary = StudioColorToken(red: 34, green: 33, blue: 32, alpha: 0.60)
        let accentPrimary = StudioColorToken(red: 63, green: 174, blue: 90)         // moss green
        let accentMuted = StudioColorToken(red: 100, green: 140, blue: 96)
        let warningPrimary = StudioColorToken(red: 200, green: 90, blue: 70)        // rust ember
        let criticalHighlight = StudioColorToken(red: 200, green: 160, blue: 20)
        let transparent = backgroundPrimary.withAlpha(0)

        return StudioResolvedColorTokens(
            background: .init(
                primary: backgroundPrimary,
                secondary: backgroundSecondary,
                elevated: .init(
                    level1: StudioColorToken(red: 255, green: 255, blue: 255, alpha: 0.72),
                    level2: StudioColorToken(red: 255, green: 255, blue: 255, alpha: 0.82),
                    level3: StudioColorToken(red: 255, green: 255, blue: 255, alpha: 0.88)
                )
            ),
            text: .init(
                primary: textPrimary,
                secondary: textSecondary,
                tertiary: textSecondary.multipliedAlpha(0.72),
                placeholder: textSecondary.multipliedAlpha(0.56)
            ),
            accent: .init(
                primary: accentPrimary,
                muted: accentMuted
            ),
            warning: .init(primary: warningPrimary),
            highlight: .init(critical: criticalHighlight),
            surface: .init(
                bare: textPrimary.withAlpha(0.03),
                soft: textPrimary.withAlpha(0.05),
                emphasis: textPrimary.withAlpha(0.07),
                highlight: textPrimary.withAlpha(0.10),
                fill: textPrimary.withAlpha(0.04),
                panel: StudioColorToken(red: 200, green: 194, blue: 188),
                lifted: StudioColorToken(red: 255, green: 255, blue: 255),
                warm: backgroundSecondary.withAlpha(0.72),
                terminal: backgroundSecondary.withAlpha(0.76),
                dock: transparent,
                dashboard: backgroundSecondary.withAlpha(0.84)
            ),
            border: .init(
                subtle: textPrimary.withAlpha(0.06),
                default: textPrimary.withAlpha(0.10),
                divider: textPrimary.withAlpha(0.06),
                accent: accentPrimary.withAlpha(0.22),
                accentStrong: accentPrimary.withAlpha(0.36),
                accentStroke: accentPrimary.withAlpha(0.28)
            ),
            status: .init(
                success: accentPrimary,
                warning: warningPrimary,
                danger: warningPrimary,
                successSurface: accentPrimary.withAlpha(0.10),
                successStroke: accentPrimary.withAlpha(0.22),
                warningSurface: warningPrimary.withAlpha(0.10),
                warningStroke: warningPrimary.withAlpha(0.22),
                dangerSurface: warningPrimary.withAlpha(0.10),
                dangerStroke: warningPrimary.withAlpha(0.22)
            ),
            shadow: .init(
                soft: textPrimary.withAlpha(0.08),
                accent: textPrimary.withAlpha(0.05),
                muted: textPrimary.withAlpha(0.04)
            ),
            overlay: .init(
                clear: transparent,
                matteHighlight: StudioColorToken(red: 255, green: 255, blue: 255, alpha: 0.06),
                matteLowlight: textPrimary.withAlpha(0.03),
                chromeEdge: textPrimary.withAlpha(0.06),
                scrim: textPrimary.withAlpha(0.22)
            )
        )
    }()
}

enum StudioColorTokens {
    enum Scheme {
        case dark
        case light
    }

    static let activeScheme: Scheme = .light

    private static var current: StudioResolvedColorTokens {
        resolved(for: activeScheme)
    }

    private static func resolved(for scheme: Scheme) -> StudioResolvedColorTokens {
        switch scheme {
        case .dark:
            return StudioResolvedColorSets.dark
        case .light:
            return StudioResolvedColorSets.light
        }
    }

    enum Background {
        static var primary: Color { current.background.primary.color }
        static var secondary: Color { current.background.secondary.color }

        enum Elevated {
            static var level1: Color { current.background.elevated.level1.color }
            static var level2: Color { current.background.elevated.level2.color }
            static var level3: Color { current.background.elevated.level3.color }
        }
    }

    enum Text {
        static var primary: Color { current.text.primary.color }
        static var secondary: Color { current.text.secondary.color }
        static var tertiary: Color { current.text.tertiary.color }
        static var placeholder: Color { current.text.placeholder.color }
    }

    enum Accent {
        static var primary: Color { current.accent.primary.color }
        static var muted: Color { current.accent.muted.color }
    }

    enum Warning {
        static var primary: Color { current.warning.primary.color }
    }

    enum Highlight {
        static var critical: Color { current.highlight.critical.color }
    }

    enum Surface {
        static var bare: Color { current.surface.bare.color }
        static var soft: Color { current.surface.soft.color }
        static var emphasis: Color { current.surface.emphasis.color }
        static var highlight: Color { current.surface.highlight.color }
        static var fill: Color { current.surface.fill.color }
        static var panel: Color { current.surface.panel.color }
        static var lifted: Color { current.surface.lifted.color }
        static var warm: Color { current.surface.warm.color }
        static var terminal: Color { current.surface.terminal.color }
        static var dock: Color { current.surface.dock.color }
        static var dashboard: Color { current.surface.dashboard.color }
    }

    enum Border {
        static var subtle: Color { current.border.subtle.color }
        static var `default`: Color { current.border.default.color }
        static var divider: Color { current.border.divider.color }
        static var accent: Color { current.border.accent.color }
        static var accentStrong: Color { current.border.accentStrong.color }
        static var accentStroke: Color { current.border.accentStroke.color }
    }

    enum Status {
        static var success: Color { current.status.success.color }
        static var warning: Color { current.status.warning.color }
        static var danger: Color { current.status.danger.color }
        static var successSurface: Color { current.status.successSurface.color }
        static var successStroke: Color { current.status.successStroke.color }
        static var warningSurface: Color { current.status.warningSurface.color }
        static var warningStroke: Color { current.status.warningStroke.color }
        static var dangerSurface: Color { current.status.dangerSurface.color }
        static var dangerStroke: Color { current.status.dangerStroke.color }
    }

    enum Shadow {
        static var soft: Color { current.shadow.soft.color }
        static var accent: Color { current.shadow.accent.color }
        static var muted: Color { current.shadow.muted.color }
    }

    enum Overlay {
        static var clear: Color { current.overlay.clear.color }
        static var matteHighlight: Color { current.overlay.matteHighlight.color }
        static var matteLowlight: Color { current.overlay.matteLowlight.color }
        static var chromeEdge: Color { current.overlay.chromeEdge.color }
        static var scrim: Color { current.overlay.scrim.color }
    }

    enum AppKit {
        static var backgroundPrimary: NSColor { current.background.primary.nsColor }
        static var backgroundSecondary: NSColor { current.background.secondary.nsColor }
        static var backgroundElevated1: NSColor { current.background.elevated.level1.nsColor }
        static var backgroundElevated2: NSColor { current.background.elevated.level2.nsColor }
        static var backgroundElevated3: NSColor { current.background.elevated.level3.nsColor }
        static var textPrimary: NSColor { current.text.primary.nsColor }
        static var textSecondary: NSColor { current.text.secondary.nsColor }
        static var accentPrimary: NSColor { current.accent.primary.nsColor }
        static var accentMuted: NSColor { current.accent.muted.nsColor }
        static var warningPrimary: NSColor { current.warning.primary.nsColor }
        static var criticalHighlight: NSColor { current.highlight.critical.nsColor }
        static var clear: NSColor { current.overlay.clear.nsColor }

        // Surface system NSColor equivalents
        static var surfaceBase: NSColor { NSColor(StudioSurface.base) }
        static var surfaceViewport: NSColor { NSColor(StudioSurface.viewport) }
    }

    // MARK: - Obsidian & Moss syntax theme

    enum Syntax {
        /// Variables / constants — Crisp White #FFFFFF
        static let plain       = NSColor(srgbRed: 255/255, green: 255/255, blue: 255/255, alpha: 1)
        /// Keywords — Electric Cyan #1CD1FF
        static let keyword     = NSColor(srgbRed:  28/255, green: 209/255, blue: 255/255, alpha: 1)
        /// Functions — Icy Violet #9EACFA
        static let function    = NSColor(srgbRed: 158/255, green: 172/255, blue: 250/255, alpha: 1)
        /// Strings — Volt Mint #86EFAC
        static let string      = NSColor(srgbRed: 134/255, green: 239/255, blue: 172/255, alpha: 1)
        /// Types / classes — Icy Violet #9EACFA
        static let type        = NSColor(srgbRed: 158/255, green: 172/255, blue: 250/255, alpha: 1)
        /// Comments — Muted Graphite #7E8794
        static let comment     = NSColor(srgbRed: 126/255, green: 135/255, blue: 148/255, alpha: 1)
        /// AI-generated suggestion tint — accent.primary at low opacity
        static let aiSuggestion = NSColor(srgbRed:  28/255, green: 209/255, blue: 255/255, alpha: 0.22)

        // SwiftUI equivalents for diff surfaces
        static let keywordColor   = Color(nsColor: keyword)
        static let functionColor  = Color(nsColor: function)
        static let stringColor    = Color(nsColor: string)
        static let typeColor      = Color(nsColor: type)
        static let commentColor   = Color(nsColor: comment)
        static let plainColor     = Color(nsColor: plain)

        /// Diff-line foreground colors — cool-tone
        static let diffAddition   = Color(nsColor: NSColor(srgbRed: 134/255, green: 239/255, blue: 172/255, alpha: 1))   // Volt Mint
        static let diffRemoval    = Color(nsColor: NSColor(srgbRed: 255/255, green: 115/255, blue: 115/255, alpha: 1))   // Cool Red
        static let diffHeader     = Color(nsColor: NSColor(srgbRed: 158/255, green: 172/255, blue: 250/255, alpha: 1))   // Icy Violet
    }

    // MARK: - Thermal Glow (thinking/loading)

    enum ThermalGlow {
        /// Deep blue anchor — muted cobalt, no neon
        static let cool    = Color(nsColor: NSColor(srgbRed:  58/255, green:  72/255, blue: 102/255, alpha: 1))
        /// Neutral midpoint — warm gray
        static let neutral = Color(nsColor: NSColor(srgbRed: 120/255, green: 113/255, blue: 108/255, alpha: 1))
        /// Soft infrared — desaturated warm red
        static let warm    = Color(nsColor: NSColor(srgbRed: 142/255, green:  78/255, blue:  68/255, alpha: 1))
    }
}

enum StudioTheme {
    static let clear = StudioColorTokens.Overlay.clear

    static let backgroundPrimary = StudioSurface.base
    static let backgroundSecondary = StudioSurface.viewport
    static let elevatedBackground1 = StudioSurfaceElevated.level1
    static let elevatedBackground2 = StudioSurfaceElevated.level2
    static let elevatedBackground3 = StudioSurfaceElevated.level2

    // Light-surface text (sidebar, chat, dashboard — warm charcoal hierarchy)
    static let primaryText = StudioTextColor.primary
    static let secondaryText = StudioTextColor.secondary
    static let tertiaryText = StudioTextColor.tertiary
    static let placeholderText = StudioTextColor.disabled

    // Dark-surface text (viewport, execution pane, right panel)
    static let darkPrimaryText = StudioTextColorDark.primary
    static let darkSecondaryText = StudioTextColorDark.secondary
    static let darkTertiaryText = StudioTextColorDark.tertiary

    static let accent = StudioColorTokens.Accent.primary
    static let accentBase = StudioColorTokens.Accent.primary
    static let accentMuted = StudioColorTokens.Accent.muted
    static let accentHighlight = StudioColorTokens.Highlight.critical

    static let warning = StudioColorTokens.Warning.primary
    static let highlightCritical = StudioColorTokens.Highlight.critical

    static let midnight = StudioColorTokens.Background.secondary
    static let charcoal = StudioColorTokens.Background.secondary
    static let moss = StudioColorTokens.Accent.muted
    // Surface system — warm neutral base layers
    static let sidebarBackground = StudioSurface.sidebar
    // Sidebar container surfaces (fields, list cards) — subtle uplift from sidebar base
    static let sidebarContainer = StudioSurfaceGrouped.secondary
    // Subtle separator on sidebar trailing edge
    static let sidebarDivider = StudioSeparator.subtle
    static let workspaceBackground = StudioSurface.base
    static let viewportBackground = StudioSurface.viewport
    static let panelBackground = StudioSurface.viewport
    static let elevatedPanel = StudioSurfaceElevated.level2
    static let capsuleTop = StudioSurfaceElevated.level1
    static let capsuleBottom = StudioSurfaceElevated.level2
    static let terminalBackground = StudioSurface.viewport
    static let surfaceBare = StudioSurfaceElevated.level1
    static let surfaceSoft = StudioSurfaceGrouped.primary
    static let surfaceEmphasis = StudioSurfaceGrouped.secondary
    static let surfaceHighlight = StudioSurfaceGrouped.secondary
    static let surfaceWarm = StudioSurfaceGrouped.primary
    static let liftedSurface = StudioSurfaceElevated.level2
    static let surfaceFill = StudioSurfaceElevated.level1
    static let dockFill = StudioSurface.sidebar
    static let dashboardCard = StudioSurfaceGrouped.primary

    static let success = StudioColorTokens.Status.success
    static let danger = StudioColorTokens.Status.danger
    static let successSurface = StudioColorTokens.Status.successSurface
    static let successStroke = StudioColorTokens.Overlay.clear
    static let warningSurface = StudioColorTokens.Status.warningSurface
    static let warningStroke = StudioColorTokens.Overlay.clear
    static let dangerSurface = StudioColorTokens.Status.dangerSurface
    static let dangerStroke = StudioColorTokens.Overlay.clear

    static let stroke = StudioSeparator.subtle
    static let subtleStroke = StudioSeparator.subtle
    static let accentSurface = StudioColorTokens.Status.successSurface
    static let accentSurfaceStrong = StudioColorTokens.Accent.primary.opacity(0.20)
    static let accentFill = StudioColorTokens.Accent.primary.opacity(0.14)
    static let accentBorder = StudioColorTokens.Overlay.clear
    static let accentBorderStrong = StudioColorTokens.Overlay.clear
    static let accentStroke = StudioColorTokens.Overlay.clear
    static let divider = StudioSeparator.subtle
    static let dockDivider = StudioSeparator.subtle
    static let composerFill = StudioSurfaceElevated.level2
    static let composerBorder = StudioSeparator.subtle
    static let softShadow = StudioColorTokens.Overlay.clear
    static let accentShadow = StudioColorTokens.Overlay.clear
    static let creamShadow = StudioColorTokens.Overlay.clear
    static let chromeGlow = StudioColorTokens.Overlay.clear
    static let successGlow = StudioColorTokens.Overlay.clear
    static let dangerGlow = StudioColorTokens.Overlay.clear
    static let matteHighlight = StudioColorTokens.Overlay.matteHighlight
    static let matteLowlight = StudioColorTokens.Overlay.matteLowlight
    static let chromeEdge = StudioColorTokens.Overlay.chromeEdge
    static let matteCanvas = StudioSurface.base

    static let nsClear = StudioColorTokens.AppKit.clear
    static let nsBackgroundPrimary = StudioColorTokens.AppKit.backgroundPrimary
    static let nsBackgroundSecondary = StudioColorTokens.AppKit.backgroundSecondary
    static let nsElevatedBackground1 = StudioColorTokens.AppKit.backgroundElevated1
    static let nsElevatedBackground2 = StudioColorTokens.AppKit.backgroundElevated2
    static let nsElevatedBackground3 = StudioColorTokens.AppKit.backgroundElevated3
    // NSColor text — dark surfaces (command bar, code editor)
    static let nsPrimaryText = StudioColorTokens.AppKit.textPrimary
    static let nsSecondaryText = StudioColorTokens.AppKit.textSecondary
    // NSColor text — light surfaces
    static let nsLightPrimaryText = NSColor(StudioTextColor.primary)
    static let nsLightSecondaryText = NSColor(StudioTextColor.secondary)
    static let nsAccent = StudioColorTokens.AppKit.accentPrimary
    static let nsAccentMuted = StudioColorTokens.AppKit.accentMuted
    static let nsWarning = StudioColorTokens.AppKit.warningPrimary
    static let nsCriticalHighlight = StudioColorTokens.AppKit.criticalHighlight
}
