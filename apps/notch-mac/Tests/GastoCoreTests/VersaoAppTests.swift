import XCTest
@testable import GastoCore

final class VersaoAppTests: XCTestCase {
    func testMainLimpa() {
        XCTAssertEqual(VersaoApp.ler(["TDCanal": "main", "TDVersao": "main-687f6b7"]),
                       VersaoApp(texto: "main-687f6b7", alpha: false))
    }

    func testBranchEAlpha() {
        XCTAssertEqual(VersaoApp.ler(["TDCanal": "alpha", "TDVersao": "branch-caixa-do-dono-76c4eef"]),
                       VersaoApp(texto: "branch-caixa-do-dono-76c4eef", alpha: true))
    }

    func testSemChaveOuIncoerenteEAlpha() {
        XCTAssertEqual(VersaoApp.ler(nil), VersaoApp(texto: "dev", alpha: true))
        XCTAssertEqual(VersaoApp.ler([:]), VersaoApp(texto: "dev", alpha: true))
        XCTAssertTrue(VersaoApp.ler(["TDCanal": "main", "TDVersao": "branch-x-1"]).alpha, "canal e texto têm de bater")
    }
}
