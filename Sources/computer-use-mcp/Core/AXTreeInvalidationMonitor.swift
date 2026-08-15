@preconcurrency import ApplicationServices
@preconcurrency import CoreFoundation
import Foundation

private final class AXRevisionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

private final class AXObserverRunLoopState: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?

    func install(_ runLoop: CFRunLoop) {
        lock.lock()
        self.runLoop = runLoop
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let current = runLoop
        lock.unlock()
        if let current { CFRunLoopStop(current) }
    }
}

/// Notification-backed dirty counter for one app/window capture session.
/// Notifications are only wake/race hints; every result still comes from an
/// authoritative AX reread.
final class AXTreeInvalidationMonitor: @unchecked Sendable {
    private let counter: AXRevisionCounter
    private let observer: AXObserver
    private let runLoopState: AXObserverRunLoopState
    private let thread: Thread
    private let registrations: [(AXUIElement, String)]
    private let callbackRefcon: UnsafeMutableRawPointer
    private let threadFinished: DispatchSemaphore

    var revision: UInt64 { counter.revision }

    init?(pid: pid_t, application: AXUIElement, window: AXUIElement) {
        let counter = AXRevisionCounter()
        var createdObserver: AXObserver?
        let createError = AXObserverCreate(
            pid,
            { _, _, _, refcon in
                guard let refcon else { return }
                Unmanaged<AXRevisionCounter>.fromOpaque(refcon).takeUnretainedValue().increment()
            },
            &createdObserver)
        guard createError == .success, let observer = createdObserver else { return nil }

        let appNotifications = [
            "AXFocusedUIElementChanged", "AXFocusedWindowChanged",
            "AXMainWindowChanged", "AXWindowCreated",
        ]
        let windowNotifications = [
            "AXUIElementDestroyed", "AXMoved", "AXResized", "AXLayoutChanged",
            "AXValueChanged", "AXSelectedChildrenChanged", "AXSelectedRowsChanged",
            "AXRowCountChanged",
        ]
        var registrations: [(AXUIElement, String)] = []
        // The callback refcon owns its counter independently until the run-loop
        // thread has stopped, so a queued callback cannot outlive its target.
        let refcon = Unmanaged.passRetained(counter).toOpaque()
        for (element, notifications) in [
            (application, appNotifications), (window, windowNotifications),
        ] {
            for notification in notifications {
                if AXObserverAddNotification(
                    observer, element, notification as CFString, refcon) == .success
                {
                    registrations.append((element, notification))
                }
            }
        }
        guard !registrations.isEmpty else {
            Unmanaged<AXRevisionCounter>.fromOpaque(refcon).release()
            return nil
        }

        let source = AXObserverGetRunLoopSource(observer)
        let state = AXObserverRunLoopState()
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                finished.signal()
                return
            }
            state.install(runLoop)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            finished.signal()
        }
        thread.name = "computer-use-mcp.ax-observer"
        thread.start()
        ready.wait()

        self.counter = counter
        self.observer = observer
        self.runLoopState = state
        self.thread = thread
        self.registrations = registrations
        self.callbackRefcon = refcon
        self.threadFinished = finished
    }

    deinit {
        for (element, notification) in registrations {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
        runLoopState.stop()
        threadFinished.wait()
        Unmanaged<AXRevisionCounter>.fromOpaque(callbackRefcon).release()
        _ = thread
    }
}
