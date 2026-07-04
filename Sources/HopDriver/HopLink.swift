import Foundation

/// A single long-lived background thread running a RunLoop, where BLE L2CAP stream I/O and the
/// per-link keepalive/watchdog timers live, deliberately OFF the main runloop. The lab proved iOS 18+
/// silently drops CoreBluetooth stream/L2CAP callbacks scheduled on a busy main runloop, and main-
/// thread stream servicing starves the link under load. One shared thread serializes all L2CAP links.
///
/// The in-driver BLE/LAN transports (HopLink / LanLink) that used to live in this file were removed in
/// the app cutover: the shared HopBearerBle / HopBearerLan bearers own the transports now. This thread
/// stays because the driver still hands its runloop to HopBearerBle (`bleRunLoop = IOThread.shared.runLoop`)
/// so the shared BLE bearer schedules its L2CAP streams + timers on this SAME dedicated thread instead of
/// spinning up a second one.
final class IOThread {
    static let shared = IOThread()
    private var cfRunLoop: CFRunLoop!
    /// The Foundation `RunLoop` of the I/O thread, captured on that thread. Exposed so the shared
    /// HopBearerBle transport schedules its L2CAP streams + timers on this dedicated thread.
    private(set) var runLoop: RunLoop!

    private init() {
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            cfRunLoop = CFRunLoopGetCurrent()
            runLoop = RunLoop.current
            // A port keeps the runloop alive when it has no other input sources (else run() returns).
            RunLoop.current.add(NSMachPort(), forMode: .common)
            sem.signal()
            RunLoop.current.run()
        }
        thread.name = "hop.io"
        thread.qualityOfService = .userInitiated
        thread.start()
        sem.wait()   // block until the runloop is captured + alive
    }

    /// Run `block` on the I/O thread's runloop (in common modes, so it interleaves with stream events).
    /// Always async; never blocks the caller, safe to call from `hop.core`, `hop.ble`, or main.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(cfRunLoop)
    }
}
