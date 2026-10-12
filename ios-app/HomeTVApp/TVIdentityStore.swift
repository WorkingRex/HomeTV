import Foundation
import Security
import X509

struct TVIdentity {
    let privateKey: SecKey
    let certificate: SecCertificate
    let clientModulus: Data
    let clientExponent: Data
}

enum TVIdentityError: Error {
    case keyGenerationFailed(String)
    case keyAttributesUnavailable
    case certificateCreationFailed
    case certificateSerializationFailed
    case invalidCertificateData
    case keychainFailure(OSStatus)
}

final class TVIdentityStore {
    private let privateKeyService = "com.rexylin.hometv.client-private-key"
    private let certificateService = "com.rexylin.hometv.client-certificate"
    private let certificateAccount = "client"
    private let clientName = "HomeTV Remote"
    private let useKeychain: Bool
    private var transientKeyData: Data?
    private var transientCertificateData: Data?

    init(useKeychain: Bool = true) {
        self.useKeychain = useKeychain
    }

    func hasStoredIdentity() -> Bool {
        (try? loadKeyData()) != nil && (try? loadCertificateData()) != nil
    }

    func isPaired(for deviceID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "com.rexylin.hometv.paired.\(deviceID)")
    }

    func markPaired(for deviceID: String) {
        UserDefaults.standard.set(true, forKey: "com.rexylin.hometv.paired.\(deviceID)")
    }

    func loadOrCreate() throws -> TVIdentity {
        let privateKey = try loadOrCreatePrivateKey()
        let certificateData: Data

        if let savedCertificate = try loadCertificateData() {
            certificateData = savedCertificate
        } else {
            certificateData = try createCertificate(for: privateKey)
            try saveCertificateData(certificateData)
        }

        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw TVIdentityError.invalidCertificateData
        }

        let attributes = try Self.rsaNumbers(fromCertificateData: certificateData)
        return TVIdentity(
            privateKey: privateKey,
            certificate: certificate,
            clientModulus: attributes.modulus,
            clientExponent: attributes.exponent
        )
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
        if let keyData = try loadKeyData() {
            var error: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2048,
            ]
            guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
                throw TVIdentityError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Invalid stored key")
            }
            return key
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsExtractable as String: true,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TVIdentityError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw TVIdentityError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unable to export key")
        }
        try saveKeyData(keyData)
        return key
    }

    private func loadKeyData() throws -> Data? {
        if !useKeychain {
            return transientKeyData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: privateKeyService,
            kSecAttrAccount as String: certificateAccount,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TVIdentityError.keychainFailure(status)
        }
        return result as? Data
    }

    private func saveKeyData(_ data: Data) throws {
        if !useKeychain {
            transientKeyData = data
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: privateKeyService,
            kSecAttrAccount as String: certificateAccount,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TVIdentityError.keychainFailure(status)
        }
    }

    static func rsaNumbers(fromCertificateData data: Data) throws -> (modulus: Data, exponent: Data) {
        let certificate = try Certificate(derEncoded: [UInt8](data))
        let publicKeyData = Data(certificate.publicKey.subjectPublicKeyInfoBytes)
        if let numbers = try? Self.parsePKCS1PublicKey(publicKeyData) {
            return numbers
        }
        return try Self.parseSubjectPublicKeyInfo(publicKeyData)
    }

    private static func parsePKCS1PublicKey(_ data: Data) throws -> (modulus: Data, exponent: Data) {
        var reader = DERReader(data: data)
        let body = try reader.read(tag: 0x30)
        var bodyReader = DERReader(data: body)
        return (try bodyReader.readInteger(), try bodyReader.readInteger())
    }

    private static func parsePKCS1PrivateKey(_ data: Data) throws -> (modulus: Data, exponent: Data) {
        var reader = DERReader(data: data)
        let body = try reader.read(tag: 0x30)
        var bodyReader = DERReader(data: body)
        _ = try bodyReader.readInteger()
        return (try bodyReader.readInteger(), try bodyReader.readInteger())
    }

    private static func parseSubjectPublicKeyInfo(_ data: Data) throws -> (modulus: Data, exponent: Data) {
        var reader = DERReader(data: data)
        let body = try reader.read(tag: 0x30)
        var bodyReader = DERReader(data: body)
        _ = try bodyReader.read(tag: 0x30)
        let bitString = try bodyReader.read(tag: 0x03)
        guard bitString.first == 0 else {
            throw TVIdentityError.keyAttributesUnavailable
        }
        return try parsePKCS1PublicKey(Data(bitString.dropFirst()))
    }

    private func createCertificate(for privateKey: SecKey) throws -> Data {
        let certificateKey = try Certificate.PrivateKey(privateKey)
        let name = try DistinguishedName {
            CommonName(clientName)
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certificateKey.publicKey,
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 3650),
            issuer: name,
            subject: name,
            extensions: extensions,
            issuerPrivateKey: certificateKey
        )
        return Data(try certificate.serializeAsPEM().derBytes)
    }

    private func loadCertificateData() throws -> Data? {
        if !useKeychain {
            return transientCertificateData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: certificateAccount,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TVIdentityError.keychainFailure(status)
        }
        return data
    }

    private func saveCertificateData(_ data: Data) throws {
        if !useKeychain {
            transientCertificateData = data
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: certificateAccount,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TVIdentityError.keychainFailure(status)
        }
    }
}

private struct DERReader {
    let data: Data
    var offset = 0

    mutating func read(tag expectedTag: UInt8) throws -> Data {
        guard data.indices.contains(offset), data[offset] == expectedTag else {
            throw TVIdentityError.keyAttributesUnavailable
        }
        offset += 1
        let length = try readLength()
        guard offset + length <= data.count else {
            throw TVIdentityError.keyAttributesUnavailable
        }
        let value = Data(data[offset..<(offset + length)])
        offset += length
        return value
    }

    mutating func readInteger() throws -> Data {
        var value = try read(tag: 0x02)
        while value.count > 1, value.first == 0 {
            value.removeFirst()
        }
        return value
    }

    mutating private func readLength() throws -> Int {
        guard data.indices.contains(offset) else {
            throw TVIdentityError.keyAttributesUnavailable
        }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= 4, offset + byteCount <= data.count else {
            throw TVIdentityError.keyAttributesUnavailable
        }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }
}