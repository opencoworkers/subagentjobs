// CharacterController.swift — stateful 7-state machine.
// Wraps the transition logic (celebrate, heart, dizzy) that sits above
// the basic BuddyState → CharacterState mapping.
//
// celebrate  fires when tokensToday crosses a 50K boundary
// heart      fires when a `waiting` state resolves within 5 seconds
// dizzy      fires on external trigger (shake / double-tap equivalent)
//
// All transient states (celebrate, heart, dizzy) revert to the base
// state after a fixed display duration.

import Foundation

@MainActor
public final class CharacterController: @unchecked Sendable {

    // MARK: - Published state

    public private(set) var currentState: CharacterState = .sleep
    public private(set) var currentIdleVariant: Int = 0

    // MARK: - Configuration

    /// Total idle variants in the active manifest (default 9 for bufo).
    public var idleVariantCount: Int = 9

    // MARK: - Internal bookkeeping

    private var previousTokensToday: UInt64 = 0
    private var waitingStartedAt: Date? = nil
    private var transientTask: Task<Void, Never>? = nil

    // MARK: - Public API

    public init() {}

    /// Drive the state machine with a fresh BuddyState snapshot.
    public func update(_ state: BuddyState) {
        // Transient states (celebrate/heart/dizzy) block normal updates until they expire.
        if case .celebrate = currentState { return }
        if case .heart     = currentState { return }
        if case .dizzy     = currentState { return }

        // ── Celebrate: token boundary crossing (every 50K) ────────────────────
        if previousTokensToday > 0 {
            let prevLevel = previousTokensToday / 50_000
            let currLevel = state.tokensToday   / 50_000
            if currLevel > prevLevel {
                previousTokensToday = state.tokensToday
                triggerTransient(.celebrate, duration: 3.0, thenReturn: CharacterState.from(state))
                return
            }
        }
        previousTokensToday = state.tokensToday

        // ── Heart: approval within 5 seconds ─────────────────────────────────
        if let waitStart = waitingStartedAt, state.sessionsWaiting == 0 {
            waitingStartedAt = nil
            let elapsed = Date().timeIntervalSince(waitStart)
            if elapsed < 5.0 {
                triggerTransient(.heart, duration: 2.0, thenReturn: CharacterState.from(state))
                return
            }
        }

        // ── Track attention entry for heart detection ─────────────────────────
        let base = CharacterState.from(state)
        if base == .attention && currentState != .attention {
            waitingStartedAt = Date()
        } else if base != .attention {
            waitingStartedAt = nil
        }

        // ── Normal base state ─────────────────────────────────────────────────
        if base != currentState || base == .idle {
            currentState = base
            if base == .idle {
                currentIdleVariant = Int.random(in: 0..<max(1, idleVariantCount))
            }
        }
    }

    /// External dizzy trigger (shake gesture / double-tap).
    public func triggerDizzy() {
        triggerTransient(.dizzy, duration: 2.5, thenReturn: currentState == .dizzy ? .idle : currentState)
    }

    // MARK: - Test helpers (internal to BuddyCore)

    /// Force-set state without going through the update pipeline (used in tests).
    public func forceState(_ state: CharacterState) {
        transientTask?.cancel()
        transientTask = nil
        currentState = state
    }

    /// Backdate the `waitingStartedAt` timestamp to simulate slow approvals (used in tests).
    public func backdateWaitingStart(by seconds: TimeInterval) {
        if waitingStartedAt != nil {
            waitingStartedAt = Date(timeIntervalSinceNow: -seconds)
        }
    }

    /// Override the idle variant count (used in tests).
    public func setIdleVariantCount(_ n: Int) {
        idleVariantCount = n
    }

    // MARK: - Private helpers

    private func triggerTransient(_ state: CharacterState, duration: TimeInterval, thenReturn base: CharacterState) {
        transientTask?.cancel()
        currentState = state
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.currentState = base
        }
    }
}
