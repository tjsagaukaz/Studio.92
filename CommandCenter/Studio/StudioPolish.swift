// StudioPolish.swift
// Studio.92 — Command Center
// Apple-grade polish layer: focus states, hover highlights, interaction clarity,
// corner radius tokens, and micro-depth. Everything is restrained and engineered.

import SwiftUI

// MARK: - Corner Radius Scale

/// Standardized corner radius tokens. Use these instead of arbitrary radius values.
/// All shapes use `.continuous` curve unless noted.
enum StudioRadius {
    /// 6pt — Small pills, inline tags, compact chips.
    static let sm: CGFloat = 6
    /// 8pt — Sidebar rows, list items, compact cards.
    static let md: CGFloat = 8
    /// 12pt — Standard cards, panels, code blocks.
    static let lg: CGFloat = 12
    /// 14pt — Elevated cards, artifact panels.
    static let xl: CGFloat = 14
    /// 18pt — Large cards, modal sheets, composer backgrounds.
    static let xxl: CGFloat = 18
    /// 24pt — Command bar, hero inputs.
    static let hero: CGFloat = 24
    /// 999pt — Full pill shape.
    static let pill: CGFloat = 999
}

// MARK: - Micro-Depth

/// Shadow tokens for subtle elevation. Never stacked. Only on elevated surfaces.
enum StudioDepth {
    /// Barely-there shadow for cards resting on a surface.
    static let subtle = StudioShadow(color: Color.black.opacity(0.03), radius: 4, y: 1)
    /// Light shadow for elevated panels, popovers.
    static let elevated = StudioShadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
    /// Slightly more presence for floating elements (command bar, dropdowns).
    static let floating = StudioShadow(color: Color.black.opacity(0.06), radius: 12, y: 3)
}

struct StudioShadow {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

// MARK: - Focus Style

/// Consistent focus state for inputs and interactive containers.
/// Tightened, not activated. No glow, no thick rings.
struct StudioFocusStyle: ViewModifier {
    var isFocused: Bool
    var cornerRadius: CGFloat = StudioRadius.lg

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isFocused
                            ? StudioAccentColor.primary.opacity(0.28)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .animation(StudioMotion.softFade, value: isFocused)
    }
}

// MARK: - Hover Highlight

/// Micro-highlight on hover. Nearly invisible but perceptible.
struct StudioHoverStyle: ViewModifier {
    var isHovered: Bool
    var cornerRadius: CGFloat = StudioRadius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.03 : 0))
            )
            .animation(StudioMotion.softFade, value: isHovered)
    }
}

// MARK: - Press Style

/// Micro-scale on press for buttons and tappable elements.
struct StudioPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

// MARK: - Content Emphasis

/// Controls content emphasis for hierarchy through restraint.
enum StudioEmphasis {
    /// Primary content — full presence.
    case primary
    /// Secondary content — reduced contrast, no additional styling.
    case secondary
    /// Completed/resolved — slightly faded, not dimmed aggressively.
    case resolved

    var opacity: Double {
        switch self {
        case .primary: return 1.0
        case .secondary: return 0.72
        case .resolved: return 0.55
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply consistent focus ring.
    func studioFocus(_ isFocused: Bool, cornerRadius: CGFloat = StudioRadius.lg) -> some View {
        modifier(StudioFocusStyle(isFocused: isFocused, cornerRadius: cornerRadius))
    }

    /// Apply micro hover highlight.
    func studioHover(_ isHovered: Bool, cornerRadius: CGFloat = StudioRadius.md) -> some View {
        modifier(StudioHoverStyle(isHovered: isHovered, cornerRadius: cornerRadius))
    }

    /// Apply micro-depth shadow.
    func studioShadow(_ depth: StudioShadow) -> some View {
        self.shadow(color: depth.color, radius: depth.radius, x: 0, y: depth.y)
    }

    /// Apply content emphasis level.
    func studioEmphasis(_ emphasis: StudioEmphasis) -> some View {
        self.opacity(emphasis.opacity)
    }
}
