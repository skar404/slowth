import Foundation

@main
struct RecordingReturnTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 1000)
        var gate = IOSApplicationReturn()
        func take(_ seconds: Double = 1, active: Bool = true, recording: Bool = true,
                  ready: Bool = true, evidence: Date? = nil, pause: String? = nil,
                  cleared: Bool = true) -> URL? {
            gate.take(now: start.addingTimeInterval(seconds), foreground: active,
                      recording: recording, ready: ready,
                      evidenceAt: evidence ?? start.addingTimeInterval(seconds),
                      pauseID: pause, shieldCleared: cleared)
        }
        assert(take() == nil)
        gate.arm(target: "unknown", recording: false, pauseID: nil, now: start)
        assert(take() == nil)
        gate.arm(target: "instagram", recording: false, pauseID: nil, now: start)
        assert(take(active: false) == nil)
        assert(take(recording: false) == nil)
        assert(take(ready: false) == nil)
        assert(take(evidence: start) == nil)
        assert(take(10, evidence: start.addingTimeInterval(1)) == nil)
        assert(take(cleared: false) == nil)
        assert(take()?.scheme == "instagram")
        assert(take() == nil)
        gate.arm(target: "youtube", recording: true, pauseID: "existing", now: start)
        assert(take(pause: "existing") == nil)
        assert(take(recording: false) == nil)
        assert(take()?.scheme == "youtube")
        gate.arm(target: "instagram", recording: false, pauseID: "existing", now: start)
        assert(take(recording: false, pause: "existing") == nil)
        assert(take(recording: false, pause: "new", cleared: false) == nil)
        assert(take(recording: false, ready: false, pause: "new") != nil)
        assert(take(pause: "new") == nil)
        gate.arm(target: "instagram", recording: false, pauseID: nil, now: start)
        gate.cancel()
        assert(take() == nil)
        gate.arm(target: "instagram", recording: false, pauseID: nil, now: start)
        assert(take(120) == nil)
        assert(take() == nil)
        print("Recording return tests passed")
    }
}
