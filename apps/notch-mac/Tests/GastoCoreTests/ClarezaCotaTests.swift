import XCTest
@testable import GastoCore

/// SuperGrok (via Cursor) e Grok CLI são contas e cotas diferentes. A UI diz isso;
/// o arquivo `enabled`, o billing e o dispatcher não entram aqui.
final class ClarezaCotaTests: XCTestCase {
    private var repoAgentsD: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agents.d")
    }

    func testCursorNaoPegaCardEGrokCLIPega() throws {
        let cursor = try XCTUnwrap(Agentes.embutidos.first { $0.nome == "cursor" })
        let grok = try XCTUnwrap(Agentes.embutidos.first { $0.nome == "grok" })
        XCTAssertFalse(ClarezaCota.recebeCard(cursor))
        XCTAssertTrue(ClarezaCota.contaDeUso(cursor))
        XCTAssertNil(cursor.cli)
        XCTAssertFalse(cursor.painel)
        XCTAssertTrue(ClarezaCota.recebeCard(grok))
        XCTAssertFalse(ClarezaCota.contaDeUso(grok))
        XCTAssertEqual(grok.cli, "grok")

        let lanes = Agentes.embutidos.filter(ClarezaCota.recebeCard).map(\.nome)
        let uso = Agentes.embutidos.filter(ClarezaCota.contaDeUso).map(\.nome)
        XCTAssertFalse(lanes.contains("cursor"))
        XCTAssertTrue(lanes.contains("grok"))
        XCTAssertEqual(uso, ["cursor", "gemini", "copilot"])
        XCTAssertFalse(lanes.contains("gemini"))
        XCTAssertFalse(lanes.contains("copilot"))
        XCTAssertEqual(Set(lanes).union(uso).count, Agentes.embutidos.count)
    }

    func testManifestoEFallbackUsamOMesmoNome() throws {
        let lidos = try CatalogoAgentes.ler(diretorio: repoAgentsD)
        let cursor = try XCTUnwrap(lidos.first { $0.nome == "cursor" })
        let grok = try XCTUnwrap(lidos.first { $0.nome == "grok" })
        XCTAssertEqual(cursor.rotulo, ClarezaCota.tituloSuperGrok)
        XCTAssertEqual(grok.rotulo, ClarezaCota.tituloGrokCLI)
        XCTAssertEqual(Agentes.embutidos.first { $0.nome == "cursor" }?.rotulo, ClarezaCota.tituloSuperGrok)
        XCTAssertEqual(Agentes.embutidos.first { $0.nome == "grok" }?.rotulo, ClarezaCota.tituloGrokCLI)
        XCTAssertFalse(cursor.painel)
        XCTAssertTrue(grok.painel)
    }

    func testTextosSeparamAsDuasCotas() {
        let grok = ClarezaCota.linha(nome: "grok", rotulo: "Grok CLI")
        XCTAssertEqual(grok.titulo, "Grok CLI")
        XCTAssertEqual(grok.detalhe, ClarezaCota.detalheGrokCLI)
        XCTAssertTrue(grok.detalhe!.contains("terminal"))
        XCTAssertTrue(grok.detalhe!.contains("separados do SuperGrok"))

        let cursor = ClarezaCota.linha(nome: "cursor", rotulo: "Cursor")
        XCTAssertEqual(cursor.titulo, "Grok Bot / SuperGrok (via Cursor)")
        XCTAssertEqual(cursor.detalhe, ClarezaCota.detalheSuperGrok)
        XCTAssertTrue(cursor.detalhe!.contains("Não pega card"))
        XCTAssertTrue(cursor.detalhe!.contains("separada do Grok CLI"))

        XCTAssertEqual(ClarezaCota.linha(nome: "claude", rotulo: "Claude Code").titulo, "Claude Code")
        XCTAssertNil(ClarezaCota.detalhe(nome: "claude"))

        XCTAssertTrue(ClarezaCota.ajudaLanesLigadas.contains("recebem cards novos"))
        XCTAssertTrue(ClarezaCota.ajudaLanesLigadas.contains("não interrompe o card que já está rodando"))
        XCTAssertFalse(ClarezaCota.ajudaLanesLigadas.contains("SuperGrok"),
                       "a ajuda da lista não é rodapé e não mistura a conta de uso")
        XCTAssertTrue(ClarezaCota.ajudaUsoSuperGrok.contains("não recebe card"))
        XCTAssertTrue(ClarezaCota.ajudaUsoSuperGrok.contains("não muda o % do SuperGrok"))
        XCTAssertTrue(ClarezaCota.ajudaUsoSuperGrok.contains("cotas e créditos separados"))
        XCTAssertTrue(ClarezaCota.ajudaUsoSuperGrok.contains("cota Sand"))
        XCTAssertTrue(ClarezaCota.ajudaUsoSuperGrok.contains("não tem interruptor"))
        XCTAssertEqual(ClarezaCota.tituloSecaoUso(nomes: ["cursor"]), "Uso do SuperGrok")
        XCTAssertEqual(ClarezaCota.tituloSecaoUso(nomes: ["cursor", "outra"]), "Contas de uso")
        XCTAssertEqual(ClarezaCota.seloNaoELane, "não é lane")
    }

    func testNomeCurtoNaoMisturaCursorComGrokCLI() {
        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "cursor", nome: "cursor", rotulo: "Cursor"), "SuperGrok")
        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "cursor", nome: "Cursor", rotulo: "Cursor"), "SuperGrok")
        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "cursor", nome: "", rotulo: "Cursor"), "SuperGrok")
        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "cursor", nome: "bot", rotulo: "Bot"), "bot")

        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "grok", nome: "grok", rotulo: "Grok CLI"), "Grok CLI")
        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "grok", nome: "", rotulo: "Grok CLI"), "Grok CLI")
        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "grok", nome: "GRK", rotulo: "x"), "GRK")

        XCTAssertEqual(ClarezaCota.nomeCurto(tipo: "claude", nome: "claude", rotulo: "Claude Code"), "claude")
    }

    func testRotuloDeContaPreservaApelido() {
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "cursor", rotuloSalvo: "Cursor"), ClarezaCota.tituloSuperGrok)
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "cursor", rotuloSalvo: "cursor"), ClarezaCota.tituloSuperGrok)
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "cursor", rotuloSalvo: ""), ClarezaCota.tituloSuperGrok)
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "cursor", rotuloSalvo: "Bot"), "Bot")
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "cursor", rotuloSalvo: ClarezaCota.tituloSuperGrok), ClarezaCota.tituloSuperGrok)

        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "grok", rotuloSalvo: "Grok CLI"), "Grok CLI")
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "grok", rotuloSalvo: "grok"), "Grok CLI")
        XCTAssertEqual(ClarezaCota.rotuloConta(tipo: "grok", rotuloSalvo: "meu grok"), "meu grok")

        XCTAssertEqual(ClarezaCota.rotuloAjuda(tipo: "cursor", rotulo: "Cursor"), ClarezaCota.tituloSuperGrok)
        XCTAssertEqual(ClarezaCota.notaCota("cursor"), ClarezaCota.notaSuperGrok)
        XCTAssertEqual(ClarezaCota.notaCota("grok"), ClarezaCota.notaGrokCLI)
        XCTAssertNil(ClarezaCota.notaCota("claude"))
        XCTAssertTrue(ClarezaCota.notaSuperGrok.contains("Não compartilha cota nem crédito com o Grok CLI"))
        XCTAssertTrue(ClarezaCota.notaGrokCLI.contains("separados do SuperGrok"))
    }

    func testListaDeLanesLigadasEUniforme() throws {
        let lanes = Agentes.embutidos.filter(ClarezaCota.recebeCard)
        XCTAssertEqual(lanes.map(\.nome), ["claude", "codex", "opencode", "opencode-go", "grok"])
        let linhas = lanes.map(ClarezaCota.linhaLista)
        XCTAssertEqual(linhas.map(\.detalhe), [nil, nil, nil, nil, nil])
        XCTAssertEqual(linhas.map(\.titulo), ["Claude Code", "Codex", "OpenCode", "OpenCode Go", "Grok CLI"])
        let cursor = try XCTUnwrap(Agentes.embutidos.first { $0.nome == "cursor" })
        XCTAssertFalse(ClarezaCota.recebeCard(cursor))
        XCTAssertNotNil(ClarezaCota.linhaLane(cursor).detalhe)
        XCTAssertNil(ClarezaCota.linhaLista(lanes[4]).detalhe)
        XCTAssertEqual(ClarezaCota.detalhe(nome: "grok"), ClarezaCota.detalheGrokCLI)
    }

    func testAjustesExplicamASeparacaoNoCabecalho() {
        let lanes = CatalogoAjustes.secoes().first { $0.id == .lanes }!
        XCTAssertTrue(lanes.subtitulo.contains("pegam card"))
        let contas = CatalogoAjustes.secoes().first { $0.id == .contas }!
        let grupo = contas.grupos.first { $0.nome == "Contas das lanes" }
        XCTAssertEqual(grupo?.ajuda, "Quanto de cada conta já foi usado. SuperGrok (via Cursor) e Grok CLI são cotas separadas.")
    }
}
