//
//  LockReviewSettings.swift
//  LockReviewFeature
//

#if os(iOS)
import Foundation

/// What the user chose for Lock Screen Review. Plain `UserDefaults`, because
/// the button intents read it from a background launch with no UI alive.
enum LockReviewSettings {
    private static let deckIDsKey = "lockReview.deckIDs"
    private static let enabledKey = "lockReview.enabled"
    private static let activeDeckKey = "lockReview.activeDeck"

    /// Decks that feed the Lock Screen card.
    static var deckIDs: [Int64] {
        get {
            let stored = UserDefaults.standard.array(forKey: deckIDsKey) as? [NSNumber]
            return stored?.map(\.int64Value) ?? []
        }
        set {
            UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: deckIDsKey)
        }
    }

    /// True between Start and Stop. Decides whether a new Live Activity may
    /// be requested when the old one has expired.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Experimental: send each card change as an alerting update, which
    /// lights the screen again. iOS offers no way to hold the Lock Screen
    /// awake, so this is the nearest thing, and it may buzz or chime.
    static var wakesScreenOnUpdate: Bool {
        get { UserDefaults.standard.bool(forKey: "lockReview.wakeOnUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "lockReview.wakeOnUpdate") }
    }

    /// The deck the last card came from. The next card comes from the same
    /// deck until it runs dry, so the card does not hop between decks.
    static var activeDeckID: Int64? {
        get { (UserDefaults.standard.object(forKey: activeDeckKey) as? NSNumber)?.int64Value }
        set {
            if let newValue {
                UserDefaults.standard.set(NSNumber(value: newValue), forKey: activeDeckKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeDeckKey)
            }
        }
    }
}
#endif
