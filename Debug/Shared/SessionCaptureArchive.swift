#if DEBUG
import Foundation

/// Host-owned sidecar: never race the ReplayKit writer's session.json replacement.
/// Names are display metadata, never filesystem paths or recording identifiers.
enum SessionCaptureName {
    static let filename = "session-name.json"

    private struct Metadata: Codable {
        let displayName: String
    }

    static func load(from directory: URL) throws -> String? {
        let url = directory.appendingPathComponent(filename)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(Metadata.self, from: data).displayName
    }

    enum NameError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "Enter a name of 1–120 characters without line breaks or control characters."
        }
    }

    static func normalized(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw NameError.invalid
        }
        return name
    }

    static func rename(in directory: URL, to name: String) throws {
        let name = try normalized(name)
        // Require an existing recording; never create or rename its storage folder.
        _ = try JSONDecoder().decode(SessionCapture.Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        try JSONEncoder().encode(Metadata(displayName: name))
            .write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}

/// Foundation creates a temporary ZIP for a directory with .forUploading.
/// Copy it inside the accessor: the coordinated URL expires when it returns.
enum SessionCaptureArchive {
    static func export(_ directory: URL, to destination: URL,
                       inspectSnapshot: ((URL) throws -> Void)? = nil) throws -> URL {
        let manager = FileManager.default
        let data = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self, from: data)
        let snapshot = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: snapshot) }
        // JPEGs are immutable and committed before the atomically replaced manifest.
        // Snapshot only its inventory, so even interrupted/live sessions are coherent.
        for frame in manifest.frames {
            guard frame.filename == URL(fileURLWithPath: frame.filename).lastPathComponent,
                  frame.filename.hasPrefix("frame_"), frame.filename.hasSuffix(".jpg") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try manager.copyItem(at: directory.appendingPathComponent(frame.filename),
                                 to: snapshot.appendingPathComponent(frame.filename))
        }
        try data.write(to: snapshot.appendingPathComponent("session.json"), options: .atomic)
        if let name = try SessionCaptureName.load(from: directory) {
            try SessionCaptureName.rename(in: snapshot, to: name)
        }
        try inspectSnapshot?(snapshot)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        coordinator.coordinate(readingItemAt: snapshot, options: .forUploading,
                               error: &coordinationError) { archive in
            result = Result {
                try FileManager.default.copyItem(at: archive, to: destination)
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
#endif
