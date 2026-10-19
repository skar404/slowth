import Foundation
import Darwin

enum BlockingClock {
    static func clock() -> IOSPauseClock {
        #if PAUSE_COORDINATOR_TESTS
        return CoordinatorTestEnvironment.now
        #else
        var value = timeval(); var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let rc = sysctl(&mib, 2, &value, &size, nil, 0)
        return IOSPauseClock(wall: Date().timeIntervalSince1970,
            continuous: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
            boot: rc == 0 ? "\(value.tv_sec):\(value.tv_usec)" : UUID().uuidString)
        #endif
    }

    // CLOCK_MONOTONIC_RAW includes sleep. All processes prefer KERN_BOOTTIME
    // for boot identity, regardless of their access to kern.bootsessionuuid.
    static func restClock() -> IOSPauseClock {
        #if PAUSE_COORDINATOR_TESTS
        return CoordinatorTestEnvironment.now
        #else
        var bytes = [CChar](repeating: 0, count: 128)
        var size = bytes.count
        let rc = sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0)
        // iOS can deny kern.bootsessionuuid in an extension while allowing the
        // host to read it. Prefer KERN_BOOTTIME consistently in both processes.
        // If a wall-clock adjustment changes this fallback, restart safely;
        // never infer elapsed rest time from calendar time.
        var bootTime = timeval()
        var bootSize = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let bootRC = sysctl(&mib, 2, &bootTime, &bootSize, nil, 0)
        return IOSPauseClock(wall: Date().timeIntervalSince1970,
            continuous: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
            boot: IOSPauseClock.restBootIdentity(
                session: rc == 0 ? String(cString: bytes) : nil,
                bootTime: bootRC == 0 ? "\(bootTime.tv_sec):\(bootTime.tv_usec)" : nil))
        #endif
    }

}
