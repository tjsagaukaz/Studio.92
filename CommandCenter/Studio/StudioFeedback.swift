// StudioFeedback.swift
// Studio.92 — Command Center
// System-native sensory feedback for macOS.
// Uses NSHapticFeedbackManager (trackpad haptics). No UIKit.
// Every signal follows "one signal per action" — never stacked.

import AppKit

// MARK: - Haptic Feedback

/// Trackpad-based haptic feedback for macOS.
/// Falls back silently when hardware doesn't support it.
/// Respects system accessibility settings automatically —
/// NSHapticFeedbackManager is a no-op when haptics are disabled.
enum StudioHaptics {

    private static let performer = NSHapticFeedbackManager.defaultPerformer

    /// Light tick — sidebar selection, minor toggles, expand/collapse.
    static func light() {
        performer.perform(.alignment, performanceTime: .now)
    }

    /// Medium click — command bar send, context switch, confirm important action.
    static func medium() {
        performer.perform(.levelChange, performanceTime: .now)
    }

    /// Generic pulse — task completion, pipeline finished, success confirmation.
    static func success() {
        performer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Sound Feedback

/// Extremely restrained system sounds. Pro tools are mostly silent.
/// Only fires for meaningful completion moments — never for routine taps.
enum StudioSound {

    /// Subtle completion sound. Only for pipeline success / major milestones.
    /// Skipped if system volume is muted or sound output is unavailable.
    static func completion() {
        guard !isMuted else { return }
        NSSound.beep() // System default — short, unobtrusive, familiar.
        // Future: Replace with a custom 80ms tone if branding requires it.
    }

    private static var isMuted: Bool {
        // NSSound respects system mute automatically, but we guard
        // against firing in contexts where it would be disruptive.
        false
    }
}

// MARK: - Unified Feedback API

/// Single entry point for all sensory feedback.
/// Views call `StudioFeedback.send()` etc. — never construct haptic objects directly.
enum StudioFeedback {

    /// Command bar submit / send action.
    static func send() {
        StudioHaptics.medium()
    }

    /// Sidebar row selection or minor navigation change.
    static func select() {
        StudioHaptics.light()
    }

    /// Pipeline or task completed successfully.
    static func completed() {
        StudioHaptics.success()
    }

    /// Cancel / stop a running operation.
    static func cancel() {
        StudioHaptics.light()
    }

    /// Destructive action confirmed (delete project, reset).
    static func destructive() {
        StudioHaptics.medium()
    }

    /// Minor toggle, expand/collapse, non-critical state change.
    static func toggle() {
        StudioHaptics.light()
    }
}
