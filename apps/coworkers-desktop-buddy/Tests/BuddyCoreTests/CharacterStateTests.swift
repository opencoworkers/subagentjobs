// CharacterStateTests.swift
// Tests the 7-state character state machine.
// Mirrors the ESP32 firmware logic: sleep/idle/busy/attention/celebrate/dizzy/heart.

import Testing
@testable import BuddyCore

@Suite("CharacterState — BuddyState mapping")
@MainActor
struct CharacterStateTests {

    // MARK: - Basic state mapping

    @Test("no connection → sleep")
    func notConnectedIsSleep() {
        let state = BuddyState(connected: false)
        #expect(CharacterState.from(state) == .sleep)
    }

    @Test("connected, no sessions → idle")
    func connectedNoSessionsIsIdle() {
        let state = BuddyState(connected: true, sessionsTotal: 0, sessionsRunning: 0, sessionsWaiting: 0)
        #expect(CharacterState.from(state) == .idle)
    }

    @Test("sessions running → busy")
    func runningSessionIsBusy() {
        let state = BuddyState(connected: true, sessionsTotal: 2, sessionsRunning: 2, sessionsWaiting: 0)
        #expect(CharacterState.from(state) == .busy)
    }

    @Test("waiting beats running → attention")
    func waitingBeatsRunning() {
        let state = BuddyState(connected: true, sessionsTotal: 3, sessionsRunning: 2, sessionsWaiting: 1)
        #expect(CharacterState.from(state) == .attention)
    }

    @Test("sessions exist but all idle → idle")
    func idleSessionsAreIdle() {
        let state = BuddyState(connected: true, sessionsTotal: 4, sessionsRunning: 0, sessionsWaiting: 0)
        #expect(CharacterState.from(state) == .idle)
    }

    // MARK: - CharacterController transitions

    @Test("celebrate triggers at 50K token boundary")
    func celebrateAt50KBoundary() async {
        let ctrl = CharacterController()
        ctrl.update(BuddyState(connected: true, tokensToday: 49_000))
        #expect(ctrl.currentState != .celebrate)

        ctrl.update(BuddyState(connected: true, tokensToday: 51_000))
        #expect(ctrl.currentState == .celebrate)
    }

    @Test("celebrate does NOT trigger when below first 50K")
    func noCelebrateUnder50K() async {
        let ctrl = CharacterController()
        ctrl.update(BuddyState(connected: true, tokensToday: 0))
        ctrl.update(BuddyState(connected: true, tokensToday: 1_000))
        ctrl.update(BuddyState(connected: true, tokensToday: 49_999))
        #expect(ctrl.currentState != .celebrate)
    }

    @Test("celebrate triggers for each additional 50K crossing")
    func celebrateEvery50K() async {
        let ctrl = CharacterController()
        ctrl.update(BuddyState(connected: true, tokensToday: 49_000))
        ctrl.update(BuddyState(connected: true, tokensToday: 51_000)) // 1st crossing
        #expect(ctrl.currentState == .celebrate)
        // Manually reset to idle (as if celebrate timer fired)
        ctrl.forceState(.idle)

        ctrl.update(BuddyState(connected: true, tokensToday: 99_000))
        ctrl.update(BuddyState(connected: true, tokensToday: 101_000)) // 2nd crossing
        #expect(ctrl.currentState == .celebrate)
    }

    @Test("heart triggers when waiting resolves within 5s")
    func heartOnFastApproval() async {
        let ctrl = CharacterController()
        // Enter attention
        ctrl.update(BuddyState(connected: true, sessionsWaiting: 1))
        #expect(ctrl.currentState == .attention)
        // Resolve within 5s (simulate < 1s by not sleeping)
        ctrl.update(BuddyState(connected: true, sessionsRunning: 1, sessionsWaiting: 0))
        #expect(ctrl.currentState == .heart)
    }

    @Test("heart does NOT trigger when waiting takes > 5s")
    func noHeartOnSlowApproval() async throws {
        let ctrl = CharacterController()
        ctrl.update(BuddyState(connected: true, sessionsWaiting: 1))
        // Simulate 6s elapsed by backdating the waitingStart
        ctrl.backdateWaitingStart(by: 6)
        ctrl.update(BuddyState(connected: true, sessionsRunning: 1, sessionsWaiting: 0))
        // Should be busy, not heart
        #expect(ctrl.currentState == .busy)
    }

    @Test("idle variant cycles within manifest range")
    func idleVariantInRange() {
        let ctrl = CharacterController()
        // idleVariantCount = 9 for bufo
        ctrl.setIdleVariantCount(9)
        for _ in 0..<20 {
            ctrl.update(BuddyState(connected: true, sessionsTotal: 0))
            #expect(ctrl.currentIdleVariant >= 0)
            #expect(ctrl.currentIdleVariant < 9)
        }
    }

    @Test("dizzy can be triggered externally (shake equivalent)")
    func dizzyTriggeredExternally() {
        let ctrl = CharacterController()
        ctrl.update(BuddyState(connected: true))
        ctrl.triggerDizzy()
        #expect(ctrl.currentState == .dizzy)
    }
}
