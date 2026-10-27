import XCTest
@testable import GastoCore

final class LanesHabilitadasTests: XCTestCase {
    func testSemArquivoVazio() throws {
        let t = try PastaTemp()
        XCTAssertEqual(LanesHabilitadas.ler(stateDir: t.url), [])
    }

    func testLeituraIncluiGrokComAsOutrasLanes() throws {
        let t = try PastaTemp()
        try t.escrever("enabled", "claude codex opencode opencode-go grok\n")
        XCTAssertEqual(LanesHabilitadas.ler(stateDir: t.url),
                       ["claude", "codex", "opencode", "opencode-go", "grok"])
    }

    func testIdaEVoltaPreservaOrdemDoRegistry() throws {
        let t = try PastaTemp()
        try t.escrever("dispatcher.py", "# dispatcher")
        try LanesHabilitadas.gravar(["opencode", "claude", "umanova"], stateDir: t.url)
        XCTAssertEqual(LanesHabilitadas.ler(stateDir: t.url), ["claude", "opencode"])
        let texto = try String(contentsOf: LanesHabilitadas.arquivo(stateDir: t.url), encoding: .utf8)
        XCTAssertEqual(texto, "claude opencode\n")
    }
}
