import Foundation

public enum WhitegramSessionTData {
    public static func read(directory: URL, passcode: String = "") throws -> [WhitegramPortableAccount] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw WhitegramSessionError.unsafeFile }
        var budget = WhitegramSessionFiles.maximumTotalBytes
        let keyData = try readContainer(directory: directory, name: "key_data", budget: &budget)
        var reader = WhitegramSessionBinaryReader(keyData)
        let salt = try reader.byteArray()
        let encryptedKey = try reader.byteArray()
        let encryptedInfo = try reader.byteArray()
        guard reader.remaining == 0, salt.count == 32 else { throw WhitegramSessionError.damagedTData }
        let passcodeKey = try WhitegramSessionCrypto.localKey(passcode: passcode, salt: salt)
        let localKey: Data
        do { localKey = try WhitegramSessionCrypto.decryptLocal(encryptedKey, authKey: passcodeKey) }
        catch WhitegramSessionError.invalidPasscode {
            throw passcode.isEmpty ? WhitegramSessionError.passcodeRequired : WhitegramSessionError.invalidPasscode
        }
        guard localKey.count == 256 else { throw WhitegramSessionError.damagedTData }
        let info: Data
        do { info = try WhitegramSessionCrypto.decryptLocal(encryptedInfo, authKey: localKey) }
        catch { throw WhitegramSessionError.damagedTData }
        var infoReader = WhitegramSessionBinaryReader(info)
        let count = Int(try infoReader.uint32())
        guard count > 0, count <= WhitegramSessionBackup.maximumAccounts else { throw WhitegramSessionError.damagedTData }
        var indices: [UInt32] = []
        for _ in 0..<count {
            let index = try infoReader.uint32()
            guard index < 100, !indices.contains(index) else { throw WhitegramSessionError.damagedTData }
            indices.append(index)
        }
        // Desktop may append its active account index after the account list.
        guard infoReader.remaining == 0 || infoReader.remaining == 4 else { throw WhitegramSessionError.unsupportedTData }
        var accounts: [WhitegramPortableAccount] = []
        for index in indices {
            let name = index == 0 ? "data" : "data#\(index + 1)"
            let container = try readContainer(directory: directory, name: accountFileName(name), budget: &budget)
            var containerReader = WhitegramSessionBinaryReader(container)
            let encrypted = try containerReader.byteArray()
            guard containerReader.remaining == 0 else { throw WhitegramSessionError.damagedTData }
            let decrypted: Data
            do { decrypted = try WhitegramSessionCrypto.decryptLocal(encrypted, authKey: localKey) }
            catch { throw WhitegramSessionError.damagedTData }
            let account = try readAuthorization(decrypted)
            guard !accounts.contains(where: { $0.identity == account.identity }) else { throw WhitegramSessionError.duplicateIdentity }
            accounts.append(account)
        }
        return accounts
    }

    static func accountFileName(_ name: String) -> String {
        let digits = Array("0123456789ABCDEF")
        return WhitegramSessionCrypto.md5(Data(name.utf8)).prefix(8).map { String(digits[Int($0 & 15)]) + String(digits[Int($0 >> 4)]) }.joined()
    }

    static func containerPayload(_ data: Data) throws -> Data {
        guard data.count >= 24, data.prefix(4) == Data("TDF$".utf8) else { throw WhitegramSessionError.damagedTData }
        let payload = data.subdata(in: 8..<data.count - 16)
        var length = UInt32(payload.count).littleEndian
        let lengthData = withUnsafeBytes(of: &length) { Data($0) }
        let checksum = WhitegramSessionCrypto.md5(payload + lengthData + data.subdata(in: 4..<8) + Data("TDF$".utf8))
        guard WhitegramSessionCrypto.constantTimeEqual(checksum, Data(data.suffix(16))) else { throw WhitegramSessionError.damagedTData }
        return payload
    }

    private static func readContainer(directory: URL, name: String, budget: inout Int) throws -> Data {
        var found = false
        for suffix in ["s", "0", "1"] {
            let url = directory.appendingPathComponent(name + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            found = true
            let data = try WhitegramSessionFiles.read(url, maximumBytes: min(budget, WhitegramSessionFiles.maximumFileBytes))
            budget -= data.count
            do { return try containerPayload(data) }
            catch WhitegramSessionError.damagedTData { continue }
        }
        throw found ? WhitegramSessionError.damagedTData : WhitegramSessionError.unsupportedTData
    }

    static func readAuthorization(_ data: Data) throws -> WhitegramPortableAccount {
        // Original reader recognizes dbiMtpAuthorization (0x4b) in the first 512 bytes.
        guard data.count >= 8 else { throw WhitegramSessionError.damagedTData }
        for offset in stride(from: 0, through: min(512, data.count - 8), by: 4) {
            var reader = WhitegramSessionBinaryReader(Data(data.dropFirst(offset)))
            guard try reader.uint32() == 0x4b else { continue }
            let payload = try reader.byteArray()
            return try parseAuthorization(payload)
        }
        throw WhitegramSessionError.unsupportedTData
    }

    static func parseAuthorization(_ data: Data) throws -> WhitegramPortableAccount {
        var reader = WhitegramSessionBinaryReader(data)
        let first = try reader.uint32()
        let second = try reader.uint32()
        let userId: Int64
        let dcId: Int32
        if first == UInt32.max, second == UInt32.max {
            let wideId = try reader.uint64()
            guard let value = Int64(exactly: wideId) else { throw WhitegramSessionError.missingIdentity }
            userId = value
            dcId = Int32(bitPattern: try reader.uint32())
        } else {
            userId = Int64(first)
            dcId = Int32(bitPattern: second)
        }
        let count = Int(try reader.uint32())
        guard (1...16).contains(count) else { throw WhitegramSessionError.damagedTData }
        var keys: [Int32: Data] = [:]
        for _ in 0..<count {
            let id = Int32(bitPattern: try reader.uint32())
            guard keys[id] == nil else { throw WhitegramSessionError.damagedTData }
            keys[id] = try reader.bytes(256)
        }
        // Do not pair the claimed master DC with a different DC's key.
        guard let key = keys[dcId] else { throw WhitegramSessionError.invalidDatacenter }
        return try WhitegramPortableAccount(dcId: dcId, authKey: key, userId: userId, name: "ID \(userId)")
    }
}
