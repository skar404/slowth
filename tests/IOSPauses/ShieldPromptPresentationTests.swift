import Foundation

@main
struct ShieldPromptPresentationTests {
    static func main() {
        var prompt = IOSShieldPromptPresentation()
        var stored = true
        var reads = 0
        func consume(_ target: inout String?) -> Bool {
            reads += 1
            guard stored else { return false }
            stored = false
            target = "youtube"
            return true
        }
        func take(_ active: Bool = true, _ idle: Bool = true, _ rests: [IOSDetectionRest]? = []) -> IOSShieldPromptPresentation.Destination? {
            prompt.take(isActive: active, isIdle: idle, rests: rests, isPauseOnly: { $0 == "tiktok" })
        }
        assert(!prompt.receive(isActive: false, consume: consume))
        assert(stored && reads == 0) // onAppear during a cold launch.
        assert(prompt.receive(isActive: true, consume: consume))
        assert(take(false) == nil && prompt.isPending)
        assert(!prompt.receive(isActive: true, consume: consume))
        assert(take(true, false) == nil && prompt.isPending) // Alert/authorization in progress.
        prompt.beginDismissal()
        assert(take() == nil && prompt.isPending) // Binding is false, animation still running.
        prompt.finishDismissal()
        assert(take(true, true, nil) == nil && prompt.isPending) // Storage read failed.
        guard case .recording("youtube") = take() else { fatalError("Lost target during activation/dismissal") }
        assert(!prompt.isPending && take() == nil)
        assert(!prompt.receive(isActive: true, consume: consume))
        assert(take() == nil) // Foreground/timer must not reopen a dismissed prompt.
        stored = true
        assert(prompt.receive(isActive: true, consume: consume))
        guard case .recording("youtube") = take() else { fatalError("Explicit repeat must reopen") }
        prompt.enqueue(target: "tiktok")
        guard case .pause("tiktok") = take() else { fatalError("Pause-only route") }
        prompt.enqueue(target: nil)
        guard case .recording(nil) = take() else { fatalError("Unknown target must show choice") }

        let youtube = IOSDetectionRest(target: "youtube")
        let tiktok = IOSDetectionRest(target: "tiktok")
        prompt.enqueue(target: "tiktok")
        guard case .rest(let selected) = take(true, true, [youtube, tiktok]) else { fatalError("Rest takes precedence") }
        assert(selected.id == tiktok.id)
        var presentation = IOSRestPresentation()
        assert(presentation.shouldPresent(selected)) // Scheduling is not appearance.
        presentation.acknowledge(selected)
        assert(!presentation.shouldPresent(selected))
        prompt.enqueue(target: "youtube")
        assert(take(true, false, [youtube]) == nil)
        guard case .recording("youtube") = take() else { fatalError("Expired rest must not be revived") }
        prompt.enqueue(target: "tiktok")
        guard case .pause("tiktok") = take() else { fatalError("Expired pause-only rest") }
        prompt.enqueue(target: "youtube")
        prompt.beginDismissal()
        prompt.enqueue(target: "tiktok") // Latest explicit request wins while waiting.
        prompt.finishDismissal()
        guard case .pause("tiktok") = take() else { fatalError("Repeated request lost its target") }
        assert(take() == nil)
        print("Shield prompt presentation tests passed")
    }
}
