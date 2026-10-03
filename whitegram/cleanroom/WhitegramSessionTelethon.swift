import Foundation
import CoreFoundation
#if canImport(sqlcipher)
import sqlcipher
#else
import SQLite3
#endif

public enum WhitegramSessionTelethon {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let schema = """
        CREATE TABLE version (version integer primary key);
        INSERT INTO version VALUES (8);
        CREATE TABLE sessions (dc_id integer primary key, server_address text, port integer, auth_key blob, takeout_id integer, tmp_auth_key blob);
        CREATE TABLE entities (id integer primary key, hash integer not null, username text, phone integer, name text, date integer);
        CREATE TABLE sent_files (md5_digest blob, file_size integer, type integer, id integer, hash integer, primary key(md5_digest, file_size, type));
        CREATE TABLE update_state (id integer primary key, pts integer, qts integer, date integer, seq integer);
        """

    private static let productionAddresses: [Int32: String] = [1: "149.154.175.53", 2: "149.154.167.51", 3: "149.154.175.100", 4: "149.154.167.91", 5: "91.108.56.130"]
    private static let testAddresses: [Int32: String] = [1: "149.154.175.10", 2: "149.154.167.40", 3: "149.154.175.117"]

    public static func read(at url: URL, sidecar: Data? = nil) throws -> WhitegramPortableAccount {
        // Open only a private snapshot. SQLite never gets a path supplied by a document provider.
        let data = try WhitegramSessionFiles.read(url)
        guard data.prefix(16) == Data("SQLite format 3\0".utf8) else { throw WhitegramSessionError.encryptedSession }
        let staging = try WhitegramSessionStagingDirectory()
        let snapshot = staging.url.appendingPathComponent("session.sqlite")
        try WhitegramSessionFiles.write(data, to: snapshot)
        let account = try readSnapshot(snapshot, sidecar: sidecar, fallbackName: url.deletingPathExtension().lastPathComponent)
        try staging.remove()
        return account
    }

    private static func readSnapshot(_ url: URL, sidecar: Data?, fallbackName: String) throws -> WhitegramPortableAccount {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw WhitegramSessionError.unreadable
        }
        defer { sqlite3_close(database) }
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(WhitegramSessionFiles.maximumFileBytes))
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 4096)
        try execute(database, "PRAGMA query_only = ON")
        try execute(database, "PRAGMA trusted_schema = OFF")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(sessions)", -1, &statement, nil) == SQLITE_OK else { throw WhitegramSessionError.invalidFormat }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let column = sqlite3_column_text(statement, 1) { columns.insert(String(cString: column)) }
        }
        sqlite3_finalize(statement)
        statement = nil
        guard columns.contains("dc_id"), columns.contains("auth_key") else { throw WhitegramSessionError.invalidFormat }
        let query = "SELECT dc_id, auth_key, " + (columns.contains("user_id") ? "user_id" : "NULL") + ", " + (columns.contains("server_address") ? "server_address" : "NULL") + ", " + (columns.contains("test_mode") ? "test_mode" : "NULL") + " FROM sessions LIMIT 2"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw WhitegramSessionError.invalidFormat }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 1) == SQLITE_BLOB, sqlite3_column_bytes(statement, 1) == 256,
              let bytes = sqlite3_column_blob(statement, 1) else { throw WhitegramSessionError.invalidKey }
        let dc = sqlite3_column_int64(statement, 0)
        guard let dcId = Int32(exactly: dc) else { throw WhitegramSessionError.invalidDatacenter }
        let key = Data(bytes: bytes, count: 256)
        var userId = sqlite3_column_type(statement, 2) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 2) : 0
        let address = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let pyrogramTesting: Bool?
        if columns.contains("test_mode") {
            guard sqlite3_column_type(statement, 4) == SQLITE_INTEGER else { throw WhitegramSessionError.invalidFormat }
            let flag = sqlite3_column_int64(statement, 4)
            guard flag == 0 || flag == 1 else { throw WhitegramSessionError.invalidFormat }
            pyrogramTesting = flag == 1
        } else { pyrogramTesting = nil }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw WhitegramSessionError.invalidFormat }
        let metadata = try Metadata(data: sidecar)
        if let metadataId = metadata.userId {
            guard userId <= 0 || userId == metadataId else { throw WhitegramSessionError.identityMismatch }
            userId = metadataId
        }
        let isKnownTestAddress = address.map { testAddresses.values.contains($0) } ?? false
        if let testing = metadata.testing, testing != isKnownTestAddress, let address,
           testAddresses.values.contains(address) || productionAddresses.values.contains(address) { throw WhitegramSessionError.identityMismatch }
        if let pyrogramTesting, let flag = metadata.testing, flag != pyrogramTesting { throw WhitegramSessionError.identityMismatch }
        let testing = metadata.testing ?? pyrogramTesting ?? isKnownTestAddress
        return try WhitegramPortableAccount(dcId: dcId, authKey: key, userId: userId, name: metadata.name ?? fallbackName, phone: metadata.phone, testingEnvironment: testing)
    }

    public static func write(_ account: WhitegramPortableAccount, to directory: URL) throws -> [URL] {
        let basename = account.identity.keychainId.replacingOccurrences(of: ":", with: "-")
        let sessionURL = directory.appendingPathComponent(basename + ".session")
        let metadataURL = directory.appendingPathComponent(basename + ".json")
        guard !FileManager.default.fileExists(atPath: sessionURL.path), !FileManager.default.fileExists(atPath: metadataURL.path) else { throw WhitegramSessionError.changedFile }
        guard let address = (account.identity.testingEnvironment ? testAddresses : productionAddresses)[account.dcId] else { throw WhitegramSessionError.invalidDatacenter }
        try WhitegramSessionFiles.write(Data(), to: sessionURL)
        var database: OpaquePointer?
        guard sqlite3_open_v2(sessionURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw WhitegramSessionError.unreadable
        }
        do {
            try execute(database, "BEGIN IMMEDIATE")
            try execute(database, schema)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO sessions (dc_id, server_address, port, auth_key) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { throw WhitegramSessionError.invalidFormat }
            do {
                defer { sqlite3_finalize(statement) }
                guard sqlite3_bind_int(statement, 1, account.dcId) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, address, -1, transient) == SQLITE_OK,
                      sqlite3_bind_int(statement, 3, 443) == SQLITE_OK else { throw WhitegramSessionError.unreadable }
                let status = account.authKey.withUnsafeBytes { key in sqlite3_bind_blob(statement, 4, key.baseAddress, Int32(key.count), transient) }
                guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw WhitegramSessionError.unreadable }
            }
            try execute(database, "COMMIT")
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close(database)
            throw error
        }
        guard sqlite3_close(database) == SQLITE_OK else { throw WhitegramSessionError.unreadable }
        let metadata: [String: Any] = ["id": account.identity.userId, "first_name": account.name, "phone": account.phone ?? "", "whitegram_test_environment": account.identity.testingEnvironment, "session_file": basename]
        try WhitegramSessionFiles.write(JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), to: metadataURL)
        return [sessionURL, metadataURL]
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw WhitegramSessionError.invalidFormat }
    }

    private struct Metadata {
        let userId: Int64?
        let name: String?
        let phone: String?
        let testing: Bool?

        init(data: Data?) throws {
            guard let data else { userId = nil; name = nil; phone = nil; testing = nil; return }
            guard data.count <= WhitegramSessionBackup.maximumBytes else { throw WhitegramSessionError.tooLarge }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WhitegramSessionError.invalidFormat }
            var ids: [Int64] = []
            for key in ["id", "user_id", "userId", "uid"] {
                guard let value = object[key], !(value is NSNull) else { continue }
                let text: String
                if let number = value as? NSNumber {
                    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw WhitegramSessionError.invalidFormat }
                    text = number.stringValue
                } else if let string = value as? String { text = string }
                else { throw WhitegramSessionError.invalidFormat }
                guard let id = Int64(text), id > 0 else { throw WhitegramSessionError.missingIdentity }
                ids.append(id)
            }
            guard Set(ids).count <= 1 else { throw WhitegramSessionError.identityMismatch }
            userId = ids.first
            let fullName = [object["first_name"] as? String, object["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            name = fullName.isEmpty ? (object["username"] as? String).map { "@" + $0 } : fullName
            if let number = object["phone"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { phone = number.stringValue }
            else { phone = object["phone"] as? String }
            if let flag = object["whitegram_test_environment"] {
                guard let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw WhitegramSessionError.invalidFormat }
                testing = number.boolValue
            } else { testing = nil }
        }
    }
}
