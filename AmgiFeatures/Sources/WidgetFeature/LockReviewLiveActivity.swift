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
            LockReviewCardView(state: context.state, isCompact: false)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch state.phase {
            case .question:
                question
            case .answer:
                answer
            case .idle:
                idle
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.deckName.isEmpty ? "Amgi" : state.deckName)
                .font(.caption2.weight(.semibold))
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
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder
    private var question: some View {
        Text(state.front)
            .font(.callout)
            .lineLimit(isCompact ? 2 : 4)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
        Button(intent: LockReviewRevealIntent()) {
            pill("Show Answer", detail: "", color: .blue)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var answer: some View {
        Text(state.front)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        Text(state.back)
            .font(.callout.weight(.semibold))
            .lineLimit(isCompact ? 2 : 3)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
            rate(1, "Again", color: .red)
            rate(2, "Hard", color: .orange)
            rate(3, "Good", color: .green)
            rate(4, "Easy", color: .blue)
        }
    }

    @ViewBuilder
    private var idle: some View {
        Text(state.message)
            .font(.callout)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        Button(intent: LockReviewRefreshIntent()) {
            pill("Check Again", detail: "", color: .gray)
        }
        .buttonStyle(.plain)
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
                .font(.caption.weight(.bold))
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
#endif
