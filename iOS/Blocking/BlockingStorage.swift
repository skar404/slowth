import Foundation

enum BlockingStorage {
    static func database() throws -> IOSPauseDatabase {
        #if PAUSE_COORDINATOR_TESTS
        return IOSPauseDatabase(url: CoordinatorTestEnvironment.databaseURL)
        #else
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { throw IOSPauseError.storage }
        let folder = root.appendingPathComponent("TemporaryPauses", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return IOSPauseDatabase(url: folder.appendingPathComponent("state.sqlite"))
        #endif
    }

}
