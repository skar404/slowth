#if os(iOS) || PAUSE_TESTS
import Foundation
import SQLite3

/// A single SQLite row and BEGIN IMMEDIATE coordinate all extension processes.
/// OS writes inside a transaction still aren't atomic with SQLite; on crash,
/// the durable active/ending intent is reconciled again. No fallback defaults.
final class IOSPauseDatabase {
    let url: URL
    init(url: URL) { self.url = url }

    func transaction<T>(_ edit: (inout IOSPauseLedger) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }; throw IOSPauseError.storage
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        func execute(_ sql: String) throws {
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
            let result = try edit(&ledger)
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
            try? execute("ROLLBACK")
            throw error
        }
    }
}
#endif
