//
//  LockReviewEngine.swift
//  LockReviewFeature
//

#if os(iOS)
import AnkiKit
import AnkiServices
import Dependencies
import Foundation

/// What the Lock Screen card should show next.
struct LockReviewHead: Sendable {
    var deckName: String
    /// Nil when nothing is due in the chosen decks right now.
    var card: QueuedReviewCard?
    var front: String
    var back: String
    /// Due counts summed over the chosen decks.
    var counts: DeckCounts
    /// False when no chosen deck exists in this collection.
    var hasSelection: Bool
}

/// The scheduler round-trips behind the Lock Screen card.
///
/// Stateless on purpose. iOS can kill the app between two taps, so nothing
/// about "the current card" is kept in memory: every call re-reads the queue
/// from the collection, and the card token carried by the button says which
/// card the user was looking at.
///
/// The engine serves one deck at a time (the collection's current deck plus
/// its subdecks), so several chosen decks are worked through in turn. The
/// current deck is left pointing at the Lock Screen's deck afterwards;
/// `ReviewSession` re-asserts its own deck before each answer, which is what
/// keeps an in-app review that was left open from being pulled off course.
enum LockReviewEngine {
    /// How far into the queue to look for the card on screen. It is nearly
    /// always first; a learning card that came due can sit ahead of it.
    private static let searchDepth: Int32 = 30

    static func head() async throws -> LockReviewHead {
        let services = Services()
        let selection = LockReviewSettings.deckIDs
        let preferred = LockReviewSettings.activeDeckID
        return try await Task.detached {
            try services.head(selection: selection, preferred: preferred)
        }.value
    }

    /// Rates the card named by `cardToken` if it is still waiting in the
    /// queue, then returns whatever is due next. A token that no longer
    /// matches (the card was answered in the app, on another device, or was
    /// buried) is ignored rather than guessed at.
    static func answer(
        cardToken: String,
        rating: Rating,
        timeSpentMs: UInt32
    ) async throws -> LockReviewHead {
        let services = Services()
        let selection = LockReviewSettings.deckIDs
        let preferred = LockReviewSettings.activeDeckID
        return try await Task.detached {
            try services.answer(
                cardToken: cardToken,
                rating: rating,
                timeSpentMs: timeSpentMs,
                selection: selection,
                preferred: preferred
            )
        }.value
    }
}

extension LockReviewEngine {
    /// Where the next card comes from.
    private struct Located {
        var hasSelection: Bool
        var totals: DeckCounts
        var deck: DeckInfo?
        var queue: QueuedCardsResult?
    }

    /// The Sendable service facades, resolved once in the caller's dependency
    /// scope and then carried into the detached work, the same way
    /// `ReviewSession` does it.
    private struct Services: Sendable {
        let decks: DecksService
        let scheduler: SchedulerService
        let cardRendering: CardRenderingService

        init() {
            @Dependency(\.decksService) var decksService
            @Dependency(\.schedulerService) var schedulerService
            @Dependency(\.cardRenderingService) var cardRenderingService
            decks = decksService
            scheduler = schedulerService
            cardRendering = cardRenderingService
        }

        func head(selection: [Int64], preferred: Int64?) throws -> LockReviewHead {
            let located = try locate(selection: selection, preferred: preferred, limit: 1)
            return try render(located)
        }

        func answer(
            cardToken: String,
            rating: Rating,
            timeSpentMs: UInt32,
            selection: [Int64],
            preferred: Int64?
        ) throws -> LockReviewHead {
            let located = try locate(
                selection: selection,
                preferred: preferred,
                limit: LockReviewEngine.searchDepth
            )
            let match = located.queue?.cards.first { String($0.card.id.rawValue) == cardToken }
            if let match {
                do {
                    try scheduler.answerReviewCard(match.card.id, rating, timeSpentMs, match.states)
                } catch {
                    // The engine only accepts the card at the front of its
                    // cached queue. After the app has been relaunched the
                    // queue is rebuilt, and new cards can land in a different
                    // slot between reviews, so the card on screen may now be
                    // second. A failed answer rolls back and drops that
                    // cache, and with no cache the engine checks only that
                    // the card's state is unchanged. So: try once more.
                    _ = try? scheduler.answerReviewCard(match.card.id, rating, timeSpentMs, match.states)
                }
            }
            return try head(selection: selection, preferred: LockReviewSettings.activeDeckID)
        }

        private func render(_ located: Located) throws -> LockReviewHead {
            guard let deck = located.deck, let card = located.queue?.cards.first else {
                return LockReviewHead(
                    deckName: "",
                    card: nil,
                    front: "",
                    back: "",
                    counts: located.totals,
                    hasSelection: located.hasSelection
                )
            }
            let rendered = try cardRendering.renderCard(card.card.id)
            return LockReviewHead(
                deckName: LockReviewText.leafName(deck.name),
                card: card,
                front: LockReviewText.question(rendered.frontHTML),
                back: LockReviewText.answer(
                    frontHTML: rendered.frontHTML,
                    backHTML: rendered.backHTML
                ),
                counts: located.totals,
                hasSelection: true
            )
        }

        /// Finds the first chosen deck with a card to show and returns the
        /// top `limit` cards of its queue.
        private func locate(selection: [Int64], preferred: Int64?, limit: Int32) throws -> Located {
            guard !selection.isEmpty else {
                return Located(hasSelection: false, totals: .zero)
            }
            let all = try decks.fetchAll()
            let chosen = Set(selection)
            let existing = all.filter { chosen.contains($0.id.rawValue) }
            // A parent deck already serves its subdecks, so a subdeck picked
            // alongside its parent would only be counted twice.
            let roots = existing.filter { deck in
                !existing.contains { $0.id != deck.id && deck.name.hasPrefix($0.name + "::") }
            }
            guard !roots.isEmpty else {
                return Located(hasSelection: false, totals: .zero)
            }

            var totals = DeckCounts.zero
            for deck in roots {
                totals.newCount += deck.counts.newCount
                totals.learnCount += deck.counts.learnCount
                totals.reviewCount += deck.counts.reviewCount
            }

            // Stay on the deck the last card came from until it runs dry.
            var ordered = roots
            if let preferred, let index = ordered.firstIndex(where: { $0.id.rawValue == preferred }) {
                ordered.insert(ordered.remove(at: index), at: 0)
            }
            // Skip decks the tree already reports as empty: switching the
            // current deck is a real collection change, not a free lookup.
            // If no deck reports anything, ask each one anyway, in case the
            // tree came back without counts.
            let candidates = totals.total > 0 ? ordered.filter { $0.counts.total > 0 } : ordered

            for deck in candidates {
                try decks.setCurrentDeck(deck.id)
                let queue = try scheduler.getQueuedCards(limit)
                if !queue.cards.isEmpty {
                    LockReviewSettings.activeDeckID = deck.id.rawValue
                    return Located(hasSelection: true, totals: totals, deck: deck, queue: queue)
                }
            }
            return Located(hasSelection: true, totals: totals)
        }
    }
}
#endif
