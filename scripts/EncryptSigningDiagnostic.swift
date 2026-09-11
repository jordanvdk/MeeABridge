import Foundation
import CryptoKit
import Security
import Darwin

private let maxLogTailBytes = 2 * 1024 * 1024
private let maxContextBytes = 512
private let maxPublicKeyDERBytes = 8192

private enum DiagnosticFailure: Error {
    case invalidInput
    case invalidPublicKey
    case cryptography
    case fileAccess
    case selfTest
}

private struct Envelope: Codable {
    let version: Int
    let algorithm: String
    let context: String
    let wrappedKey: String
    let nonce: String
    let ciphertext: String
    let tag: String

    private enum CodingKeys: String, CodingKey {
        case version, algorithm, context, wrappedKey, nonce, ciphertext, tag
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) { self.bytes = Array(data) }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func readElement(tag: UInt8) throws -> Data {
        guard readByte() == tag else { throw DiagnosticFailure.invalidPublicKey }
        let length = try readLength()
        guard length <= bytes.count - offset else { throw DiagnosticFailure.invalidPublicKey }
        let result = Data(bytes[offset..<(offset + length)])
        offset += length
        return result
    }

    private mutating func readByte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readLength() throws -> Int {
        guard let first = readByte() else { throw DiagnosticFailure.invalidPublicKey }
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7f)
        guard count > 0, count <= 4 else { throw DiagnosticFailure.invalidPublicKey }
        var length = 0
        for _ in 0..<count {
            guard let byte = readByte() else { throw DiagnosticFailure.invalidPublicKey }
            if length > (Int.max >> 8) { throw DiagnosticFailure.invalidPublicKey }
            length = (length << 8) | Int(byte)
        }
        guard length >= 0 else { throw DiagnosticFailure.invalidPublicKey }
        if length < 0x80 || (count > 1 && length < (1 << (8 * (count - 1)))) {
            throw DiagnosticFailure.invalidPublicKey
        }
        return length
    }
}

private func rsaModulusBitCount(_ der: Data) throws -> Int {
    var outer = DERReader(der)
    let sequence = try outer.readElement(tag: 0x30)
    guard outer.isAtEnd else { throw DiagnosticFailure.invalidPublicKey }
    var body = DERReader(sequence)
    let encodedModulus = try body.readElement(tag: 0x02)
    let exponent = try body.readElement(tag: 0x02)
    guard body.isAtEnd, !encodedModulus.isEmpty, !exponent.isEmpty else {
        throw DiagnosticFailure.invalidPublicKey
    }

    let modulus = Array(encodedModulus)
    guard modulus[0] & 0x80 == 0 else { throw DiagnosticFailure.invalidPublicKey }
    if modulus.count > 1, modulus[0] == 0 {
        guard modulus[1] & 0x80 != 0 else { throw DiagnosticFailure.invalidPublicKey }
    }
    let modulusWithoutSign = modulus.first == 0 ? Array(modulus.dropFirst()) : modulus
    guard !modulusWithoutSign.isEmpty, modulusWithoutSign.contains(where: { $0 != 0 }) else {
        throw DiagnosticFailure.invalidPublicKey
    }

    let exponentBytes = Array(exponent)
    guard exponentBytes[0] & 0x80 == 0 else { throw DiagnosticFailure.invalidPublicKey }
    if exponentBytes.count > 1, exponentBytes[0] == 0 {
        guard exponentBytes[1] & 0x80 != 0 else { throw DiagnosticFailure.invalidPublicKey }
    }
    guard exponentBytes.contains(where: { $0 != 0 }) else { throw DiagnosticFailure.invalidPublicKey }

    let first = modulusWithoutSign[0]
    return (modulusWithoutSign.count - 1) * 8 + (8 - first.leadingZeroBitCount)
}

private func boundedRead(_ path: String, maximum: Int) throws -> Data {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } catch {
        throw DiagnosticFailure.fileAccess
    }
    defer { try? handle.close() }
    do {
        let end = try handle.seekToEnd()
        let start = end > UInt64(maximum) ? end - UInt64(maximum) : 0
        try handle.seek(toOffset: start)
        return try handle.read(upToCount: maximum) ?? Data()
    } catch {
        throw DiagnosticFailure.fileAccess
    }
}

private func readPublicKeyDER(_ path: String) throws -> Data {
    let data = try boundedRead(path, maximum: maxPublicKeyDERBytes + 1)
    guard data.count <= maxPublicKeyDERBytes else { throw DiagnosticFailure.invalidPublicKey }
    return data
}

private func publicKey(from der: Data) throws -> SecKey {
    let bits = try rsaModulusBitCount(der)
    guard bits >= 3072, bits <= 8192 else { throw DiagnosticFailure.invalidPublicKey }
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass: kSecAttrKeyClassPublic,
    ]
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
          SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA256) else {
        throw DiagnosticFailure.invalidPublicKey
    }
    return key
}

private func symmetricKeyData(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

private func encryptDiagnostic(publicKey: SecKey, tail: Data, context: String) throws -> Envelope {
    let contextData = Data(context.utf8)
    guard contextData.count <= maxContextBytes else { throw DiagnosticFailure.invalidInput }
    let key = SymmetricKey(size: .bits256)
    let sealed: AES.GCM.SealedBox
    do {
        sealed = try AES.GCM.seal(tail, using: key, authenticating: contextData)
    } catch {
        throw DiagnosticFailure.cryptography
    }

    var encryptionError: Unmanaged<CFError>?
    guard let wrapped = SecKeyCreateEncryptedData(
        publicKey, .rsaEncryptionOAEPSHA256, symmetricKeyData(key) as CFData, &encryptionError
    ) as Data? else { throw DiagnosticFailure.cryptography }
    let nonce = Data(sealed.nonce)
    guard nonce.count == 12, sealed.tag.count == 16 else { throw DiagnosticFailure.cryptography }
    return Envelope(
        version: 1,
        algorithm: "RSA-OAEP-256+A256GCM",
        context: context,
        wrappedKey: wrapped.base64EncodedString(),
        nonce: nonce.base64EncodedString(),
        ciphertext: sealed.ciphertext.base64EncodedString(),
        tag: sealed.tag.base64EncodedString()
    )
}

private func writeExclusively(_ data: Data, to path: String) throws {
    let descriptor = path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw DiagnosticFailure.fileAccess }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
        _ = Darwin.close(descriptor)
        throw DiagnosticFailure.fileAccess
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        try? handle.close()
        throw DiagnosticFailure.fileAccess
    }
}

private func decryptKey(_ wrapped: Data, privateKey: SecKey) throws -> SymmetricKey {
    var decryptionError: Unmanaged<CFError>?
    guard let keyData = SecKeyCreateDecryptedData(
        privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, &decryptionError
    ) as Data? else { throw DiagnosticFailure.selfTest }
    return SymmetricKey(data: keyData)
}

private func openEnvelope(
    _ envelope: Envelope,
    privateKey: SecKey,
    ciphertext: Data,
    tag: Data,
    context: String
) throws -> Data {
    guard let wrapped = Data(base64Encoded: envelope.wrappedKey),
          let nonceData = Data(base64Encoded: envelope.nonce),
          let nonce = try? AES.GCM.Nonce(data: nonceData) else {
        throw DiagnosticFailure.selfTest
    }
    let key = try decryptKey(wrapped, privateKey: privateKey)
    do {
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    } catch {
        throw DiagnosticFailure.selfTest
    }
}

private func decryptForSelfTest(_ envelope: Envelope, privateKey: SecKey, plaintext: Data) throws {
    guard envelope.version == 1,
          envelope.algorithm == "RSA-OAEP-256+A256GCM",
          let ciphertext = Data(base64Encoded: envelope.ciphertext),
          let tag = Data(base64Encoded: envelope.tag) else {
        throw DiagnosticFailure.selfTest
    }
    let opened = try openEnvelope(
        envelope,
        privateKey: privateKey,
        ciphertext: ciphertext,
        tag: tag,
        context: envelope.context
    )
    guard opened == plaintext else { throw DiagnosticFailure.selfTest }
}

private func assertAuthenticationFailure(
    _ envelope: Envelope,
    privateKey: SecKey,
    ciphertext: Data,
    tag: Data,
    context: String
) throws {
    do {
        _ = try openEnvelope(
            envelope,
            privateKey: privateKey,
            ciphertext: ciphertext,
            tag: tag,
            context: context
        )
    } catch {
        // The expected result is authentication rejection.
        return
    }
    throw DiagnosticFailure.selfTest
}

private func runNativeCLI(_ arguments: [String]) throws -> (Int32, Data, Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile(),
            errors.fileHandleForReading.readDataToEndOfFile()
        )
    } catch {
        throw DiagnosticFailure.selfTest
    }
}

private func runSelfTest() throws {
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits: 3072,
    ]
    var generationError: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError),
          let generatedPublicKey = SecKeyCopyPublicKey(privateKey),
          let publicDER = SecKeyCopyExternalRepresentation(generatedPublicKey, nil) as Data? else {
        throw DiagnosticFailure.selfTest
    }

    // Require the same PKCS#1 DER representation used by the normal CLI path.
    let importedPublicKey = try publicKey(from: publicDER)
    let plaintext = Data("private signing stage diagnostics\n".utf8)
    let context = "run=synthetic;attempt=1;stage=archive"
    let envelope = try encryptDiagnostic(publicKey: importedPublicKey, tail: plaintext, context: context)
    let encoded = try envelope.jsonData()
    guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw DiagnosticFailure.selfTest
    }
    let expectedKeys: Set<String> = ["version", "algorithm", "context", "wrappedKey", "nonce", "ciphertext", "tag"]
    guard Set(object.keys) == expectedKeys else { throw DiagnosticFailure.selfTest }
    try decryptForSelfTest(envelope, privateKey: privateKey, plaintext: plaintext)

    guard let ciphertext = Data(base64Encoded: envelope.ciphertext),
          let tag = Data(base64Encoded: envelope.tag) else {
        throw DiagnosticFailure.selfTest
    }
    var badTag = tag
    badTag[0] ^= 1
    try assertAuthenticationFailure(
        envelope,
        privateKey: privateKey,
        ciphertext: ciphertext,
        tag: badTag,
        context: context
    )
    var badCiphertext = ciphertext
    badCiphertext[0] ^= 1
    try assertAuthenticationFailure(
        envelope,
        privateKey: privateKey,
        ciphertext: badCiphertext,
        tag: tag,
        context: context
    )
    try assertAuthenticationFailure(
        envelope,
        privateKey: privateKey,
        ciphertext: ciphertext,
        tag: tag,
        context: "wrong-context"
    )

    // A 2048-bit key is deliberately outside the accepted 3072..8192-bit range.
    let smallAttributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits: 2048,
    ]
    var smallGenerationError: Unmanaged<CFError>?
    guard let smallPrivateKey = SecKeyCreateRandomKey(smallAttributes as CFDictionary, &smallGenerationError),
          let smallPublicKey = SecKeyCopyPublicKey(smallPrivateKey),
          let smallDER = SecKeyCopyExternalRepresentation(smallPublicKey, nil) as Data? else {
        throw DiagnosticFailure.selfTest
    }
    var rejectedSmallKey = false
    do {
        _ = try publicKey(from: smallDER)
    } catch {
        rejectedSmallKey = true
    }
    guard rejectedSmallKey else { throw DiagnosticFailure.selfTest }

    guard (try? encryptDiagnostic(
        publicKey: importedPublicKey,
        tail: plaintext,
        context: String(repeating: "x", count: maxContextBytes + 1)
    )) == nil else { throw DiagnosticFailure.selfTest }
    // Exercise the actual CLI’s fixed failure behavior without a private key or
    // a real log. The temporary public key and log are synthetic and discarded.
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("meea-encrypt-self-test-" + UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    } catch {
        throw DiagnosticFailure.selfTest
    }
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let invalidKeyPath = temporaryDirectory.appendingPathComponent("invalid.der")
    let validKeyPath = temporaryDirectory.appendingPathComponent("public.der")
    let inputPath = temporaryDirectory.appendingPathComponent("synthetic.log")
    let invalidOutputPath = temporaryDirectory.appendingPathComponent("invalid-output.json")
    let existingOutputPath = temporaryDirectory.appendingPathComponent("existing-output.json")
    let marker = Data("existing output must remain unchanged".utf8)
    do {
        try Data([0x01]).write(to: invalidKeyPath, options: .withoutOverwriting)
        try publicDER.write(to: validKeyPath, options: .withoutOverwriting)
        try plaintext.write(to: inputPath, options: .withoutOverwriting)
        let invalidResult = try runNativeCLI([
            String(#filePath), invalidKeyPath.path, inputPath.path, invalidOutputPath.path, context
        ])
        let fixedFailure = Data("Signing diagnostic failed safely.\n".utf8)
        guard invalidResult.0 != 0,
              invalidResult.1.isEmpty,
              invalidResult.2 == fixedFailure,
              !FileManager.default.fileExists(atPath: invalidOutputPath.path) else {
            throw DiagnosticFailure.selfTest
        }
        try marker.write(to: existingOutputPath, options: .withoutOverwriting)
        let existingResult = try runNativeCLI([
            String(#filePath), validKeyPath.path, inputPath.path, existingOutputPath.path, context
        ])
        guard existingResult.0 != 0,
              existingResult.1.isEmpty,
              existingResult.2 == fixedFailure,
              try Data(contentsOf: existingOutputPath) == marker else {
            throw DiagnosticFailure.selfTest
        }
    } catch let failure as DiagnosticFailure {
        throw failure
    } catch {
        throw DiagnosticFailure.selfTest
    }
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 1, arguments[0] == "--self-test" {
        try runSelfTest()
        print("Signing diagnostic self-test passed.")
        return
    }
    guard arguments.count == 4 else { throw DiagnosticFailure.invalidInput }
    let key = try publicKey(from: readPublicKeyDER(arguments[0]))
    let tail = try boundedRead(arguments[1], maximum: maxLogTailBytes)
    let envelope = try encryptDiagnostic(publicKey: key, tail: tail, context: arguments[3])
    try writeExclusively(try envelope.jsonData(), to: arguments[2])
    print("Signing diagnostic encrypted safely.")
}

do {
    try run()
} catch {
    fputs("Signing diagnostic failed safely.\n", stderr)
    Darwin.exit(1)
}
