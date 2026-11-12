//
//  LockReviewSettingsView.swift
//  LockReviewFeature
//

#if os(iOS)
package import SwiftUI
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import LockReviewCore

/// Settings > Lock Screen Review: choose the decks that feed the Lock Screen
/// card, and turn the card on or off.
package struct LockReviewSettingsView: View {
    @State private var model = LockReviewSettingsModel()

    package init() {}

    package var body: some View {
        @Bindable var model = model
        List {
            Section {
                if model.isRunning {
                    Button("Stop Lock Screen Review", role: .destructive) {
                        Task { await model.stop() }
                    }
                } else {
                    Button("Start Lock Screen Review") {
                        Task { await model.start() }
                    }
                    .disabled(model.selected.isEmpty || model.isWorking)
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text(
                    "Shows your next due card on the Lock Screen. Tap Show Answer, then rate it, and the next card appears. No need to open Amgi."
                )
            }

            Section {
                if model.decks.isEmpty {
                    Text(model.didLoad ? "No decks yet. Sync or import a deck first." : "Loading decks\u{2026}")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.decks) { deck in
                    Button {
                        model.toggle(deck.id)
                    } label: {
                        LockReviewDeckRow(deck: deck, isSelected: model.selected.contains(deck.id.rawValue))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Decks on the Lock Screen")
            } footer: {
                Text("A deck includes its subdecks. Cards come from one deck at a time, moving to the next when it runs out.")
            }

            Section {
                Toggle("Wake screen on each card", isOn: $model.wakesScreen)
            } footer: {
                Text("Experimental. iOS dims the Lock Screen after a few seconds and apps cannot change that. This relights it each time you tap a button, and may buzz or chime when it does.")
            }

            Section {
                Text(
                    "iOS removes any Live Activity after 8 hours. Rating a card after the 6 hour mark starts a new one automatically. To bring it back every morning without opening Amgi, add a Shortcuts automation that runs Start Lock Screen Review."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(
                    "Cards show as plain text. Images, audio and formatted math do not appear on the Lock Screen, so picture-heavy decks are better reviewed in the app."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("Good to know")
            }
        }
        .navigationTitle("Lock Screen Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

private struct LockReviewDeckRow: View {
    let deck: DeckInfo
    let isSelected: Bool

    var body: some View {
        let parts = deck.name.components(separatedBy: "::")
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(parts.last ?? deck.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            if deck.counts.total > 0 {
                Text("\(deck.counts.total)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(max(parts.count - 1, 0)) * 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
@Observable
final class LockReviewSettingsModel {
    var decks: [DeckInfo] = []
    var selected: Set<Int64> = []
    var isRunning = false
    var isWorking = false
    var didLoad = false
    var errorMessage: String?
    var wakesScreen: Bool = LockReviewSettings.wakesScreenOnUpdate {
        didSet { LockReviewSettings.wakesScreenOnUpdate = wakesScreen }
    }

    func load() async {
        @Dependency(\.deckClient) var deckClient
        selected = Set(LockReviewSettings.deckIDs)
        isRunning = LockReviewController.shared.isRunning
        do {
            decks = try await deckClient.fetchAll()
        } catch {
            errorMessage = "Could not load your decks."
        }
        didLoad = true
    }

    func toggle(_ id: DeckID) {
        if selected.contains(id.rawValue) {
            selected.remove(id.rawValue)
        } else {
            selected.insert(id.rawValue)
        }
        // Stored in deck-list order, so the Lock Screen walks the decks in
        // the order the user sees them here.
        LockReviewSettings.deckIDs = decks.map(\.id.rawValue).filter { selected.contains($0) }
        if isRunning {
            Task { await LockReviewController.shared.handle(.resume) }
        }
    }

    func start() async {
        isWorking = true
        await LockReviewController.shared.handle(.start)
        isRunning = LockReviewController.shared.isRunning
        errorMessage = LockReviewController.shared.lastError
        isWorking = false
    }

    func stop() async {
        isWorking = true
        await LockReviewController.shared.handle(.stop)
        isRunning = LockReviewController.shared.isRunning
        errorMessage = nil
        isWorking = false
    }
}
#endif
