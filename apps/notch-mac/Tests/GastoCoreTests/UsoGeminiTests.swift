import Foundation
import XCTest
@testable import GastoCore

/// FRA-462: Gemini no catálogo, opt-in. A leitura do limite fica fora do TuttiDash aberto (FRA-565).
final class UsoGeminiTests: XCTestCase {
    private var repoAgentsD: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agents.d")
    }

    // MARK: Catálogo e opt-in

    func testCatalogoDoRepoExpoeGeminiOptIn() throws {
        let lidos = try CatalogoAgentes.ler(diretorio: repoAgentsD)
        let g = try XCTUnwrap(lidos.first { $0.nome == "gemini" })
        XCTAssertEqual(g.uso.tipo, "gemini")
        XCTAssertEqual(g.cli, "gemini")
        XCTAssertFalse(g.painel)
        XCTAssertTrue(g.optIn)
        let emb = try XCTUnwrap(Agentes.embutidos.first { $0.nome == "gemini" })
        XCTAssertTrue(emb.optIn)
        XCTAssertFalse(emb.painel)
        XCTAssertFalse(ClarezaCota.recebeCard(emb))
        XCTAssertEqual(ClarezaCota.detalhe(nome: "gemini"), ClarezaCota.detalheGemini)
    }

    func testGeminiNaoEntraNoPadraoMasPodeSerAdicionado() {
        XCTAssertTrue(Agentes.todos.contains { $0.nome == "gemini" && $0.optIn && !$0.painel })
        XCTAssertFalse(ContaUso.padrao.contains { $0.id == "gemini" || $0.tipo == "gemini" })
        XCTAssertTrue(ContaUso.todas.contains { $0.tipo == "gemini" })
        XCTAssertTrue(ContaUso.tipos.contains("gemini"))
        XCTAssertTrue(ContasConfig.tiposNovos.contains("gemini"))
        let atuais = ContaUso.padrao.map { ContaCadastro(conta: $0) }
        let rascunho = ContasConfig.rascunho(nas: atuais)
        XCTAssertEqual(rascunho.tipo, "gemini", "com as contas padrão já presentes, o tipo livre é gemini")
        let gemini = ContasConfig.aplicarTipo(rascunho, tipo: "gemini", nas: atuais + [rascunho])
        XCTAssertEqual(gemini.tipo, "gemini")
        XCTAssertNil(ContasConfig.problema(gemini, nas: atuais + [gemini]))
    }

}
