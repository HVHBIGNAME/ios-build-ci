import Foundation
import CryptoKit
import CommonCrypto

public enum WhitegramSessionCrypto {
    public static func sha1(_ data: Data) -> Data { return Data(Insecure.SHA1.hash(data: data)) }
    static func md5(_ data: Data) -> Data { return Data(Insecure.MD5.hash(data: data)) }

    public static func authKeyId(_ key: Data) -> Int64 {
        return Int64(bitPattern: sha1(key).suffix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) })
    }

    static func localKey(passcode: String, salt: Data) throws -> Data {
        guard salt.count == 32, passcode.utf8.count <= 1024 else { throw WhitegramSessionError.damagedTData }
        let password = Data(SHA512.hash(data: salt + Data(passcode.utf8) + salt))
        var result = Data(count: 256)
        let status = result.withUnsafeMutableBytes { result in
            password.withUnsafeBytes { password in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count, salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), passcode.isEmpty ? 1 : 100000, result.baseAddress?.assumingMemoryBound(to: UInt8.self), result.count)
                }
            }
        }
        guard status == kCCSuccess else { throw WhitegramSessionError.damagedTData }
        return result
    }

    static func localAesKey(authKey: Data, messageKey: Data) throws -> (key: Data, iv: Data) {
        guard authKey.count == 256, messageKey.count == 16 else { throw WhitegramSessionError.invalidKey }
        // Telegram Desktop local storage uses MTProto 1.0's receive direction (x = 8).
        let a = sha1(messageKey + authKey.subdata(in: 8..<40))
        let b = sha1(authKey.subdata(in: 40..<56) + messageKey + authKey.subdata(in: 56..<72))
        let c = sha1(authKey.subdata(in: 72..<104) + messageKey)
        let d = sha1(messageKey + authKey.subdata(in: 104..<136))
        return (a.subdata(in: 0..<8) + b.subdata(in: 8..<20) + c.subdata(in: 4..<16), a.subdata(in: 8..<20) + b.subdata(in: 0..<8) + c.subdata(in: 16..<20) + d.subdata(in: 0..<8))
    }

    static func decryptLocal(_ encrypted: Data, authKey: Data) throws -> Data {
        guard encrypted.count >= 32, encrypted.count % 16 == 0 else { throw WhitegramSessionError.damagedTData }
        let messageKey = Data(encrypted.prefix(16))
        let aes = try localAesKey(authKey: authKey, messageKey: messageKey)
        let decrypted = try aesIGE(Data(encrypted.dropFirst(16)), key: aes.key, iv: aes.iv, encrypt: false)
        guard constantTimeEqual(Data(sha1(decrypted).prefix(16)), messageKey) else { throw WhitegramSessionError.invalidPasscode }
        var reader = WhitegramSessionBinaryReader(decrypted)
        let count = Int(try reader.uint32(littleEndian: true))
        guard count >= 4, count <= decrypted.count, decrypted.count - count < 16 else { throw WhitegramSessionError.damagedTData }
        return decrypted.subdata(in: 4..<count)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    // The encrypt direction is also exercised by independent synthetic Desktop fixtures.
    static func aesIGE(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard key.count == 32, iv.count == 32, !data.isEmpty, data.count % 16 == 0 else { throw WhitegramSessionError.damagedTData }
        var previousCipher = [UInt8](iv.prefix(16))
        var previousPlain = [UInt8](iv.suffix(16))
        let input = [UInt8](data)
        var output = Data(capacity: data.count)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { key in
            CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key.baseAddress, key.count, nil, &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { throw WhitegramSessionError.damagedTData }
        defer { CCCryptorRelease(cryptor) }
        for offset in stride(from: 0, to: input.count, by: 16) {
            let block = Array(input[offset..<offset + 16])
            let xor = encrypt ? previousCipher : previousPlain
            let mixed = zip(block, xor).map { $0.0 ^ $0.1 }
            var transformed = [UInt8](repeating: 0, count: 16)
            var written = 0
            let status = mixed.withUnsafeBytes { mixed in
                transformed.withUnsafeMutableBytes { transformed in
                    CCCryptorUpdate(cryptor, mixed.baseAddress, 16, transformed.baseAddress, 16, &written)
                }
            }
            guard status == kCCSuccess, written == 16 else { throw WhitegramSessionError.damagedTData }
            let finalXor = encrypt ? previousPlain : previousCipher
            let result = zip(transformed, finalXor).map { $0.0 ^ $0.1 }
            output.append(contentsOf: result)
            previousCipher = encrypt ? result : block
            previousPlain = encrypt ? block : result
        }
        return output
    }
}

struct WhitegramSessionBinaryReader {
    let data: Data
    private(set) var offset = 0
    var remaining: Int { return data.count - offset }
    init(_ data: Data) { self.data = Data(data) }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw WhitegramSessionError.damagedTData }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func uint32(littleEndian: Bool = false) throws -> UInt32 {
        let values = try bytes(4)
        if littleEndian { return values.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) } }
        return values.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func uint64() throws -> UInt64 { return try bytes(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    mutating func byteArray() throws -> Data {
        let count = try uint32()
        guard count != UInt32.max else { throw WhitegramSessionError.damagedTData }
        return try bytes(Int(count))
    }
}
