import SwiftUI
import AppKit

// MARK: - Studio Motion System
//
// Centralized motion tokens for Studio.92.
// All animation values, transitions, press/hover constants,
// and interaction styles live here. No magic numbers in views.

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Animation Tokens
// ═══════════════════════════════════════════════════════════════════════════════

enum StudioMotion {

    // MARK: - Accessibility

    /// Whether Reduce Motion is enabled in System Settings.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Springs

    /// Hover response, icon emphasis, button press recovery, checkmark flips, tiny insertion feedback.
    static var fastSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.86)
    }

    /// List item appearance, card state changes, command bar adjustments, collapsible sections.
    static var standardSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.84)
    }

    /// Right panel internal transitions, floating input presentation, viewport mode/state swaps.
    static var panelSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.88)
    }

    // MARK: Eased Hovers

    /// Unified hover response for all interactive elements. 0.14s easeInOut.
    static var hoverEase: Animation {
        .easeInOut(duration: reduceMotion ? 0.08 : 0.14)
    }

    /// Streaming → settled transition. 0.2s easeOut. No snapping.
    static var settledFade: Animation {
        .easeOut(duration: reduceMotion ? 0.1 : 0.2)
    }

    // MARK: Fades

    /// Tooltip-like appearances, secondary metadata changes, very subtle state labels.
    static var softFade: Animation {
        .easeOut(duration: reduceMotion ? 0.12 : 0.18)
    }

    /// Slightly longer fade for emphasis changes, loading overlays, metadata transitions.
    static var emphasisFade: Animation {
        .easeOut(duration: reduceMotion ? 0.15 : 0.24)
    }

    // MARK: - Ambient / Loops

    /// Cursor blink and breathing indicators. Slower cadence with Reduce Motion.
    static var breathe: Animation {
        .easeInOut(duration: reduceMotion ? 2.4 : 1.6).repeatForever(autoreverses: true)
    }

    /// Shimmer sweep. Gentler with Reduce Motion.
    static var shimmer: Animation {
        .easeInOut(duration: reduceMotion ? 6.0 : 4.0)
    }

    /// Thermal glow drift. Very slow ambient warmth.
    static var thermalDrift: Animation {
        .easeInOut(duration: reduceMotion ? 10.0 : 6.0).repeatForever(autoreverses: true)
    }

    /// Continuous rotation (gear icons, spinners). Stops with Reduce Motion.
    static var rotation: Animation {
        reduceMotion ? .easeOut(duration: 0.01) : .linear(duration: 3.0).repeatForever(autoreverses: false)
    }

    /// Running status dot pulse.
    static var statusPulse: Animation {
        .easeInOut(duration: reduceMotion ? 1.5 : 1.0).repeatForever()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Transitions
// ═══════════════════════════════════════════════════════════════════════════════

extension AnyTransition {

    /// Default content insertion: fade + subtle lift upward + near-imperceptible scale-in.
    /// Reduce Motion: opacity-only.
    static var studioFadeLift: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.985))
                .combined(with: .offset(y: 6)),
            removal: .opacity
                .combined(with: .scale(scale: 0.992))
        )
    }

    /// Horizontal content swap for right panel / viewport internal changes.
    static var studioPanelSwap: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 8)),
            removal: .opacity.combined(with: .offset(x: -6))
        )
    }

    /// Collapse/expand content. Subtle vertical shift in, opacity-only out.
    static var studioCollapse: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)),
            removal: .opacity
        )
    }

    /// Panel slide from trailing edge (viewport reveal).
    static var studioPanelTrailing: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 12)),
            removal: .opacity.combined(with: .offset(x: 8))
        )
    }

    /// Panel slide from leading edge (sidebar reveal).
    static var studioPanelLeading: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: -12)),
            removal: .opacity.combined(with: .offset(x: -8))
        )
    }

    /// Bottom sheet / terminal popup entrance.
    static var studioBottomLift: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 10))
                .combined(with: .scale(scale: 0.992)),
            removal: .opacity.combined(with: .offset(y: 6))
        )
    }

    /// Top banner entrance.
    static var studioTopDrop: AnyTransition {
        if StudioMotion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)),
            removal: .opacity.combined(with: .offset(y: -6))
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Press & Hover Constants
// ═══════════════════════════════════════════════════════════════════════════════

extension StudioMotion {

    /// Standard press-down scale for medium elements (buttons, chips, cards).
    static let pressScale: CGFloat = 0.988

    /// Heavier press-down scale for large primary buttons.
    static let pressPrimaryScale: CGFloat = 0.985

    /// Minimum opacity during press. Never collapse below this.
    static let pressMinOpacity: Double = 0.92

    /// Maximum hover scale for interactive elements that scale on hover.
    static let hoverScale: CGFloat = 1.008

    /// Subtle hover scale for small icon buttons.
    static let hoverScaleSmall: CGFloat = 1.04

    /// Command bar focus scale.
    static let commandBarFocusScale: CGFloat = 1.006

    /// Command bar running/recovering tuck-in scale.
    static let commandBarTuckScale: CGFloat = 0.996
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Centralized Button Styles
// ═══════════════════════════════════════════════════════════════════════════════

/// Press style for accessory icon buttons in the command bar area.
struct StudioAccessoryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? StudioMotion.pressScale : 1.0)
            .opacity(configuration.isPressed ? StudioMotion.pressMinOpacity : 1.0)
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

/// Press style for primary action buttons (send, stop).
struct StudioPrimaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? StudioMotion.pressPrimaryScale : 1.0)
            .opacity(configuration.isPressed ? StudioMotion.pressMinOpacity : 1.0)
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

/// Press style for subtle viewport/sidebar buttons.
struct StudioSubtleButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? StudioSurfaceElevated.level2 : StudioSurfaceElevated.level1)
            )
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}

/// Press style for inline action pills (copy, diff, artifact).
struct StudioPillButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? StudioMotion.pressScale : 1.0)
            .opacity(configuration.isPressed ? StudioMotion.pressMinOpacity : 1.0)
            .animation(StudioMotion.fastSpring, value: configuration.isPressed)
    }
}
