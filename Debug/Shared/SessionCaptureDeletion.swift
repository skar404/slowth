#if DEBUG
import Foundation

enum SessionCaptureDeletion {
    struct Failure {
        let directory: URL
        let message: String
    }

    struct Result {
        var deleted: Set<URL> = []
        var failures: [Failure] = []
    }

    /// Attempts every selected session, retaining failures for display and retry.
    static func remove(_ directories: [URL]) -> Result {
        var result = Result()
        for directory in directories {
            do {
                try FileManager.default.removeItem(at: directory)
                result.deleted.insert(directory)
            } catch {
                result.failures.append(Failure(directory: directory, message: error.localizedDescription))
            }
        }
        return result
    }
}
#endif
