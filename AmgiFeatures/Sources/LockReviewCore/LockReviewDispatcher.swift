//
//  LockReviewDispatcher.swift
//  LockReviewCore
//

#if os(iOS)
import Foundation

/// What a Lock Screen button, a Shortcut, or the app itself asks for.
public enum LockReviewAction: Sendable, Equatable {
    /// Turn Lock Screen Review on and put the next due card up.
    case start
    /// Turn it off and take the card down.
    case stop
    /// Sync, then show whatever is due now.
    case refresh
    /// The app moved to the foreground or background: re-read the queue
    /// without syncing.
    case resume
    /// Flip the card on screen to its answer side.
    case reveal
    /// Rate the card on screen. `rating` is 1...4 (again, hard, good, easy).
    case rate(cardToken: String, rating: Int)
    /// Take back the rating just given.
    case undo
    /// Move on to the next chosen deck that has cards waiting.
    case nextDeck
}

/// The seam between the intents and the engine.
///
/// The button intents have to be compiled into the widget extension as well
/// as the app, because the Live Activity view names them. The extension must
/// never link the Rust engine, so the intents cannot call it directly.
/// Instead the app installs a handler here at launch and the intents forward
/// to it. `LiveActivityIntent` always runs in the app's process, so in the
/// extension the handler is simply never set.
@MainActor
public enum LockReviewDispatcher {
    public typealias Handler = @MainActor (LockReviewAction) async -> Void

    private static var handler: Handler?

    public static func install(_ newHandler: @escaping Handler) {
        handler = newHandler
    }

    static func dispatch(_ action: LockReviewAction) async {
        // A button tap can launch the app cold. `App.init` installs the
        // handler before any intent runs, but waiting a moment costs nothing
        // and keeps a tap from being dropped if that order ever slips.
        var attempts = 0
        while handler == nil, attempts < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        await handler?(action)
    }
}
#endif
