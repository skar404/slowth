#if DEBUG
import Foundation

struct DebugTransferFile: Codable, Equatable, Sendable {
    let name: String
    let size: Int64
    let sha256: String
    let md5: String
    let contentType: String
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 150 && name != "." && name != ".." &&
        name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && name != "COMPLETE.json"
    }
}
struct DebugTransferInventory: Codable, Equatable, Sendable {
    let version: Int
    let kind: String
    let sessionID: UUID
    let files: [DebugTransferFile]
}
struct DebugTransferSnapshot: Codable, Equatable, Sendable {
    let id: String
    let inventory: DebugTransferInventory
    var objectPrefix: String { "\(inventory.kind)/\(inventory.sessionID.uuidString.lowercased())/\(id)" }
    var bytes: Int64 { inventory.files.reduce(0) { $0 + $1.size } }

    enum Source: Sendable {
        case screenshots(URL, UUID)
        case motion(UUID, [String: Data])
        case motionFiles(UUID, [String: Data], [URL])
    }
    static func prepare(_ source: Source, root: URL) throws -> Self {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let kind: String; let id: UUID
        switch source {
        case .screenshots(let directory, let sessionID):
            kind = "screenshots"; id = sessionID
            try SessionCaptureArchive.copySnapshot(directory, to: temporary)
            let manifest = try JSONDecoder().decode(SessionCapture.Manifest.self,
                from: Data(contentsOf: temporary.appendingPathComponent("session.json")))
            guard manifest.sessionID == id, !manifest.frames.isEmpty else { throw DebugTransferError.invalidSnapshot }
        case .motion(let sessionID, let files):
            kind = "motion"; id = sessionID
            guard Set(files.keys) == Set(["session.json", "samples.json", "motion.csv"]),
                  files.values.allSatisfy({ !$0.isEmpty }) else { throw DebugTransferError.invalidSnapshot }
            for (name, data) in files { try data.write(to: temporary.appendingPathComponent(name), options: .atomic) }
        case .motionFiles(let sessionID, let metadata, let videos):
            kind = "motion"; id = sessionID
            guard Set(["session.json", "samples.json", "motion.csv", "edits.json"]).isSubset(of: Set(metadata.keys)),
                  Set(metadata.keys).isSubset(of: Set(["session.json", "samples.json", "motion.csv", "edits.json", "video.json"])) else {
                throw DebugTransferError.invalidSnapshot
            }
            for (name, data) in metadata { try data.write(to: temporary.appendingPathComponent(name), options: .atomic) }
            for url in videos {
                try Task.checkCancellation()
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      DebugTransferFile.validName(url.lastPathComponent), ["mov", "mp4"].contains(url.pathExtension) else {
                    throw DebugTransferError.invalidSnapshot
                }
                // FileManager copies/clones files without materializing a video in Data.
                try manager.copyItem(at: url, to: temporary.appendingPathComponent(url.lastPathComponent))
            }
        }
        var files: [DebugTransferFile] = []
        for file in try manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let props = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard props.isRegularFile == true, props.isSymbolicLink != true, DebugTransferFile.validName(file.lastPathComponent) else {
                throw DebugTransferError.invalidSnapshot
            }
            let hash = try DebugTransferDigest.file(file)
            let type: String
            switch file.pathExtension {
            case "png": type = "image/png"
            case "jpg": type = "image/jpeg"
            case "json": type = "application/json"
            case "csv": type = "text/csv"
            case "mov": type = "video/quicktime"
            case "mp4": type = "video/mp4"
            default: throw DebugTransferError.invalidSnapshot
            }
            files.append(.init(name: file.lastPathComponent, size: hash.size, sha256: hash.sha256, md5: hash.md5, contentType: type))
        }
        let inventory = DebugTransferInventory(version: 1, kind: kind, sessionID: id, files: files)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(inventory)
        let snapshot = Self(id: DebugTransferDigest.hex(data), inventory: inventory)
        try data.write(to: temporary.appendingPathComponent("COMPLETE.json"), options: .atomic)
        let final = root.appendingPathComponent(snapshot.id, isDirectory: true)
        if !manager.fileExists(atPath: final.path) { try manager.moveItem(at: temporary, to: final) }
        else { try snapshot.validate(at: final) }
        return snapshot
    }
    func validate(at directory: URL) throws {
        guard id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              inventory.version == 1, ["motion", "screenshots"].contains(inventory.kind),
              !inventory.files.isEmpty, Set(inventory.files.map(\.name)).count == inventory.files.count else {
            throw DebugTransferError.invalidSnapshot
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("COMPLETE.json"))
        guard DebugTransferDigest.hex(data) == id,
              try JSONDecoder().decode(DebugTransferInventory.self, from: data) == inventory else { throw DebugTransferError.invalidSnapshot }
        for file in inventory.files {
            guard DebugTransferFile.validName(file.name), file.size >= 0, file.size <= 5 * 1024 * 1024 * 1024 else {
                throw DebugTransferError.invalidSnapshot
            }
            let path = directory.appendingPathComponent(file.name)
            let props = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard props.isRegularFile == true, props.isSymbolicLink != true else { throw DebugTransferError.invalidSnapshot }
            let digest = try DebugTransferDigest.file(path)
            guard digest.sha256 == file.sha256, digest.md5 == file.md5, digest.size == file.size else { throw DebugTransferError.invalidSnapshot }
        }
    }
}
#endif
