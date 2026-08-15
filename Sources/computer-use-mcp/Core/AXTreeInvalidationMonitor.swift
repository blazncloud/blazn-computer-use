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

/// Shared AX notification plumbing. Notifications only wake readers; callers
/// must reread authoritative AX attributes before deciding that anything
/// happened.
private final class AXNotificationMonitor: @unchecked Sendable {
    private let counter: AXRevisionCounter
    private let observer: AXObserver
    private let runLoopState: AXObserverRunLoopState
    private let thread: Thread
    private let registrations: [(AXUIElement, String)]
    private let callbackRefcon: UnsafeMutableRawPointer
    private let threadFinished: DispatchSemaphore

    var revision: UInt64 { counter.revision }

    init?(pid: pid_t, requestedRegistrations: [(AXUIElement, [String])]) {
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

        var registrations: [(AXUIElement, String)] = []
        let refcon = Unmanaged.passRetained(counter).toOpaque()
        for (element, notifications) in requestedRegistrations {
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
    private let monitor: AXNotificationMonitor

    var revision: UInt64 { monitor.revision }

    init?(pid: pid_t, application: AXUIElement, window: AXUIElement) {
        let appNotifications = [
            "AXFocusedUIElementChanged", "AXFocusedWindowChanged",
            "AXMainWindowChanged", "AXWindowCreated",
        ]
        let windowNotifications = [
            "AXUIElementDestroyed", "AXMoved", "AXResized", "AXLayoutChanged",
            "AXValueChanged", "AXSelectedChildrenChanged", "AXSelectedRowsChanged",
            "AXRowCountChanged",
        ]
        guard let monitor = AXNotificationMonitor(
            pid: pid,
            requestedRegistrations: [
                (application, appNotifications), (window, windowNotifications),
            ])
        else { return nil }
        self.monitor = monitor
    }
}

/// Short-lived notification source for one mutation. It is installed before
/// dispatch and removed after verification. The counter is a wake signal only.
protocol DeliveryChangeObserving: Sendable {
    var revision: UInt64 { get }
    func waitForChange(after baseline: UInt64, timeout: Duration) async -> Bool
}

final class AXDeliveryObserver: DeliveryChangeObserving, @unchecked Sendable {
    private let monitor: AXNotificationMonitor

    var revision: UInt64 { monitor.revision }

    init?(
        pid: pid_t, application: AXUIElement, window: AXUIElement,
        target: AXUIElement?, family: ActionFamily
    ) {
        var registrations: [(AXUIElement, [String])] = []
        switch family {
        case .click, .type:
            registrations.append((application, [
                "AXFocusedUIElementChanged", "AXFocusedWindowChanged",
            ]))
        case .setValue, .scroll, .window, .menu, .secondaryAction, .drag:
            break
        }
        registrations.append((window, [
            "AXUIElementDestroyed", "AXLayoutChanged", "AXMoved", "AXResized",
        ]))
        if let target {
            let targetNotifications: [String]
            switch family {
            case .type:
                targetNotifications = [
                    "AXUIElementDestroyed", "AXValueChanged", "AXSelectedTextChanged",
                ]
            case .click, .setValue:
                targetNotifications = ["AXUIElementDestroyed", "AXValueChanged"]
            case .scroll:
                targetNotifications = [
                    "AXUIElementDestroyed", "AXValueChanged", "AXLayoutChanged",
                    "AXSelectedRowsChanged", "AXRowCountChanged",
                ]
            case .window, .menu, .secondaryAction, .drag:
                targetNotifications = ["AXUIElementDestroyed", "AXValueChanged"]
            }
            registrations.append((target, targetNotifications))
        }
        guard let monitor = AXNotificationMonitor(
            pid: pid, requestedRegistrations: registrations)
        else { return nil }
        self.monitor = monitor
    }

    /// Wait until a notification advances the counter or the bounded timeout
    /// expires. Polling only the in-process counter avoids blocking Swift's
    /// cooperative executor; AX state itself is not polled here.
    func waitForChange(after baseline: UInt64, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if revision != baseline { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return revision != baseline
    }
}
