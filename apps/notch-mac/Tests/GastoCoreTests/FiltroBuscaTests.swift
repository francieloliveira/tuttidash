import XCTest
@testable import GastoCore

final class FiltroBuscaTests: XCTestCase {
    func testVazioDeixaTudo() {
        XCTAssertTrue(FiltroBusca("   ").vazio)
        XCTAssertEqual(FiltroBusca("").filtrar([1, 2, 3]) { _ in [] }, [1, 2, 3])
    }

    func testIgnoraMaiusculasEAcentos() {
        let f = FiltroBusca("producao")
        XCTAssertTrue(f.casa(["Deploy em Produção"]))
        XCTAssertTrue(FiltroBusca("PRODUÇÃO").casa(["deploy em producao"]))
        XCTAssertFalse(f.casa(["homologação", nil]))
    }

    func testCadaPalavraEmQualquerCampo() {
        let campos: [String?] = ["FRA-563", "Ajustar listagens", "claude"]
        XCTAssertTrue(FiltroBusca("claude 563").casa(campos))
        XCTAssertTrue(FiltroBusca("listagens fra").casa(campos))
        XCTAssertFalse(FiltroBusca("claude grok").casa(campos))
    }
}
