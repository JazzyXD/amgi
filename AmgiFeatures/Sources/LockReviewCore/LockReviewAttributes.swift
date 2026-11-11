//
//  LockReviewAttributes.swift
//  LockReviewCore
//

#if os(iOS)
public import ActivityKit
public import Foundation

/// The Live Activity that keeps one due card on the Lock Screen.
///
/// Lives in an engine-free sink because two processes need the very same
/// type: the app requests and updates the activity, and the widget extension
/// renders it. Everything the card view needs travels in `ContentState`, so
/// the extension never reads the app group or the collection.
///
/// ActivityKit caps attributes plus state at 4 KB. `LockReviewController`
/// clips the text fields well under that before every update.
public struct LockReviewAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Phase: String, Codable, Sendable {
            /// Front of a card, with a Show Answer button.
            case question
            /// Back of the same card, with the four rating buttons.
            case answer
            /// No card to show: nothing due, no decks picked, or an error.
            case idle
        }

        public var phase: Phase
        public var deckName: String
        /// `String(cardId)`. The rating buttons echo it back so the app can
        /// refuse to rate a card that is no longer the one on screen.
        public var cardToken: String
        public var front: String
        public var back: String
        public var newCount: Int
        public var learnCount: Int
        public var reviewCount: Int
        /// Next-interval labels in rating order: again, hard, good, easy.
        public var intervals: [String]
        /// Shown in the `idle` phase.
        public var message: String
        /// When this card went up, for the answer-time the engine records.
        public var shownAt: Date

        public var totalDue: Int { newCount + learnCount + reviewCount }

        public init(
            phase: Phase,
            deckName: String = "",
            cardToken: String = "",
            front: String = "",
            back: String = "",
            newCount: Int = 0,
            learnCount: Int = 0,
            reviewCount: Int = 0,
            intervals: [String] = [],
            message: String = "",
            shownAt: Date = Date()
        ) {
            self.phase = phase
            self.deckName = deckName
            self.cardToken = cardToken
            self.front = front
            self.back = back
            self.newCount = newCount
            self.learnCount = learnCount
            self.reviewCount = reviewCount
            self.intervals = intervals
            self.message = message
            self.shownAt = shownAt
        }
    }

    /// iOS ends a Live Activity eight hours after it starts. The controller
    /// reads this to replace the activity before that happens.
    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
#endif
