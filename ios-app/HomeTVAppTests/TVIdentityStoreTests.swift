import XCTest
@testable import HomeTV

final class TVIdentityStoreTests: XCTestCase {
    func testIdentityStoreCreatesReusableIdentity() throws {
        let identity = try TVIdentityStore(useKeychain: false).loadOrCreate()
        XCTAssertTrue(SecKeyIsAlgorithmSupported(identity.privateKey, .sign, .rsaSignatureMessagePKCS1v15SHA256))
        XCTAssertFalse(identity.clientModulus.isEmpty)
        XCTAssertFalse(identity.clientExponent.isEmpty)
    }
}