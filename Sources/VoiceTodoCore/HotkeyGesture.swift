import Foundation

/// One physical key press. A quick tap is intentional input, not a discarded hold.
public struct HotkeyGesture {
    public enum State: Equatable { case idle, waiting, holding, blocked }
    public enum Effect: Equatable { case none, armHold, tap, startHold, latchRecording, endHold, cancelHold }
    public private(set) var state: State = .idle
    public init() {}
    public mutating func press(hasOtherKeys: Bool) -> Effect {
        guard state == .idle else { return .none }
        state = hasOtherKeys ? .blocked : .waiting
        return hasOtherKeys ? .none : .armHold
    }
    public mutating func holdThreshold() -> Effect {
        guard state == .waiting else { return .none }
        state = .holding; return .startHold
    }
    public mutating func release(heldFor duration: TimeInterval = 1) -> Effect {
        let previous = state; state = .idle
        switch previous {
        case .waiting: return .tap
        // Feedback begins at 120 ms, but an ordinary tap may last longer than that.
        case .holding: return duration < 0.35 ? .latchRecording : .endHold
        default: return .none
        }
    }
    public mutating func combine() -> Effect {
        guard state != .idle else { return .none }
        let wasHolding = state == .holding; state = .blocked
        return wasHolding ? .cancelHold : .none
    }
    public mutating func reset() -> Effect {
        let wasHolding = state == .holding; state = .idle
        return wasHolding ? .cancelHold : .none
    }
}
