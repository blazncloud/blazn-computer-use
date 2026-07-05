import Foundation

// Single source of truth for the binary version.
let version = "0.4.1"

/// Modification time (epoch seconds) of the running executable, sent in the
/// daemon handshake so a rebuilt binary retires a daemon running older code
/// even when the semantic version did not change. "Newest build wins": an
/// older shim never retires a newer daemon, so mixed debug/release binaries
/// on one machine converge instead of thrashing.
let executableBuildStamp: Double = {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
}()
