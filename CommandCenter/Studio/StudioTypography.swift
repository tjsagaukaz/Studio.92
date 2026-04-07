// StudioTypography.swift
// Studio.92 — Command Center
// Unified typography and spacing system.
// Single source of truth for all font roles and layout rhythm.

import SwiftUI

// MARK: - Typography Roles

/// Semantic font roles. Use these instead of arbitrary `.font(.system(size:weight:))`.
/// Every text element maps to exactly one role.
enum StudioTypography {

    // MARK: - Display & Titles

    /// Large section titles, onboarding headers.
    static let largeTitle = Font.system(size: 20, weight: .semibold)

    /// Panel section titles, sidebar major headers (18pt).
    static let titleLarge = Font.system(size: 18, weight: .semibold)

    /// Panel titles, card headers, dialog titles.
    static let title = Font.system(size: 17, weight: .semibold)

    /// Sub-panel headings, artifact headers (16pt).
    static let titleSmall = Font.system(size: 16, weight: .semibold)

    /// Sub-section headings, group labels.
    static let headline = Font.system(size: 15, weight: .semibold)

    /// Emphasized heading variant (medium weight).
    static let headlineMedium = Font.system(size: 15, weight: .medium)

    // MARK: - Body

    /// Primary readable text, chat messages, descriptions.
    static let body = Font.system(size: 14, weight: .regular)

    /// Emphasized body text (labels, active states).
    static let bodyMedium = Font.system(size: 14, weight: .medium)

    /// Bold body (inline emphasis, key values).
    static let bodySemibold = Font.system(size: 14, weight: .semibold)

    // MARK: - Secondary

    /// Secondary readable text, sidebar labels, metadata.
    static let subheadline = Font.system(size: 13, weight: .regular)

    /// Emphasized secondary text (section headers in lists).
    static let subheadlineMedium = Font.system(size: 13, weight: .medium)

    /// Strong secondary text (sidebar group titles).
    static let subheadlineSemibold = Font.system(size: 13, weight: .semibold)

    // MARK: - Footnote / Caption

    /// Tertiary text, timestamps, minor labels.
    static let footnote = Font.system(size: 12, weight: .regular)

    /// Emphasized footnote (badges, status labels).
    static let footnoteMedium = Font.system(size: 12, weight: .medium)

    /// Strong footnote (column headers, tag labels).
    static let footnoteSemibold = Font.system(size: 12, weight: .semibold)

    // MARK: - Caption

    /// Small supporting text, tool trace labels.
    static let caption = Font.system(size: 11, weight: .regular)

    /// Emphasized caption.
    static let captionMedium = Font.system(size: 11, weight: .medium)

    /// Strong caption (status chips, compact headers).
    static let captionSemibold = Font.system(size: 11, weight: .semibold)

    // MARK: - Micro

    /// Tiny indicators, badge counts, compact labels.
    static let micro = Font.system(size: 10, weight: .regular)

    /// Emphasized micro.
    static let microMedium = Font.system(size: 10, weight: .medium)

    /// Strong micro (pill labels, dot annotations).
    static let microSemibold = Font.system(size: 10, weight: .semibold)

    // MARK: - Monospaced (Code & Data)

    /// Code blocks, diffs, terminal output.
    static let code = Font.system(size: 13, weight: .regular, design: .monospaced)

    /// Code with emphasis (line numbers, highlighted tokens).
    static let codeSemibold = Font.system(size: 13, weight: .semibold, design: .monospaced)

    /// Compact code, diff line numbers, inline code.
    static let codeSmall = Font.system(size: 11, weight: .regular, design: .monospaced)

    /// Compact code with emphasis.
    static let codeSmallMedium = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// Data values, metrics, counters.
    static let dataCaption = Font.system(size: 12, weight: .medium, design: .monospaced)

    /// Tiny mono for dense data tables, hashes.
    static let dataMicro = Font.system(size: 10, weight: .medium, design: .monospaced)

    /// Micro mono with semibold for emphasis.
    static let dataMicroSemibold = Font.system(size: 10, weight: .semibold, design: .monospaced)

    /// Mono digits for counts, timers (proportional width for alignment).
    static let monoDigits = Font.caption.monospacedDigit()

    /// Tiny mono digits.
    static let monoDigitsSmall = Font.caption2.monospacedDigit()

    // MARK: - Special

    /// Pill/badge text (very small, always semibold).
    static let badge = Font.system(size: 8, weight: .semibold)

    /// Medium-weight badge for secondary pills.
    static let badgeMedium = Font.system(size: 8, weight: .medium)

    /// Small badge for compact indicators.
    static let badgeSmall = Font.system(size: 9, weight: .medium)

    /// Small badge with semibold.
    static let badgeSmallSemibold = Font.system(size: 9, weight: .semibold)

    /// Small badge mono for compact data.
    static let badgeSmallMono = Font.system(size: 9, weight: .medium, design: .monospaced)
}

// MARK: - Spacing Scale (8pt Grid)

/// Spacing tokens for padding, gaps, and margins.
/// Based on a compressed 4pt/8pt grid that matches Apple's native density.
enum StudioSpacing {
    /// 2pt — Hairline gaps, tight icon offsets.
    static let xxs: CGFloat = 2
    /// 3pt — Micro separations inside compact components.
    static let xxsPlus: CGFloat = 3
    /// 4pt — Tight label-to-value grouping, inline element gaps.
    static let xs: CGFloat = 4
    /// 6pt — Compact stack spacing, small icon-to-text gaps.
    static let sm: CGFloat = 6
    /// 8pt — Standard element spacing, icon-text pairs, list items.
    static let md: CGFloat = 8
    /// 10pt — Comfortable element spacing, card internal padding.
    static let lg: CGFloat = 10
    /// 12pt — Section internal padding, group spacing.
    static let xl: CGFloat = 12
    /// 14pt — Message internal spacing, panel content padding.
    static let xxl: CGFloat = 14
    /// 16pt — Major section padding, card outer padding.
    static let section: CGFloat = 16
    /// 18pt — Panel margins, generous section gaps.
    static let panel: CGFloat = 18
    /// 20pt — Large gaps, sidebar inset, between-section spacing.
    static let sectionGap: CGFloat = 20
    /// 24pt — Column padding, major vertical breathing room.
    static let columnPad: CGFloat = 24
    /// 28pt — Chat message-to-message spacing.
    static let messageGap: CGFloat = 28
    /// 32pt — Major layout margins, column vertical padding.
    static let pagePad: CGFloat = 32
}

// MARK: - Chat Layout

/// Layout constants for the calm chat column.
/// Centralizes chat-specific measurements that build on StudioSpacing + StudioTypography.
enum StudioChatLayout {
    static let columnMinWidth: CGFloat = 620
    static let columnIdealWidth: CGFloat = 680
    static let columnMaxWidth: CGFloat = 720
    static let columnHorizontalPadding: CGFloat = StudioSpacing.columnPad
    static let columnVerticalPadding: CGFloat = StudioSpacing.pagePad
    /// Space between conversation turns.
    static let messageSpacing: CGFloat = 26
    /// Internal spacing inside assistant content.
    static let messageInternalSpacing: CGFloat = 14
    /// Space between user bubble → assistant text.
    static let userToAssistantSpacing: CGFloat = 24
    static let bodyFontSize: CGFloat = 15
    static let assistantFontSize: CGFloat = 15
    static let userFontSize: CGFloat = 15
    static let bodyLetterSpacing: CGFloat = -0.16
    static let bodyLineSpacing: CGFloat = 7
    static let headingFontSize: CGFloat = 17
    static let h1FontSize: CGFloat = 24
    static let h2FontSize: CGFloat = 20
    static let h3FontSize: CGFloat = 17
    static let h4FontSize: CGFloat = 15
    /// Top spacing above headings.
    static let headingTopSpacing: CGFloat = 20
    /// Bottom spacing below headings.
    static let headingBottomSpacing: CGFloat = 8
    static let metaFontSize: CGFloat = 12
    static let listItemSpacing: CGFloat = 8
    /// Paragraph spacing.
    static let paragraphSpacing: CGFloat = 14
    static let assistantReadableMaxWidth: CGFloat = 664
    static let listMarkerSpacing: CGFloat = 14
    static let listIndent: CGFloat = 14
    static let listMarkerWidth: CGFloat = 14
    static let assistantLeadBlockOpacity: Double = 1.0
    static let assistantBodyBlockOpacity: Double = 0.965
    static let assistantPrimaryTextOpacity: Double = 0.97
    static let assistantSecondaryTextOpacity: Double = 0.78
    static let assistantTertiaryTextOpacity: Double = 0.56
    static let assistantLinkOpacity: Double = 0.88
    /// User bubble max width.
    static let userBubbleMaxWidth: CGFloat = 520
    /// User bubble corner radius.
    static let userBubbleCornerRadius: CGFloat = 16
    /// User bubble horizontal padding.
    static let userBubbleHPad: CGFloat = 14
    /// User bubble vertical padding.
    static let userBubbleVPad: CGFloat = 11
    /// Code block padding.
    static let codeBlockPadding: CGFloat = 14
    /// Code block corner radius.
    static let codeBlockRadius: CGFloat = 12
    /// Tool trace opacity (receded behind content).
    static let toolTraceOpacity: Double = 0.5
    static let composerHeight: CGFloat = 38
    static let composerCornerRadius: CGFloat = 20
    static let composerHorizontalPadding: CGFloat = StudioSpacing.sectionGap
    /// Bottom clearance in the chat scroll so the last message floats above the composer.
    static let composerScrollClearance: CGFloat = 160

    static func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let availableWidth = max(totalWidth - (columnHorizontalPadding * 2), 0)
        if availableWidth >= columnMaxWidth {
            return columnIdealWidth
        }
        if availableWidth >= columnMinWidth {
            return min(availableWidth, columnMaxWidth)
        }
        return availableWidth
    }
}

// MARK: - Sidebar Layout

/// Layout constants for the fleet sidebar.
enum StudioSidebarLayout {
    static let inset: CGFloat = StudioSpacing.sectionGap
    static let rowHeight: CGFloat = 32
    static let iconSize: CGFloat = 18
    static let rowSpacing: CGFloat = StudioSpacing.xs
    static let iconTextSpacing: CGFloat = StudioSpacing.md
}
