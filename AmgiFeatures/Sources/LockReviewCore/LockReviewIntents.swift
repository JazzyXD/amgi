//
//  LockReviewIntents.swift
//  LockReviewCore
//

#if os(iOS)
public import AppIntents
import Foundation

// The three button intents are `LiveActivityIntent`s, so iOS runs them in the
// app's process (launching it in the background if needed) and never in the
// widget extension. Each one only forwards to `LockReviewDispatcher`.

/// "Show Answer" on the Lock Screen card.
public struct LockReviewRevealIntent: LiveActivityIntent {
    public init() {}

    public static let title: LocalizedStringResource = "Show Answer"
    public static let isDiscoverable: Bool = false

    public func perform() async throws -> some IntentResult {
        await LockReviewDispatcher.dispatch(.reveal)
        return .result()
    }
}

/// Again / Hard / Good / Easy on the Lock Screen card.
public struct LockReviewRateIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Rate Card"
    public static let isDiscoverable: Bool = false

    @Parameter(title: "Card")
    public var cardToken: String

    @Parameter(title: "Rating")
    public var rating: Int

    public init() {}

    public init(cardToken: String, rating: Int) {
        self.cardToken = cardToken
        self.rating = rating
    }

    public func perform() async throws -> some IntentResult {
        await LockReviewDispatcher.dispatch(.rate(cardToken: cardToken, rating: rating))
        return .result()
    }
}

/// "Check Again" on the idle card: sync, then look for due cards.
public struct LockReviewRefreshIntent: LiveActivityIntent {
    public init() {}

    public static let title: LocalizedStringResource = "Check for Due Cards"
    public static let isDiscoverable: Bool = false

    public func perform() async throws -> some IntentResult {
        await LockReviewDispatcher.dispatch(.refresh)
        return .result()
    }
}

/// Shows up in the Shortcuts app, which is the point: iOS ends every Live
/// Activity after eight hours, and a daily automation running this action
/// puts the card back without opening the app.
public struct LockReviewStartIntent: LiveActivityIntent {
    public init() {}

    public static let title: LocalizedStringResource = "Start Lock Screen Review"
    public static let description = IntentDescription(
        "Puts your next due card on the Lock Screen.",
        categoryName: "Review"
    )
    public static let openAppWhenRun = false

    public func perform() async throws -> some IntentResult {
        await LockReviewDispatcher.dispatch(.start)
        return .result()
    }
}

public struct LockReviewStopIntent: LiveActivityIntent {
    public init() {}

    public static let title: LocalizedStringResource = "Stop Lock Screen Review"
    public static let description = IntentDescription(
        "Takes the review card off the Lock Screen.",
        categoryName: "Review"
    )
    public static let openAppWhenRun = false

    public func perform() async throws -> some IntentResult {
        await LockReviewDispatcher.dispatch(.stop)
        return .result()
    }
}
#endif
