//
//  LockReviewController.swift
//  LockReviewFeature
//

#if os(iOS)
import ActivityKit
import AnkiKit
import AppCore
import Foundation
import IntentsFeature
package import LockReviewCore
import OSLog
import UIKit

/// Owns the Lock Screen card: starts and replaces the Live Activity, and
/// turns each button tap into a scheduler call and a fresh card.
///
/// One instance, on the main actor. Taps are handled strictly one after
/// another, because two quick taps arrive as two overlapping intents and the
/// second must see the queue the first one left behind.
@MainActor
package final class LockReviewController {
    package static let shared = LockReviewController()

    /// Why the last start did not put a card up, in words fit for the
    /// settings screen. Nil when it worked.
    package private(set) var lastError: String?

    private var tail: Task<Void, Never>?
    private var isSyncing = false
    private var lastSyncAttempt = Date.distantPast

    /// iOS ends a Live Activity eight hours after it starts.
    private static let systemLifetime: TimeInterval = 8 * 3600
    /// Replace ours well before that, the next time the user taps a button.
    private static let renewAfter: TimeInterval = 6 * 3600
    private static let syncInterval: TimeInterval = 15 * 60
    private static let emptyQueueSyncInterval: TimeInterval = 60

    // ActivityKit allows 4 KB for the whole state. These leave room for the
    // deck name, the counts and the interval labels.
    private static let frontByteLimit = 900
    private static let backByteLimit = 1200

    fileprivate typealias CardState = LockReviewAttributes.ContentState

    private init() {}

    /// Routes the button intents to this controller. Called once from the
    /// app's bootstrap, before any intent can run.
    package static func install() {
        LockReviewDispatcher.install { action in
            await LockReviewController.shared.handle(action)
        }
    }

    package var isRunning: Bool { !liveActivities.isEmpty }

    /// Runs `action` after every action queued before it has finished.
    package func handle(_ action: LockReviewAction) async {
        let previous = tail
        let task = Task {
            _ = await previous?.value
            await self.process(action)
        }
        tail = task
        await task.value
    }

    /// The app became active or went to the background. Either way the
    /// queue may have moved (an in-app review, a sync), so re-read it.
    package func sceneDidChange() {
        guard LockReviewSettings.isEnabled else { return }
        Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "LockReviewResume", expirationHandler: nil)
            await self.handle(.resume)
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
            }
        }
    }
}

// MARK: - Actions

private extension LockReviewController {
    func process(_ action: LockReviewAction) async {
        switch action {
        case .start:
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                lastError = "Live Activities are turned off for Amgi. Turn them on in the Settings app, under Amgi."
                return
            }
            LockReviewSettings.isEnabled = true
            await showHead()
        case .stop:
            LockReviewSettings.isEnabled = false
            lastError = nil
            await endAll()
        case .refresh:
            await push(CardState(phase: .idle, message: "Checking for cards\u{2026}"))
            await sync()
            await showHead()
        case .resume:
            // Leave an answer the user is reading where it is. The rating
            // buttons check the card against the queue anyway.
            if currentState?.phase == .answer { return }
            await showHead()
        case .reveal:
            await reveal()
        case .rate(let cardToken, let rating):
            await rate(cardToken: cardToken, rating: rating)
        }
    }

    func reveal() async {
        guard var state = currentState else {
            await showHead()
            return
        }
        guard state.phase == .question else { return }
        // The back side already travelled with the question, so flipping
        // needs no engine call and feels instant.
        state.phase = .answer
        await push(state)
    }

    func rate(cardToken: String, rating rawRating: Int) async {
        guard let rating = Rating(rawValue: Int16(clamping: rawRating)) else { return }
        // The card may have sat on the Lock Screen for hours. Record at most
        // a minute, which is what a reviewer left open would be capped at.
        let elapsed = currentState.map { Date().timeIntervalSince($0.shownAt) } ?? 10
        let timeSpentMs = UInt32(min(max(elapsed, 1), 60) * 1000)
        do {
            let head = try await LockReviewEngine.answer(
                cardToken: cardToken,
                rating: rating,
                timeSpentMs: timeSpentMs
            )
            await push(Self.state(for: head))
            syncSoon(queueIsEmpty: head.card == nil)
        } catch {
            Log.review.error("Lock Screen answer failed: \(error)")
            await push(Self.failureState)
        }
    }

    func showHead() async {
        do {
            let head = try await LockReviewEngine.head()
            await push(Self.state(for: head))
        } catch {
            Log.review.error("Lock Screen queue read failed: \(error)")
            await push(Self.failureState)
        }
    }
}

// MARK: - Live Activity

private extension LockReviewController {
    var allActivities: [Activity<LockReviewAttributes>] {
        Activity<LockReviewAttributes>.activities
    }

    /// Activities iOS still lets us update. One that hit the eight-hour cap
    /// stays visible for a while as `.ended`, with buttons that still work,
    /// which is why `currentState` looks at those too.
    var liveActivities: [Activity<LockReviewAttributes>] {
        allActivities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    var currentState: CardState? {
        (liveActivities.first ?? allActivities.first)?.content.state
    }

    func push(_ state: CardState) async {
        let now = Date()
        if let activity = liveActivities.first,
           now.timeIntervalSince(activity.attributes.startedAt) < Self.renewAfter {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            await endAll(except: activity.id)
            return
        }

        // Nothing live, or the live one is getting close to the cap: start a
        // new activity and retire the old one.
        guard LockReviewSettings.isEnabled else { return }
        do {
            let fresh = try Activity<LockReviewAttributes>.request(
                attributes: LockReviewAttributes(startedAt: now),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastError = nil
            await endAll(except: fresh.id)
        } catch {
            Log.review.error("Lock Screen activity request failed: \(error)")
            lastError = "iOS did not let the card start: \(error.localizedDescription)"
            // Could not start a new one, which iOS may refuse while the app
            // is in the background. Keep the old one going for as long as it
            // has left.
            if let activity = liveActivities.first {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func endAll(except keep: String? = nil) async {
        for activity in allActivities where activity.id != keep {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func state(for head: LockReviewHead) -> CardState {
        guard let card = head.card else {
            let message: String
            if !head.hasSelection {
                message = "Pick decks in Amgi, under Settings, Lock Screen Review."
            } else if head.counts.learnCount > 0 {
                message = "Nothing due right now. Learning cards will be back soon."
            } else {
                message = "All caught up."
            }
            return CardState(
                phase: .idle,
                newCount: head.counts.newCount,
                learnCount: head.counts.learnCount,
                reviewCount: head.counts.reviewCount,
                message: message
            )
        }
        let ratings: [Rating] = [.again, .hard, .good, .easy]
        return CardState(
            phase: .question,
            deckName: LockReviewText.clip(head.deckName, maxBytes: 80),
            cardToken: String(card.card.id.rawValue),
            front: LockReviewText.clip(head.front, maxBytes: frontByteLimit),
            back: LockReviewText.clip(head.back, maxBytes: backByteLimit),
            newCount: head.counts.newCount,
            learnCount: head.counts.learnCount,
            reviewCount: head.counts.reviewCount,
            intervals: ratings.map { card.nextIntervals[$0] ?? "" },
            shownAt: Date()
        )
    }

    static var failureState: CardState {
        CardState(phase: .idle, message: "Could not load cards. Open Amgi, then try again.")
    }
}

// MARK: - Sync

private extension LockReviewController {
    /// Sends Lock Screen reviews to the sync server without making the user
    /// open the app: a while after the last sync, and when the queue runs
    /// dry. Not after every card. A sync holds the collection, so the next
    /// tap would wait on it, and the server should not be hit per review.
    func syncSoon(queueIsEmpty: Bool) {
        let sinceLast = Date().timeIntervalSince(lastSyncAttempt)
        let isDue = sinceLast > Self.syncInterval
            || (queueIsEmpty && sinceLast > Self.emptyQueueSyncInterval)
        guard isDue, !isSyncing else { return }
        Task {
            await self.sync()
            // The sync may have pulled reviews done elsewhere.
            await self.handle(.resume)
        }
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncAttempt = Date()
        // Keeps the process alive after the intent that started this returns.
        let background = UIApplication.shared.beginBackgroundTask(withName: "LockReviewSync", expirationHandler: nil)
        do {
            // Detached so no part of the sync can land on the main thread.
            _ = try await Task.detached { try await SyncIntentRunner.run() }.value
        } catch {
            // Not signed in, offline, or a full sync is needed. All of those
            // are the app's to explain, on its sync screen.
            Log.sync.error("Lock Screen sync failed: \(error)")
        }
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
        }
        isSyncing = false
    }
}
#endif
