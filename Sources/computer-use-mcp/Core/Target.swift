// Shared target resolution for interaction tools: app + element_id (from the
// latest snapshot) → live AXUIElement, re-resolved via its locator path.

import ApplicationServices
import Foundation
import MCP

struct ResolvedTarget {
    let app: ResolvedApp
    let snapshot: AppSnapshot
    let snapshotElement: SnapshotElement
    let element: AXUIElement
    /// Exact window used for lineage validation and live locator resolution.
    let window: TargetWindow
}

enum SnapshotIdentityRequirement: Equatable {
    /// Scoped/read-only perception may use legacy title/path resolution when
    /// strong identity is unavailable, but still rejects a positive conflict.
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

/// Resolve the exact captured window and require fully available, matching
/// lineage. Shared by element-id and coordinate mutation paths.
func resolveMutationWindow(snapshot: AppSnapshot, app: ResolvedApp) throws -> TargetWindow {
    guard let snapshotWindowID = snapshot.lineage?.windowID else {
        try enforceSnapshotIdentityDecision(
            .unavailable, requirement: .mutation,
            generation: snapshot.generation)
        preconditionFailure("mutation identity enforcement must throw when window id is unavailable")
    }
    let window = try targetWindow(for: app, snapshotWindowID: snapshotWindowID)
    try requireCompatibleSnapshotIdentity(
        snapshot: snapshot, app: app, window: window,
        requirement: .mutation)
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
        if let snapshotWindowID = snapshot.lineage?.windowID {
            window = try targetWindow(for: app, snapshotWindowID: snapshotWindowID)
        } else {
            window = try targetWindow(for: app, title: snapshot.windowTitle)
        }
        try requireCompatibleSnapshotIdentity(
            snapshot: snapshot, app: app, window: window,
            requirement: .bestEffort)
    }
    let element = try await resolveElement(snapshotElement, in: window.element)
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
