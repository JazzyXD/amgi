//
//  LockReviewWidget.swift
//  WidgetFeature
//

#if os(iOS)
import AppCore
import AppIntents
import Foundation
import LockReviewCore
public import SwiftUI
import WidgetKit

/// The Home Screen review widget: a full card, the rating buttons, undo, a
/// deck switcher and today's progress.
///
/// It reads the card from `LockReviewSnapshotStore` in the app group. Its
/// buttons are the same `LiveActivityIntent`s the Lock Screen card uses, so
/// they run in the app's process, where the engine is; the app then rewrites
/// the snapshot and reloads this widget. The extension itself still never
/// opens the collection.
public struct LockReviewWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: LockReviewSnapshotStore.widgetKind,
            intent: LockReviewWidgetIntent.self,
            provider: LockReviewWidgetProvider()
        ) { entry in
            LockReviewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Amgi Review")
        .description("Review your due cards right on the Home Screen.")
        .supportedFamilies([.systemLarge])
    }
}

/// Nothing to configure. The decks are chosen in the app, under Settings,
/// so the widget and the Lock Screen card always share one list.
struct LockReviewWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Amgi Review"
    static let description = IntentDescription("Review your due cards on the Home Screen.")
}

struct LockReviewWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: LockReviewSnapshot?
    var reviewedToday: Int
    var streak: Int

    static func current() -> LockReviewWidgetEntry {
        let totals = WidgetSnapshotStore.read(deckId: 0)
        return LockReviewWidgetEntry(
            date: Date(),
            snapshot: LockReviewSnapshotStore.read(),
            reviewedToday: totals?.reviewedToday ?? 0,
            streak: totals?.streak ?? 0
        )
    }

    static var sample: LockReviewWidgetEntry {
        LockReviewWidgetEntry(
            date: Date(),
            snapshot: LockReviewSnapshot(
                state: .init(
                    phase: .question,
                    deckName: "Deck",
                    front: "Your next due card shows here.",
                    newCount: 5,
                    learnCount: 2,
                    reviewCount: 13
                ),
                canUndo: false,
                switchableDecks: 1
            ),
            reviewedToday: 7,
            streak: 3
        )
    }
}

struct LockReviewWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = LockReviewWidgetIntent
    typealias Entry = LockReviewWidgetEntry

    func placeholder(in context: Context) -> LockReviewWidgetEntry {
        .sample
    }

    func snapshot(for configuration: LockReviewWidgetIntent, in context: Context) async -> LockReviewWidgetEntry {
        context.isPreview ? .sample : .current()
    }

    func timeline(for configuration: LockReviewWidgetIntent, in context: Context) async -> Timeline<LockReviewWidgetEntry> {
        // The app reloads this widget whenever the card changes. The
        // half-hourly refresh only covers the case where it could not.
        Timeline(entries: [.current()], policy: .after(Date().addingTimeInterval(1800)))
    }
}

struct LockReviewWidgetView: View {
    let entry: LockReviewWidgetEntry

    private var state: LockReviewAttributes.ContentState {
        entry.snapshot?.state ?? .init(
            phase: .idle,
            message: "Open Amgi, go to Settings, then Lock Screen Review, and pick the decks to review here."
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            face
            controls
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if (entry.snapshot?.switchableDecks ?? 0) > 1 {
                Button(intent: LockReviewNextDeckIntent()) {
                    HStack(spacing: 4) {
                        deckName
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next deck")
            } else {
                deckName
            }
            Spacer(minLength: 8)
            count(state.newCount, color: .blue, label: "new")
            count(state.learnCount, color: .red, label: "learning")
            count(state.reviewCount, color: .green, label: "to review")
        }
    }

    private var deckName: some View {
        Text(state.deckName.isEmpty ? "Amgi" : state.deckName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func count(_ value: Int, color: Color, label: String) -> some View {
        Text("\(value)")
            .font(.footnote.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel("\(value) \(label)")
    }

    // MARK: Card face

    private var face: some View {
        VStack(spacing: 8) {
            switch state.phase {
            case .question:
                Text(state.front)
                    .font(.title2.weight(.semibold))
                    .minimumScaleFactor(0.45)
            case .answer:
                Text(state.front)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Divider()
                Text(state.back)
                    .font(.title3.weight(.medium))
                    .minimumScaleFactor(0.45)
            case .idle:
                Text(state.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.7)
            }
        }
        .multilineTextAlignment(.center)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    // MARK: Buttons

    @ViewBuilder
    private var controls: some View {
        switch state.phase {
        case .question:
            Button(intent: LockReviewRevealIntent()) {
                LockReviewWidgetPill(title: "Show Answer", detail: "", color: .blue)
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
                LockReviewWidgetPill(title: "Check Again", detail: "", color: .gray)
            }
            .buttonStyle(.plain)
        }
    }

    private func rate(_ rating: Int, _ title: String, color: Color) -> some View {
        let interval = state.intervals.indices.contains(rating - 1) ? state.intervals[rating - 1] : ""
        return Button(intent: LockReviewRateIntent(cardToken: state.cardToken, rating: rating)) {
            LockReviewWidgetPill(title: title, detail: interval, color: color)
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        let done = entry.reviewedToday
        let left = state.totalDue
        return HStack(spacing: 10) {
            if entry.snapshot?.canUndo == true {
                Button(intent: LockReviewUndoIntent()) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(done) done today, \(left) left")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                ProgressView(value: Double(done), total: Double(max(done + left, 1)))
                    .tint(.green)
            }
            if entry.streak > 0 {
                Label("\(entry.streak)", systemImage: "flame.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(entry.streak) day streak")
            }
        }
    }
}

/// A button face. `detail` is the next interval under a rating.
struct LockReviewWidgetPill: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
#endif
