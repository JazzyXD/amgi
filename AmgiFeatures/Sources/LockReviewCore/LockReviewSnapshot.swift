//
//  LockReviewSnapshot.swift
//  LockReviewCore
//

#if os(iOS)
import AppCore
import Foundation

/// The card currently on offer, as the Home Screen widget needs it.
///
/// The Live Activity gets its state pushed to it by ActivityKit. A widget has
/// no such channel: it is a separate process that redraws from whatever it
/// can read, so the app writes this to the app group after every change and
/// then asks WidgetKit to reload. It is also the single record of "the card
/// on screen", which is what keeps the widget and the Lock Screen card
/// showing the same thing.
public struct LockReviewSnapshot: Codable, Sendable {
    public var state: LockReviewAttributes.ContentState
    /// True right after a card was rated from the widget or the Lock Screen,
    /// while that rating is still the collection's last change.
    public var canUndo: Bool
    /// How many of the chosen decks have cards waiting. The deck switcher
    /// only shows when there is somewhere to switch to.
    public var switchableDecks: Int

    public init(state: LockReviewAttributes.ContentState, canUndo: Bool, switchableDecks: Int) {
        self.state = state
        self.canUndo = canUndo
        self.switchableDecks = switchableDecks
    }
}

public enum LockReviewSnapshotStore {
    /// The review widget's WidgetKit kind, shared so the app can reload it.
    public static let widgetKind = "AmgiReviewWidget"

    private static let key = "lockReview.snapshot"

    public static func read() -> LockReviewSnapshot? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LockReviewSnapshot.self, from: data)
    }

    public static func write(_ snapshot: LockReviewSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }
}
#endif
