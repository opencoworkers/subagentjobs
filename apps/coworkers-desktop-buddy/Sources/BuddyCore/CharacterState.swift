// CharacterState.swift — seven emotional states from the claude-desktop-buddy firmware.
// Maps BuddyState → the correct display state, mirroring src/main.cpp state machine.

import Foundation

public enum CharacterState: String, Sendable, Equatable, CaseIterable {
    /// Bridge not connected — eyes closed, slow breathing.
    case sleep
    /// Connected, nothing urgent — blinking, looking around.
    case idle
    /// Sessions actively running — sweating, working.
    case busy
    /// Approval pending — alert, urgent. ESP32 blinks LED.
    case attention
    /// Level up (every 50K tokens) — confetti, bouncing.
    case celebrate
    /// Shook the stick / external dizzy trigger — spiral eyes, wobbling.
    case dizzy
    /// Approved in under 5 seconds — floating hearts.
    case heart

    /// Derive the base character state from BuddyState.
    /// Does NOT handle celebrate/heart/dizzy — those are time-based transitions
    /// managed by `CharacterController`.
    public static func from(_ state: BuddyState) -> CharacterState {
        guard state.connected else { return .sleep }
        if state.sessionsWaiting > 0  { return .attention }
        if state.sessionsRunning > 0  { return .busy }
        return .idle
    }
}
