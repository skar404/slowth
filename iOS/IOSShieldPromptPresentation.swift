import Foundation

/// In-memory handoff only; the shared request stays untouched until activation.
struct IOSShieldPromptPresentation {
    enum Destination {
        case rest(IOSDetectionRest)
        case pause(String)
        case recording(String?)
    }
    private struct Request { let target: String? }
    private var request: Request?
    private(set) var waitingForDismissal = false
    var isPending: Bool { request != nil }

    mutating func enqueue(target: String?) { request = Request(target: target) }

    mutating func receive(isActive: Bool, consume: (inout String?) -> Bool) -> Bool {
        guard isActive else { return false }
        var target: String?
        guard consume(&target) else { return false }
        enqueue(target: target)
        return true
    }

    mutating func beginDismissal() { waitingForDismissal = true }
    mutating func finishDismissal() { waitingForDismissal = false }

    mutating func take(isActive: Bool, isIdle: Bool, rests: [IOSDetectionRest]?,
                       isPauseOnly: (String) -> Bool) -> Destination? {
        // A failed refresh must not lose the request or choose from stale state.
        guard isActive, isIdle, !waitingForDismissal, let request, let rests else { return nil }
        self.request = nil
        if let target = request.target, let rest = rests.first(where: { $0.target == target }) {
            return .rest(rest)
        }
        if let target = request.target, isPauseOnly(target) { return .pause(target) }
        return .recording(request.target)
    }
}
