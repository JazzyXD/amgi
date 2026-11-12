//
//  LockReviewLiveActivity.swift
//  WidgetFeature
//

#if os(iOS)
import ActivityKit
import AppIntents
import LockReviewCore
public import SwiftUI
import WidgetKit

/// The Lock Screen review card: one due card, a Show Answer button, then the
/// four rating buttons.
///
/// Everything it draws arrives in the activity's content state. The buttons
/// run `LiveActivityIntent`s, which iOS executes in the app's process, so
/// this extension still never touches the collection or the Rust engine.
///
/// iOS gives a Lock Screen Live Activity about 160 points of height and
/// clips the rest, which is what the line limits below are sized for.
public struct LockReviewLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockReviewAttributes.self) { context in
            // 136 of content plus 24 of padding is the 160 points iOS allows
            // a Lock Screen Live Activity. Anything taller gets clipped.
            LockReviewCardView(state: context.state, isCompact: false)
                .frame(height: 136)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    LockReviewCardView(state: context.state, isCompact: true)
                }
            } compactLeading: {
                Image(systemName: "rectangle.stack")
            } compactTrailing: {
                Text("\(context.state.totalDue)")
                    .monospacedDigit()
            } minimal: {
                Text("\(context.state.totalDue)")
                    .monospacedDigit()
            }
        }
    }
}

struct LockReviewCardView: View {
    let state: LockReviewAttributes.ContentState
    /// The Dynamic Island's expanded area is shorter than the Lock Screen's.
    let isCompact: Bool

    /// 160 points is the tallest a Lock Screen Live Activity may be. The
    /// Lock Screen layout claims all of it (136 here plus 12 of padding top
    /// and bottom from the configuration), so the card keeps one size
    /// instead of growing and shrinking with the text.
    private static let lockScreenContentHeight: CGFloat = 136

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            header
            surface
            controls
        }
        .frame(height: isCompact ? nil : Self.lockScreenContentHeight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.deckName.isEmpty ? "Amgi" : state.deckName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            count(state.newCount, color: .blue, label: "new")
            count(state.learnCount, color: .red, label: "learning")
            count(state.reviewCount, color: .green, label: "to review")
        }
    }

    private func count(_ value: Int, color: Color, label: String) -> some View {
        Text("\(value)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel("\(value) \(label)")
    }

    /// The card face: its own raised panel, apart from the buttons.
    private var surface: some View {
        VStack(spacing: 4) {
            switch state.phase {
            case .question:
                Text(state.front)
                    .font(.title3.weight(.semibold))
                    .lineLimit(isCompact ? 2 : 3)
                    .minimumScaleFactor(0.55)
            case .answer:
                Text(state.front)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.back)
                    .font(.body.weight(.semibold))
                    .lineLimit(isCompact ? 2 : 3)
                    .minimumScaleFactor(0.55)
            case .idle:
                Text(state.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: isCompact ? nil : .infinity)
        .background(
            Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var controls: some View {
        switch state.phase {
        case .question:
            Button(intent: LockReviewRevealIntent()) {
                pill("Show Answer", detail: "", color: .blue)
            }
            .buttonStyle(.plain)
        case .answer:
            HStack(spacing: 6) {
                rate(1, "Again", color: .red)
                rate(2, "Hard", color: .orange)
                rate(3, "Good", color: .green)
                rate(4, "Easy", color: .blue)
            }
        case .idle:
            Button(intent: LockReviewRefreshIntent()) {
                pill("Check Again", detail: "", color: .gray)
            }
            .buttonStyle(.plain)
        }
    }

    private func rate(_ rating: Int, _ title: String, color: Color) -> some View {
        let interval = state.intervals.indices.contains(rating - 1) ? state.intervals[rating - 1] : ""
        return Button(intent: LockReviewRateIntent(cardToken: state.cardToken, rating: rating)) {
            pill(title, detail: interval, color: color)
        }
        .buttonStyle(.plain)
    }

    /// A button face. `detail` is the next interval under a rating.
    private func pill(_ title: String, detail: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
#endif
