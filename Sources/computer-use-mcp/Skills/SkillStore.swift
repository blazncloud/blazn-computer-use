// Durable skill storage: one JSON file per skill under Application Support
// (skills are user data, not cache — they must survive cache cleaning).

import Foundation

enum SkillStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("computer-use-mcp/skills", isDirectory: true)
    }

    private static func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    static func save(_ skill: Skill) throws {
        try validateSkill(skill)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(skill).write(to: url(for: skill.name), options: .atomic)
    }

    static func load(_ name: String) throws -> Skill {
        guard let data = try? Data(contentsOf: url(for: name)) else {
            let available = list().map(\.name)
            throw ToolError.invalidArguments(
                "No skill named \"\(name)\"."
                    + (available.isEmpty
                        ? " No skills are saved yet — create one with save_skill."
                        : " Saved skills: \(available.joined(separator: ", "))."))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Skill.self, from: data)
        } catch {
            throw ToolError.failed("Skill \"\(name)\" could not be decoded (\(error)). Re-save it with save_skill.")
        }
    }

    static func list() -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Skill.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    static func delete(_ name: String) throws {
        let target = url(for: name)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolError.invalidArguments("No skill named \"\(name)\" to delete.")
        }
        try FileManager.default.removeItem(at: target)
    }
}
