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

    /// O `tools/install.sh` numa instalação limpa deixa estes arquivos. `dispatcherExiste`
    /// olha só o dispatcher; a prontidão exige o conjunto (FRA-591).
    func testDispatcherExisteEInstalacaoPronta() throws {
        let t = try PastaTemp()
        XCTAssertFalse(LanesHabilitadas.dispatcherExiste(stateDir: t.url))
        XCTAssertFalse(LanesHabilitadas.instalacaoPronta(stateDir: t.url))
        try t.escrever("dispatcher.py", "# dispatcher\n")
        XCTAssertTrue(LanesHabilitadas.dispatcherExiste(stateDir: t.url))
        XCTAssertFalse(LanesHabilitadas.instalacaoPronta(stateDir: t.url))
        XCTAssertEqual(LanesHabilitadas.ausentes(stateDir: t.url),
                       ["run_lane.sh", "lane_view.py", "claude-settings.json", "lane-mcp.json"])
        for nome in ["run_lane.sh", "lane_view.py", "claude-settings.json", "lane-mcp.json"] {
            try t.escrever(nome, "{\n}\n")
        }
        XCTAssertTrue(LanesHabilitadas.dispatcherExiste(stateDir: t.url))
        XCTAssertTrue(LanesHabilitadas.instalacaoPronta(stateDir: t.url))
        XCTAssertTrue(LanesHabilitadas.ausentes(stateDir: t.url).isEmpty)
    }
}
