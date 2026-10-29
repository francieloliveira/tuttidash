import XCTest
@testable import GastoCore

/// Caixa do dono (PRD de 29/10): leitura do arquivo do vigia, contador e mutações de cada decisão.
final class CaixaDonoTests: XCTestCase {
    let json = """
    {"atualizado_em": "2026-10-29T18:00:00", "rotulo_dono": "needs:dono",
     "ids": {"dono": "lab-dono", "esforco": {"medio": "lab-medio", "alto": "lab-alto"}, "lanes": {"codex": "lab-codex", "claude": "lab-claude"}, "cancelado": "st-cancel"},
     "itens": [{"card": "FRA-443", "issue_id": "uuid-443", "titulo": "Freios por card", "url": "https://linear.app/x/FRA-443",
                "desde": "2026-10-29T12:06:00", "origem": "dono", "motivo": "rodada cancelada", "pergunta_id": "FRA-443:abc",
                "pendencia": "escolher o esforço", "recomenda": "A", "porque": "já testado", "esforco": "alto", "lane": "claude",
                "opcoes": [{"letra": "A", "texto": "Liberar em opus high", "acao": null},
                           {"letra": "B", "texto": "Reclassificar como médio", "acao": {"tipo": "esforco", "valor": "medio"}},
                           {"letra": "C", "texto": "Passar ao codex", "acao": {"tipo": "lane", "valor": "codex"}}]},
               {"card": "SEM-ID", "issue_id": ""}],
     "cancelados": ["FRA-400"]}
    """

    private var arquivo: ArquivoCaixa { CaixaDono.interpretar(Data(json.utf8)) }
    private var item: ItemCaixa { arquivo.itens[0] }

    func testLeituraDoArquivoDoVigia() {
        let a = arquivo
        XCTAssertEqual(a.itens.count, 1, "item sem issue_id é descartado")
        XCTAssertEqual(item.card, "FRA-443")
        XCTAssertEqual(item.opcoes.map(\.letra), ["A", "B", "C"])
        XCTAssertEqual(item.opcoes[1].acao, AcaoCaixa(tipo: .esforco, valor: "medio"))
        XCTAssertNil(item.opcoes[0].acao)
        XCTAssertNotNil(item.desde)
        XCTAssertEqual(a.ids.cancelado, "st-cancel")
        XCTAssertEqual(a.cancelados, ["FRA-400"])
        XCTAssertEqual(CaixaDono.interpretar(Data("lixo".utf8)), .vazio)
    }

    func testContadorRespeitaAsRespostasEmAberto() {
        let itens = arquivo.itens
        XCTAssertEqual(CaixaDono.abertas(itens, respondidas: []), 1)
        XCTAssertEqual(CaixaDono.abertas(itens, respondidas: ["FRA-443:abc"]), 0, "respondida no app desconta na hora")
        XCTAssertEqual(CaixaDono.abertas(itens, respondidas: ["FRA-443:velha"]), 1, "pergunta nova conta de novo")
        XCTAssertEqual(CaixaDono.novas(itens, vistas: ["FRA-443:abc"]).count, 0)
        XCTAssertEqual(CaixaDono.novas(itens, vistas: []).map(\.card), ["FRA-443"])
    }

    func testOpcaoComEsforcoTrocaAEtiquetaComentaELibera() throws {
        let passos = try CaixaDono.mutacoes(.opcao(item.opcoes[1], comentario: ""), item: item, ids: arquivo.ids)
        XCTAssertEqual(passos.count, 4)
        XCTAssertTrue(passos[0].contains("issueRemoveLabel") && passos[0].contains("lab-alto"))
        XCTAssertTrue(passos[1].contains("issueAddLabel") && passos[1].contains("lab-medio"))
        XCTAssertTrue(passos[2].contains("commentCreate") && passos[2].contains("Dono decidiu: B) Reclassificar como médio"))
        XCTAssertTrue(passos[3].contains("issueRemoveLabel") && passos[3].contains("lab-dono"))
    }

    func testOpcaoSemAcaoSoComentaELibera() throws {
        let passos = try CaixaDono.mutacoes(.opcao(item.opcoes[0], comentario: "rode \"já\"\nhoje"), item: item, ids: arquivo.ids)
        XCTAssertEqual(passos.count, 2)
        XCTAssertTrue(passos[0].contains(#"rode \"já\"\nhoje"#), "texto escapado como literal do GraphQL")
    }

    func testResponderLiberarECancelar() throws {
        XCTAssertEqual(try CaixaDono.mutacoes(.responder("ok", liberar: false), item: item, ids: arquivo.ids).count, 1)
        XCTAssertEqual(try CaixaDono.mutacoes(.responder("  ", liberar: true), item: item, ids: arquivo.ids).count, 1)
        XCTAssertTrue(try CaixaDono.mutacoes(.liberar, item: item, ids: arquivo.ids)[0].contains("lab-dono"))
        let c = try CaixaDono.mutacoes(.cancelar, item: item, ids: arquivo.ids)
        XCTAssertTrue(c[0].contains("issueUpdate") && c[0].contains("st-cancel"))
        XCTAssertThrowsError(try CaixaDono.mutacoes(.cancelar, item: item, ids: IdsCaixa(dono: "x")))
        XCTAssertThrowsError(try CaixaDono.mutacoes(.liberar, item: item, ids: IdsCaixa()))
    }

    func testExecutarParaNoPrimeiroErro() async throws {
        final class Falso: ClienteLinear, @unchecked Sendable {
            var feitas: [String] = []
            let falhaEm: Int
            init(falhaEm: Int) { self.falhaEm = falhaEm }
            func consultar(_ query: String, token: String) async throws -> [String: Any] {
                feitas.append(query)
                return ["x": ["success": feitas.count != falhaEm]]
            }
        }
        let ok = Falso(falhaEm: 99)
        try await CaixaDono.executar(["a", "b"], cliente: ok, token: "t")
        XCTAssertEqual(ok.feitas, ["a", "b"])
        let ruim = Falso(falhaEm: 1)
        do { try await CaixaDono.executar(["a", "b"], cliente: ruim, token: "t"); XCTFail("devia falhar") } catch {}
        XCTAssertEqual(ruim.feitas, ["a"])
    }
}
