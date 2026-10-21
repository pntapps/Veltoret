import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while it serves a video to the TV (Android: Wi-Fi lock + partial wake lock,
/// Windows: SetThreadExecutionState). An IOPM assertion, released after 6 hours at the latest (Android's cap).
public final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0
    private var held = false
    private var activity: NSObjectProtocol?

    public init() {}

    public var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }

    public func acquire() {
        lock.lock(); defer { lock.unlock() }
        if held { return }
        var id: IOPMAssertionID = 0
        let reason = "Veltoret is streaming a video to a TV" as CFString
        if IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, reason, nil, nil, nil,
                                              6 * 3600, kIOPMAssertionTimeoutActionRelease as CFString, &id) == kIOReturnSuccess {
            assertion = id
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Streaming a video to a TV")
        held = true
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        if !held { return }
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        held = false
    }

    deinit { release() }
}
