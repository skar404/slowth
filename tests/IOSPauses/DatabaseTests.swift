import Foundation
import SQLite3

@main enum DatabaseChecks {
    nonisolated static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected storage failure") } catch { }
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.sqlite")
        let database = IOSPauseDatabase(url: url)
        func check(_ value: @autoclosure () throws -> Bool) throws {
            let result = try value()
            precondition(result)
        }
        try check(database.read().pauseSeconds == 60)
        precondition(!FileManager.default.fileExists(atPath: url.path))
        try database.transaction { $0.revision = 120 }

        // A presentation read must see the last commit without competing for
        // the RESERVED writer lock or rewriting/encoding the ledger.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try! database.transaction {
                $0.revision = 180
                entered.signal()
                precondition(release.wait(timeout: .now() + 5) == .success)
            }
            done.signal()
        }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        try check(database.read().revision == 120)
        release.signal()
        precondition(done.wait(timeout: .now() + 5) == .success)
        try check(database.read().revision == 180)

        // A denied or already-expired assertion must not enter the edit closure.
        IOSPauseDatabase.beginHostAccess = { throw IOSPauseError.storage }
        rejects { try database.transaction { _ in fatalError("Denied access ran") } }
        rejects { _ = try database.read() }
        let early = IOSPauseDatabaseAccess()
        early.cancelAndWait() // Must return even before an access starts.
        IOSPauseDatabase.beginHostAccess = { early }
        rejects { try database.transaction { _ in fatalError("Expired access ran") } }

        // Expiration during a write waits for rollback/close; it must neither
        // publish the uncommitted edit nor release protection with a live lock.
        let access = IOSPauseDatabaseAccess()
        let expired = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        access.onFinish = {
            var connection: OpaquePointer?
            precondition(sqlite3_open(url.path, &connection) == SQLITE_OK)
            precondition(sqlite3_exec(connection, "BEGIN EXCLUSIVE; ROLLBACK", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(connection)
            closed.signal()
        }
        IOSPauseDatabase.beginHostAccess = { access }
        DispatchQueue.global().async {
            rejects {
                try database.transaction {
                    $0.revision = 240
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 5) == .success)
                }
            }
            done.signal()
        }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async { access.cancelAndWait(); expired.signal() }
        let deadline = Date().addingTimeInterval(3)
        while (try? access.check()) != nil {
            precondition(Date() < deadline)
            Thread.sleep(forTimeInterval: 0.001)
        }
        precondition(expired.wait(timeout: .now()) == .timedOut)
        release.signal()
        precondition(expired.wait(timeout: .now() + 5) == .success)
        precondition(done.wait(timeout: .now() + 5) == .success)
        precondition(closed.wait(timeout: .now() + 5) == .success)
        IOSPauseDatabase.beginHostAccess = nil
        try check(database.read().revision == 180)

        // Invalid persistent data must remain a failure, not an empty ledger.
        let corrupt = folder.appendingPathComponent("corrupt.sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        rejects { _ = try IOSPauseDatabase(url: corrupt).read() }
        print("PASS: read-only committed snapshots, denied/expired admission, rollback before background completion, corrupt storage")
    }
}
