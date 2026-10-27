import XCTest
@testable import GastoCore

/// O app se identifica como ele mesmo nas chamadas de rede, nunca como outro cliente.
final class ProdutoTests: XCTestCase {
    func testUserAgentEDoTuttiDashENaoImitaOutroCliente() throws {
        XCTAssertEqual(Produto.userAgent, "TuttiDash/\(Produto.versao)")
        XCTAssertFalse(Produto.userAgent.localizedCaseInsensitiveContains("codexbar"))
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let dados = try Data(contentsOf: plist)
        let obj = try XCTUnwrap(PropertyListSerialization.propertyList(from: dados, format: nil) as? [String: Any])
        XCTAssertEqual(obj["CFBundleName"] as? String, Produto.nome)
        XCTAssertEqual(obj["CFBundleShortVersionString"] as? String, Produto.versao)
    }
}
