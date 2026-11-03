#if os(iOS) || PAUSE_TESTS
import Foundation
import SQLite3

/// One access owns its connection until it has closed, including on expiration.
/// Never dispatch synchronously to the main thread while an access is in flight:
/// the host expiration handler may be waiting there for SQLite to release locks.
final class IOSPauseDatabaseAccess: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var started = false
    private var finished = false
    private var connection: OpaquePointer?
    var onFinish: () -> Void = {}

    func start() throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw IOSPauseError.storage }
        started = true
    }

    func check() throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw IOSPauseError.storage }
    }

    func attach(_ db: OpaquePointer) throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw IOSPauseError.storage }
        connection = db
    }

    func close(_ db: OpaquePointer) {
        condition.lock(); defer { condition.unlock() }
        sqlite3_close(db)
        connection = nil
    }

    func cancelAndWait() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true
        if let connection { sqlite3_interrupt(connection) }
        // Expiration can arrive while UIKit is still granting the assertion.
        // Reject a subsequent start rather than waiting for it to happen.
        while started && !finished { condition.wait() }
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
        onFinish()
    }
}

/// A single SQLite row and BEGIN IMMEDIATE coordinate all extension processes.
/// OS writes inside a transaction still aren't atomic with SQLite; on crash,
/// the durable active/ending intent is reconciled again. No fallback defaults.
final class IOSPauseDatabase {
    // Installed once by the iOS host before creating its views. Extensions do
    // not use UIApplication and retain their existing execution lifetime.
    static var beginHostAccess: (() throws -> IOSPauseDatabaseAccess)?
    let url: URL
    init(url: URL) { self.url = url }

    func transaction<T>(_ edit: (inout IOSPauseLedger) throws -> T) throws -> T {
        let access = try Self.beginHostAccess?() ?? IOSPauseDatabaseAccess()
        defer { access.finish() }
        try access.start()
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }; throw IOSPauseError.storage
        }
        defer { access.close(db) }
        try access.attach(db)
        sqlite3_busy_timeout(db, 2000)
        func execute(_ sql: String) throws {
            try access.check()
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IOSPauseError.storage }
        }
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), value BLOB NOT NULL)")
        try execute("BEGIN IMMEDIATE")
        do {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE id=1", -1, &query, nil) == SQLITE_OK else { throw IOSPauseError.storage }
            var ledger = IOSPauseLedger()
            var old: Data?
            let step = sqlite3_step(query)
            if step == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) {
                old = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
            }
            sqlite3_finalize(query)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw IOSPauseError.storage }
            if let old { ledger = try JSONDecoder().decode(IOSPauseLedger.self, from: old) }
            guard ledger.version == 1 else { throw IOSPauseError.storage }
            try access.check()
            let result = try edit(&ledger)
            try access.check()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ledger)
            if data != old {
                var insert: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(id,value) VALUES(1,?)", -1, &insert, nil) == SQLITE_OK else { throw IOSPauseError.storage }
                defer { sqlite3_finalize(insert) }
                let bound = data.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(insert, 1, ptr.baseAddress, Int32(ptr.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard bound == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw IOSPauseError.storage }
            }
            try execute("COMMIT")
            return result
        } catch {
            // Cancellation must not prevent cleanup. Closing also rolls back.
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// A committed presentation snapshot, without creating a DB or taking a
    /// reserved writer lock. Copy the blob and close before decoding JSON.
    func read() throws -> IOSPauseLedger {
        let access = try Self.beginHostAccess?() ?? IOSPauseDatabaseAccess()
        defer { access.finish() }
        try access.start()
        func readData() throws -> Data? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var connection: OpaquePointer?
            guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let db = connection else {
                if let connection { sqlite3_close(connection) }
                throw IOSPauseError.storage
            }
            defer { access.close(db) }
            try access.attach(db)
            sqlite3_busy_timeout(db, 2000)
            // A concurrent first writer may have created the file but not yet
            // created/committed the schema. That is still the initial ledger.
            var schema: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='state'", -1, &schema, nil) == SQLITE_OK else { throw IOSPauseError.storage }
            let schemaStep = sqlite3_step(schema)
            sqlite3_finalize(schema)
            if schemaStep == SQLITE_DONE { return nil }
            guard schemaStep == SQLITE_ROW else { throw IOSPauseError.storage }
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE id=1", -1, &query, nil) == SQLITE_OK else { throw IOSPauseError.storage }
            defer { sqlite3_finalize(query) }
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw IOSPauseError.storage }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        }
        let data = try readData()
        try access.check()
        let ledger = try data.map { try JSONDecoder().decode(IOSPauseLedger.self, from: $0) } ?? IOSPauseLedger()
        guard ledger.version == 1 else { throw IOSPauseError.storage }
        return ledger
    }
}
#endif
