// Shared target resolution: app + element_id → the exact retained AX handle,
// validated against its captured process, window, and semantic facts.

import ApplicationServices
import Foundation
import MCP

struct ResolvedTarget {
    let app: ResolvedApp
    let snapshot: AppSnapshot
    let snapshotElement: CapturedNode
    let element: AXUIElement
    /// Exact retained window used for lineage and attachment validation.
    let window: TargetWindow
}

enum SnapshotIdentityRequirement: Equatable {
    /// Scoped/read-only perception may tolerate unavailable CG window identity.
    case bestEffort
    /// Mutations require a fresh snapshot with fully available strong process
    /// and window identity.
    case mutation
}

/// Central identity policy shared by the concrete target resolvers and pure
/// deterministic tests.
func enforceSnapshotIdentityDecision(
    _ decision: SnapshotLineageDecision,
    requirement: SnapshotIdentityRequirement,
    generation: String
) throws {
    switch decision {
    case .compatible:
        return
    case .unavailable where requirement == .bestEffort:
        return
    case .unavailable:
        throw ToolError.failed(
            "Element ids from snapshot \(generation) cannot be used for mutation because "
                + "strong process/window identity is unavailable. Call get_app_state and "
                + "use an id from the fresh state.")
    case .conflict(let reason):
        throw ToolError.failed(
            "Element ids from snapshot \(generation) are stale: \(reason). "
                + "Call get_app_state and use an id from the current app window.")
    }
}

/// Resolve and enforce the current process/window lineage under one explicit
/// policy; strong conflicts never fall through to title/path heuristics.
func requireCompatibleSnapshotIdentity(
    snapshot: AppSnapshot, app: ResolvedApp, window: TargetWindow,
    requirement: SnapshotIdentityRequirement
) throws {
    let current = SnapshotLineage(
        process: snapshotProcessIdentity(pid: app.pid, bundleIdentifier: app.bundleIdentifier),
        windowID: window.lineageWindowID)
    try enforceSnapshotIdentityDecision(
        compareSnapshotLineage(persisted: snapshot.lineage, current: current),
        requirement: requirement, generation: snapshot.generation)
}

func resolveTarget(app: ResolvedApp, elementID: String) async throws -> ResolvedTarget {
    try await resolveTarget(
        app: app, elementID: elementID, identityRequirement: .bestEffort)
}

/// Mutation-specific entry point. Tool handlers that can change app state must
/// use this instead of the best-effort read-only resolver.
func resolveMutationTarget(app: ResolvedApp, elementID: String) async throws -> ResolvedTarget {
    try await resolveTarget(
        app: app, elementID: elementID, identityRequirement: .mutation)
}

func containsAXElement(_ expected: AXUIElement, in elements: [AXUIElement]) -> Bool {
    elements.contains { CFEqual($0, expected) }
}

/// Validate the exact retained window and require fully available, matching
/// lineage. Shared by element-id and coordinate mutation paths.
func resolveMutationWindow(snapshot: AppSnapshot, app: ResolvedApp) throws -> TargetWindow {
    try resolveRetainedWindow(snapshot: snapshot, app: app, requirement: .mutation)
}

private func resolveRetainedWindow(
    snapshot: AppSnapshot, app: ResolvedApp,
    requirement: SnapshotIdentityRequirement
) throws -> TargetWindow {
    guard let windowElement = snapshot.windowElement else {
        throw ToolError.failed(
            "Snapshot \(snapshot.generation) has no live AX window handle. Call get_app_state "
                + "in the current daemon before mutating the app.")
    }
    var ownerPID = pid_t(0)
    let pidError = AXUIElementGetPid(windowElement, &ownerPID)
    guard pidError == .success, ownerPID == app.pid else {
        throw ToolError.failed(
            "Snapshot \(snapshot.generation) is stale: its AX window no longer belongs to "
                + "\(app.name). Call get_app_state and use a fresh element id.")
    }
    guard case .value(let rawRole) = axReadAttribute(windowElement, kAXRoleAttribute),
        rawRole as? String == "AXWindow"
    else {
        throw ToolError.failed(
            "Snapshot \(snapshot.generation) is stale: its AX window is no longer valid. "
                + "Call get_app_state and use a fresh element id.")
    }
    switch axReadElements(app.axApplication, kAXWindowsAttribute) {
    case .value(let currentWindows):
        guard containsAXElement(windowElement, in: currentWindows) else {
            throw ToolError.failed(
                "Snapshot \(snapshot.generation) is stale: its AX window is no longer attached "
                    + "to \(app.name). Call get_app_state and use a fresh element id.")
        }
    case .failure(let failure):
        throw ToolError.failed(
            "Could not prove that snapshot \(snapshot.generation)'s AX window is still attached "
                + "to \(app.name): \(describeAXReadFailure(failure)).")
    }
    let snapshotWindowID = snapshot.lineage?.windowID
    let currentWindowID = windowID(for: windowElement)
    if let snapshotWindowID, let currentWindowID, currentWindowID != snapshotWindowID {
        try enforceSnapshotIdentityDecision(
            .conflict("the target window was replaced"), requirement: requirement,
            generation: snapshot.generation)
        preconditionFailure("identity enforcement must throw on a window conflict")
    }
    guard let frame = axFrame(windowElement) else {
        throw ToolError.failed("Could not read the captured window frame for \(app.name).")
    }
    let window = TargetWindow(
        element: windowElement,
        title: axString(windowElement, kAXTitleAttribute),
        frame: frame, identityWindowID: currentWindowID)
    try requireCompatibleSnapshotIdentity(
        snapshot: snapshot, app: app, window: window,
        requirement: requirement)
    return window
}

private func resolveTarget(
    app: ResolvedApp, elementID: String,
    identityRequirement: SnapshotIdentityRequirement
) async throws -> ResolvedTarget {
    guard let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: app.pid, elementID: elementID) else {
        guard let latest = await SnapshotStore.shared.load(forPid: app.pid) else {
            throw ToolError.failed(
                "No app state captured for \(app.name) yet. Call get_app_state first, "
                    + "then use the element ids it returns."
            )
        }
        if let atIndex = elementID.firstIndex(of: "@"),
            String(elementID[elementID.index(after: atIndex)...]) != latest.generation
        {
            throw ToolError.invalidArguments(
                "\"\(elementID)\" is from an older app state and did not survive the UI "
                    + "change (the current state is \(latest.generation)). Use element ids "
                    + "from the most recent result, or call get_app_state."
            )
        }
        throw ToolError.invalidArguments(
            "\"\(elementID)\" is not an element id from the latest \(app.name) state. "
                + "Call get_app_state and use a fresh id (e.g. \"e12@\(latest.generation)\")."
        )
    }
    let snapshot = resolved.snapshot
    let snapshotElement = resolved.element
    let window: TargetWindow
    switch identityRequirement {
    case .mutation:
        window = try resolveMutationWindow(snapshot: snapshot, app: app)
    case .bestEffort:
        if snapshot.windowElement != nil {
            window = try resolveRetainedWindow(
                snapshot: snapshot, app: app, requirement: .bestEffort)
        } else if let snapshotWindowID = snapshot.lineage?.windowID {
            window = try targetWindow(for: app, snapshotWindowID: snapshotWindowID)
        } else {
            window = try targetWindow(for: app, title: snapshot.windowTitle)
        }
        try requireCompatibleSnapshotIdentity(
            snapshot: snapshot, app: app, window: window,
            requirement: .bestEffort)
    }
    let element = try await resolveElement(snapshotElement, in: window.element)
    var elementPID = pid_t(0)
    let elementPIDError = AXUIElementGetPid(element, &elementPID)
    guard elementPIDError == .success, elementPID == app.pid else {
        throw ToolError.failed(
            "Element \(snapshotElement.id) is stale: its AX handle no longer belongs to "
                + "\(app.name). Call get_app_state and use a fresh element id.")
    }
    return ResolvedTarget(
        app: app, snapshot: snapshot, snapshotElement: snapshotElement,
        element: element, window: window)
}

func performAXAction(_ action: String, on target: ResolvedTarget) throws {
    let error = try performAXActionPrimitive {
        AXUIElementPerformAction(target.element, action as CFString)
    }
    guard error == .success else {
        throw ToolError.failed(
            "\(action) failed on \(describeTarget(target)) (\(axErrorDescription(error)))."
        )
    }
}

func performAXActionPrimitive(_ primitive: () -> AXError) throws -> AXError {
    try checkCancellationBeforeDelivery()
    return primitive()
}

func describeTarget(_ target: ResolvedTarget) -> String {
    let label = target.snapshotElement.label.map { " \"\($0)\"" } ?? ""
    return "\(target.snapshotElement.id) (\(target.snapshotElement.role)\(label))"
}
