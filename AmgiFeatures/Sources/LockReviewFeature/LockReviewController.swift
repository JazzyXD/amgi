//
//  LockReviewController.swift
//  LockReviewFeature
//

#if os(iOS)
import ActivityKit
import AnkiKit
import AppCore
import AppShared
import Foundation
import IntentsFeature
package import LockReviewCore
import OSLog
import UIKit
import WidgetKit

/// Owns the review card shown outside the app, on the Lock Screen (a Live
/// Activity) and on the Home Screen (a widget): turns each button tap into a
/// scheduler call and a fresh card, and shows that card in both places.
///
/// The card on offer is recorded once, in `LockReviewSnapshotStore`. The
/// widget reads it from there, and the Live Activity is sent a copy cut down
/// to ActivityKit's size limit. That shared record is why rating a card in
/// one place moves the other one on too.
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
    /// The widget has no such limit, only a sensible ceiling.
    private static let storedByteLimit = 6000

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
        // The widget needs this even when the Lock Screen card is off.
        guard LockReviewSettings.isEnabled || !LockReviewSettings.deckIDs.isEmpty else { return }
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
            await publish(CardState(phase: .idle, message: "Checking for cards\u{2026}"))
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
        case .undo:
            await undo()
        case .nextDeck:
            await show { try await LockReviewEngine.nextDeck() }
        }
    }

    func reveal() async {
        guard let snapshot = LockReviewSnapshotStore.read() else {
            await showHead()
            return
        }
        var state = snapshot.state
        guard state.phase == .question else { return }
        // The back side already travelled with the question, so flipping
        // needs no engine call and feels instant.
        state.phase = .answer
        await publish(state, canUndo: snapshot.canUndo)
    }

    func rate(cardToken: String, rating rawRating: Int) async {
        guard let rating = Rating(rawValue: Int16(clamping: rawRating)) else { return }
        // The card may have sat on screen for hours. Record at most a
        // minute, which is what a reviewer left open would be capped at.
        let elapsed = currentState.map { Date().timeIntervalSince($0.shownAt) } ?? 10
        let timeSpentMs = UInt32(min(max(elapsed, 1), 60) * 1000)
        let deckBefore = LockReviewSettings.activeDeckID
        do {
            let result = try await LockReviewEngine.answer(
                cardToken: cardToken,
                rating: rating,
                timeSpentMs: timeSpentMs
            )
            // Undo takes back the collection's last change. If the deck ran
            // out and the next card came from another deck, that last change
            // is the deck switch, not the rating, so undo is not offered.
            let canUndo = result.didAnswer && LockReviewSettings.activeDeckID == deckBefore
            await publish(result.head, canUndo: canUndo)
            refreshProgress()
            syncSoon(queueIsEmpty: result.head.card == nil)
        } catch {
            Log.review.error("Review card answer failed: \(error)")
            await publish(Self.failureState)
        }
    }

    func undo() async {
        guard LockReviewSnapshotStore.read()?.canUndo == true else { return }
        await show { try await LockReviewEngine.undo() }
        refreshProgress()
    }

    func showHead() async {
        await show { try await LockReviewEngine.head() }
    }

    func show(_ load: () async throws -> LockReviewHead) async {
        do {
            await publish(try await load())
        } catch {
            Log.review.error("Review card queue read failed: \(error)")
            await publish(Self.failureState)
        }
    }

    /// Today's count and the streak on the widget come from the snapshot the
    /// app's other widgets already use. Rewriting it also reloads them.
    func refreshProgress() {
        Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "LockReviewProgress", expirationHandler: nil)
            await writeWidgetSnapshot()
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
            }
        }
    }
}

// MARK: - Publishing

private extension LockReviewController {
    var currentState: CardState? {
        LockReviewSnapshotStore.read()?.state
            ?? (liveActivities.first ?? allActivities.first)?.content.state
    }

    func publish(_ head: LockReviewHead, canUndo: Bool = false) async {
        await publish(Self.state(for: head), canUndo: canUndo, switchableDecks: head.switchableDecks)
    }

    /// Records `state` as the card on offer, then shows it on the widget and
    /// on the Lock Screen.
    func publish(_ state: CardState, canUndo: Bool = false, switchableDecks: Int? = nil) async {
        let decks = switchableDecks ?? LockReviewSnapshotStore.read()?.switchableDecks ?? 0
        LockReviewSnapshotStore.write(
            LockReviewSnapshot(state: state, canUndo: canUndo, switchableDecks: decks)
        )
        WidgetCenter.shared.reloadTimelines(ofKind: LockReviewSnapshotStore.widgetKind)

        var clipped = state
        clipped.front = LockReviewText.clip(state.front, maxBytes: Self.frontByteLimit)
        clipped.back = LockReviewText.clip(state.back, maxBytes: Self.backByteLimit)
        await push(clipped)
    }
}

// MARK: - Live Activity

private extension LockReviewController {
    var allActivities: [Activity<LockReviewAttributes>] {
        Activity<LockReviewAttributes>.activities
    }

    /// Activities iOS still lets us update. One that hit the eight-hour cap
    /// stays visible for a while as `.ended`, with buttons that still work,
    /// which is why `currentState` falls back to those too.
    var liveActivities: [Activity<LockReviewAttributes>] {
        allActivities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    func push(_ state: CardState) async {
        let now = Date()
        if let activity = liveActivities.first,
           now.timeIntervalSince(activity.attributes.startedAt) < Self.renewAfter {
            let id = activity.id
            await LockReviewActivities.update(
                id: id,
                state: state,
                alerting: LockReviewSettings.wakesScreenOnUpdate && state.phase != .idle
            )
            await LockReviewActivities.endAll(except: id)
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
            let freshID = fresh.id
            lastError = nil
            await LockReviewActivities.endAll(except: freshID)
        } catch {
            Log.review.error("Lock Screen activity request failed: \(error)")
            lastError = "iOS did not let the card start: \(error.localizedDescription)"
            // Could not start a new one, which iOS may refuse while the app
            // is in the background. Keep the old one going for as long as it
            // has left.
            if let id = liveActivities.first?.id {
                await LockReviewActivities.update(id: id, state: state)
            }
        }
    }

    func endAll() async {
        await LockReviewActivities.endAll(except: nil)
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
            front: LockReviewText.clip(head.front, maxBytes: storedByteLimit),
            back: LockReviewText.clip(head.back, maxBytes: storedByteLimit),
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

/// `Activity` is not `Sendable`, so an instance read on the main actor cannot
/// be handed to its own async `update` and `end`. These look the activity up
/// again off the main actor, by id, and call it there.
private enum LockReviewActivities {
    @concurrent
    static func update(
        id: String,
        state: LockReviewAttributes.ContentState,
        alerting: Bool = false
    ) async {
        for activity in Activity<LockReviewAttributes>.activities where activity.id == id {
            let content = ActivityContent(state: state, staleDate: nil)
            if alerting {
                let alert = AlertConfiguration(title: "Amgi", body: "Next card", sound: .default)
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
        }
    }

    @concurrent
    static func endAll(except keep: String?) async {
        for activity in Activity<LockReviewAttributes>.activities where activity.id != keep {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
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
