import XCTest
@testable import GastoCore

final class NorteProjetoTests: XCTestCase {
    private let pid = "aaaaaaaa-0000-4000-8000-000000000002"
    private var pasta: URL!

    override func setUpWithError() throws {
        pasta = FileManager.default.temporaryDirectory.appendingPathComponent("norte-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pasta.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: pasta)
    }

    private func estado(norte: String, naMain: Bool) -> NorteProjeto.Estado {
        let p = ProjetoCadastro(projetoID: pid, repo: pasta.path, norte: norte)
        return NorteProjeto.estado(p, git: { _, args in
            XCTAssertTrue(args.last?.hasPrefix("origin/main:") == true)
            return Subprocesso.Resultado(codigo: naMain ? 0 : 1, saida: Data())
        })
    }

    func testQuatroEstadosPeloCadastroEPelaMain() {
        XCTAssertEqual(estado(norte: "docs/produto/caminho.md", naMain: true), .ativo)
        XCTAssertEqual(estado(norte: "", naMain: true), .importavel)
        XCTAssertEqual(estado(norte: "docs/produto/caminho.md", naMain: false), .aguardandoMerge)
        XCTAssertEqual(estado(norte: "", naMain: false), .falta)
    }

    func testSemPastaOuSemGit() {
        XCTAssertEqual(NorteProjeto.estado(ProjetoCadastro(projetoID: pid, repo: "")), .semPasta)
        let fora = ProjetoCadastro(projetoID: pid, repo: "/caminho/que/nao/existe")
        guard case .desconhecido = NorteProjeto.estado(fora) else { return XCTFail("sem .git não confere") }
    }

    func testRespostasPulamAsVazias() {
        let t = NorteProjeto.respostas(perguntas: ["Quem usa?", "O que nunca?"], respostas: ["Times pequenos.", "  "])
        XCTAssertEqual(t, "- Quem usa?\n  Times pequenos.")
    }

    func testProblemaBloqueiaPendenciaForaDoGlossario() {
        XCTAssertNotNil(NorteProjeto.problema("  "))
        let pendente = NorteProjeto.esqueleto.markdown(nome: "App")
        XCTAssertNotNil(NorteProjeto.problema(pendente))
        var r = NorteProjeto.esqueleto
        r.corpos = ["Um app.", "- R1: x", "1. y", "- z", NorteRascunho.aDefinir]
        XCTAssertNil(NorteProjeto.problema(r.markdown(nome: "App")), "glossário pode ficar a definir")
        r.corpos[1] = NorteRascunho.aDefinir
        XCTAssertNotNil(NorteProjeto.problema(r.markdown(nome: "App")))
    }

    func testComandoInstalarSoComScriptDoBundleEIdSeguro() {
        XCTAssertNil(NorteProjeto.comandoInstalar(projetoID: "-x", arquivoNorte: pasta))
        XCTAssertNil(NorteProjeto.comandoInstalar(projetoID: "", arquivoNorte: pasta))
        XCTAssertTrue(ScriptsDoBundle.relativos.contains("tools/instalar-norte"))
    }
}
