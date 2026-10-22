import XCTest
@testable import HomeTV

final class TVIdentityStoreTests: XCTestCase {
    func testSeparatePhonesHaveUniqueCertificateNamesAndReuseTheirIdentity() throws {
        let firstStore = TVIdentityStore(useKeychain: false)
        let first = try firstStore.loadOrCreate()
        let second = try TVIdentityStore(useKeychain: false).loadOrCreate()
        let reloaded = try firstStore.loadOrCreate(upgradeLegacyCertificate: true)
        let firstName = try XCTUnwrap(SecCertificateCopySubjectSummary(first.certificate) as String?)
        let secondName = try XCTUnwrap(SecCertificateCopySubjectSummary(second.certificate) as String?)
        XCTAssertTrue(firstName.hasPrefix("HomeTV Remote-"))
        XCTAssertNotEqual(firstName, secondName)
        XCTAssertEqual(SecCertificateCopyData(first.certificate) as Data, SecCertificateCopyData(reloaded.certificate) as Data)
        XCTAssertEqual(first.clientModulus, reloaded.clientModulus)
        XCTAssertNotEqual(first.clientModulus, second.clientModulus)
    }

    func testIdentityStoreCreatesReusableIdentity() throws {
        let identity = try TVIdentityStore(useKeychain: false).loadOrCreate()
        XCTAssertTrue(SecKeyIsAlgorithmSupported(identity.privateKey, .sign, .rsaSignatureMessagePKCS1v15SHA256))
        XCTAssertFalse(identity.clientModulus.isEmpty)
        XCTAssertFalse(identity.clientExponent.isEmpty)
    }
}