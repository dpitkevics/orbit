import Foundation

/// Protocol for persisting and retrieving sessions.
public protocol SessionStore: Sendable {
    func save(_ session: Session, project: String) throws
    func load(id: String, project: String) throws -> Session
    func list(project: String, limit: Int) throws -> [SessionSummary]
    func delete(id: String, project: String) throws
}

/// File-backed session store at ~/.orbit/sessions/{project}/{id}.json.
public struct FileSessionStore: SessionStore, Sendable {
    private let baseDir: URL

    public init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? ConfigLoader.orbitHome.appendingPathComponent("sessions")
    }

    public func save(_ session: Session, project: String) throws {
        let dir = projectDir(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("\(session.sessionID).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(session)
        try data.write(to: path)
    }

    public func load(id: String, project: String) throws -> Session {
        let path = projectDir(project).appendingPathComponent("\(id).json")

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw SessionStoreError.notFound(id: id, project: project)
        }

        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Session.self, from: data)
    }

    public func list(project: String, limit: Int) throws -> [SessionSummary] {
        let dir = projectDir(project)

        guard FileManager.default.fileExists(atPath: dir.path) else {
            return []
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
            .sorted(by: >) // newest first by filename (UUID-based, so roughly chronological)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        var summaries: [SessionSummary] = []
        for file in files.prefix(limit) {
            let path = dir.appendingPathComponent(file)
            if let data = try? Data(contentsOf: path),
               let session = try? decoder.decode(Session.self, from: data) {
                summaries.append(SessionSummary(from: session))
            }
        }

        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(id: String, project: String) throws {
        let path = projectDir(project).appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private func projectDir(_ project: String) -> URL {
        baseDir.appendingPathComponent(project)
    }
}

public enum SessionStoreError: Error, LocalizedError {
    case notFound(id: String, project: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id, let project):
            return "Session '\(id)' not found in project '\(project)'."
        }
    }
}
