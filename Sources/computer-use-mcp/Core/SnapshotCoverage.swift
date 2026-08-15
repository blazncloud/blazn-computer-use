import Foundation

/// How trustworthy a captured AX tree is as a statement about the whole
/// requested scope. This is separate from `scoped`: a scoped tree can be
/// complete for its requested subtree.
enum SnapshotCoverage: String, Codable, Equatable, Sendable {
    case complete
    /// Deliberately bounded by skeleton, collection, depth, or element limits.
    case partial
    /// One or more required AX reads failed, so elements may be missing.
    case degraded
    /// AX notifications showed that the UI changed during both capture attempts.
    case unstable

    var isComplete: Bool { self == .complete }

    static func combining(_ lhs: SnapshotCoverage, _ rhs: SnapshotCoverage) -> SnapshotCoverage {
        func rank(_ coverage: SnapshotCoverage) -> Int {
            switch coverage {
            case .complete: return 0
            case .partial: return 1
            case .degraded: return 2
            case .unstable: return 3
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}

/// Build once when no observer is available. When notifications race the
/// build, discard that mixed-time tree and retry exactly once. A second race
/// is returned as unstable instead of hiding it behind unbounded retries.
func buildTreeWithRevisionRetry(
    generation: String,
    revision: (() -> UInt64)?,
    build: (String) -> BuiltTree
) -> BuiltTree {
    guard let revision else { return build(generation) }

    let firstBefore = revision()
    let first = build(generation)
    guard revision() != firstBefore else { return first }

    let secondBefore = revision()
    let second = build(generation)
    guard revision() != secondBefore else { return second }

    return second.withCoverage(
        .unstable,
        note: "… accessibility coverage unstable: the UI changed during both capture attempts; "
            + "re-read app state before acting on absence."
    )
}

/// `unchanged == false` means only "not safely reusable" for incomplete
/// captures. It is affirmative change evidence only for complete captures.
func observedTreeChange(unchanged: Bool, coverage: SnapshotCoverage) -> Bool? {
    coverage.isComplete ? !unchanged : nil
}
