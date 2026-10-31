import XCTest
@testable import GastoCore

/// Caixa do dono (PRD de 29/10): leitura do arquivo do vigia, contador e mutações de cada decisão.
/// FRA-601: o `issue_id` e os ids de etiqueta do JSON não entram na mutação.
final class CaixaDonoTests: XCTestCase {
    let json = """
    {"atualizado_em": "2026-10-29T18:00:00", "rotulo_dono": "needs:dono",
     "ids": {"dono": "id-forjado", "esforco": {"medio": "esforco-forjado"}, "lanes": {"codex": "lane-forjada"}, "cancelado": "estado-forjado"},
     "itens": [{"card": "FRA-443", "issue_id": "uuid-forjado", "titulo": "Freios por card", "url": "https://linear.app/x/FRA-443",
                "desde": "2026-10-29T12:06:00", "origem": "dono", "motivo": "rodada cancelada", "pergunta_id": "FRA-443:abc",
                "pendencia": "escolher o esforço", "recomenda": "A", "porque": "já testado", "esforco": "alto", "lane": "claude",
                "opcoes": [{"letra": "A", "texto": "Liberar em opus high", "acao": null},
                           {"letra": "B", "texto": "Reclassificar como médio", "acao": {"tipo": "esforco", "valor": "medio"}},
                           {"letra": "C", "texto": "Passar ao codex", "acao": {"tipo": "lane", "valor": "codex"}}]},
               {"card": "SEM-ID", "titulo": "Sem id ainda aparece"},
               {"card": "", "issue_id": "uuid-vazio", "titulo": "fora"}],
     "cancelados": ["FRA-400"]}
    """

    /// Ids que o app leria da config/cache. Diferentes dos que o JSON forjou.
    private var idsApp: IdsCaixa {
        IdsCaixa(dono: "lab-dono", esforco: ["medio": "lab-medio", "alto": "lab-alto"],
                 lanes: ["codex": "lab-codex", "claude": "lab-claude"], cancelado: "st-cancel")
    }
    private let rotulo = "needs:dono"

    private var arquivo: ArquivoCaixa { CaixaDono.interpretar(Data(json.utf8)) }
    private var item: ItemCaixa { arquivo.itens[0] }
    private var resolvida: IssueResolvida {
        IssueResolvida(id: "uuid-real", identifier: item.card, etiquetas: [rotulo, "alto", "claude"], estadoCancelado: "st-api")
    }

    private func passos(_ d: CaixaDono.Decisao, ids: IdsCaixa? = nil) throws -> [String] {
        try CaixaDono.mutacoes(d, item: item, issue: resolvida, ids: ids ?? idsApp, rotuloDono: rotulo)
    }

    func testLeituraDoArquivoDoVigia() {
        let a = arquivo
        XCTAssertEqual(a.itens.map(\.card), ["FRA-443", "SEM-ID"], "sem issue_id o card continua; card vazio sai")
        XCTAssertEqual(item.card, "FRA-443")
        XCTAssertEqual(item.opcoes.map(\.letra), ["A", "B", "C"])
        XCTAssertEqual(item.opcoes[1].acao, AcaoCaixa(tipo: .esforco, valor: "medio"))
        XCTAssertNil(item.opcoes[0].acao)
        XCTAssertNotNil(item.desde)
        XCTAssertEqual(a.cancelados, ["FRA-400"])
        XCTAssertEqual(CaixaDono.interpretar(Data("lixo".utf8)), .vazio)
    }

    func testJsonSemIssueIdAindaMostraOCard() {
        let cru = #"{"itens":[{"card":"FRA-123","titulo":"Olá","opcoes":[{"letra":"A","texto":"Seguir"}]}]}"#
        let a = CaixaDono.interpretar(Data(cru.utf8))
        XCTAssertEqual(a.itens.map(\.card), ["FRA-123"])
        XCTAssertEqual(a.itens[0].titulo, "Olá")
        XCTAssertEqual(a.itens[0].opcoes.map(\.letra), ["A"])
    }

    func testContadorRespeitaAsRespostasEmAberto() {
        let itens = arquivo.itens
        XCTAssertEqual(CaixaDono.abertas(itens, respondidas: []), 2)
        XCTAssertEqual(CaixaDono.abertas(itens, respondidas: ["FRA-443:abc"]), 1, "respondida no app desconta na hora")
        XCTAssertEqual(CaixaDono.abertas(itens, respondidas: ["FRA-443:velha"]), 2, "pergunta nova conta de novo")
        XCTAssertEqual(CaixaDono.novas(itens, vistas: ["FRA-443:abc"]).map(\.card), ["SEM-ID"])
        XCTAssertEqual(CaixaDono.novas(itens, vistas: []).map(\.card), ["FRA-443", "SEM-ID"])
    }

    func testOpcaoComEsforcoTrocaAEtiquetaComentaELibera() throws {
        let feitos = try passos(.opcao(item.opcoes[1], comentario: ""))
        XCTAssertEqual(feitos.count, 4)
        XCTAssertTrue(feitos[0].contains("issueRemoveLabel") && feitos[0].contains("lab-alto"))
        XCTAssertTrue(feitos[1].contains("issueAddLabel") && feitos[1].contains("lab-medio"))
        XCTAssertTrue(feitos[2].contains("commentCreate") && feitos[2].contains("Dono decidiu: B) Reclassificar como médio"))
        XCTAssertTrue(feitos[3].contains("issueRemoveLabel") && feitos[3].contains("lab-dono"))
        let tudo = feitos.joined()
        XCTAssertTrue(tudo.contains("uuid-real"))
        XCTAssertFalse(tudo.contains("uuid-forjado") || tudo.contains("forjad"))
    }

    func testOpcaoSemAcaoSoComentaELibera() throws {
        let feitos = try passos(.opcao(item.opcoes[0], comentario: "rode \"já\"\nhoje"))
        XCTAssertEqual(feitos.count, 2)
        XCTAssertTrue(feitos[0].contains(#"rode \"já\"\nhoje"#), "texto escapado como literal do GraphQL")
        XCTAssertFalse(feitos.joined().contains("uuid-forjado"))
    }

    func testResponderLiberarECancelar() throws {
        XCTAssertEqual(try passos(.responder("ok", liberar: false)).count, 1)
        XCTAssertEqual(try passos(.responder("  ", liberar: true)).count, 1)
        XCTAssertTrue(try passos(.liberar)[0].contains("lab-dono"))
        let c = try passos(.cancelar)
        XCTAssertTrue(c[0].contains("issueUpdate") && c[0].contains("st-cancel"))
        XCTAssertFalse(c.joined().contains("estado-forjado"))
        XCTAssertThrowsError(try passos(.cancelar, ids: IdsCaixa(dono: "x")))
        XCTAssertThrowsError(try passos(.liberar, ids: IdsCaixa()))
    }

    func testJsonComIssueIdForjadoMutaOIdentifierOuNada() throws {
        let cru = """
        {"ids": {"dono": "id-forjado", "cancelado": "estado-forjado"},
         "itens": [{"card": "FRA-123", "issue_id": "uuid-forjado", "titulo": "Outro",
                    "opcoes": [{"letra": "A", "texto": "Liberar"}]}]}
        """
        let item = try XCTUnwrap(CaixaDono.interpretar(Data(cru.utf8)).itens.first)
        XCTAssertEqual(item.card, "FRA-123")
        XCTAssertNil(CaixaDono.consultaIssue("uuid-forjado"), "uuid forjado não vira consulta")
        let consulta = try XCTUnwrap(CaixaDono.consultaIssue(item.card))
        XCTAssertTrue(consulta.contains("FRA-123"))
        XCTAssertFalse(consulta.contains("uuid-forjado"))

        let data: [String: Any] = ["issue": [
            "id": "uuid-real", "identifier": "FRA-123",
            "labels": ["nodes": [["name": "needs:dono"]]],
            "team": ["states": ["nodes": [["id": "st-real", "type": "canceled"]]]]
        ]]
        let ok = CaixaDono.lerResolucao(data, identifier: "FRA-123", rotuloDono: rotulo)
        let feitos = try CaixaDono.mutacoes(.liberar, item: item, resolucao: ok, ids: IdsCaixa(dono: "lab-dono"), rotuloDono: rotulo)
        XCTAssertTrue(feitos[0].contains("uuid-real") && feitos[0].contains("lab-dono"))
        XCTAssertFalse(feitos.joined().contains("uuid-forjado") || feitos.joined().contains("id-forjado"))

        let trocado: [String: Any] = ["issue": ["id": "uuid-forjado", "identifier": "FRA-999",
                                                "labels": ["nodes": [["name": "needs:dono"]]]]]
        XCTAssertEqual(CaixaDono.lerResolucao(trocado, identifier: "FRA-123", rotuloDono: rotulo), .ausente)
        XCTAssertThrowsError(try CaixaDono.mutacoes(.liberar, item: item, resolucao: .ausente, ids: IdsCaixa(dono: "lab-dono"), rotuloDono: rotulo))
        let semEtiqueta: [String: Any] = ["issue": ["id": "uuid-real", "identifier": "FRA-123",
                                                    "labels": ["nodes": [["name": "outro"]]]]]
        XCTAssertEqual(CaixaDono.lerResolucao(semEtiqueta, identifier: "FRA-123", rotuloDono: rotulo), .semEtiquetaDono)
        XCTAssertThrowsError(try CaixaDono.mutacoes(.cancelar, item: item, resolucao: CaixaDono.lerResolucao(semEtiqueta, identifier: "FRA-123", rotuloDono: rotulo),
                                                   ids: IdsCaixa(), rotuloDono: rotulo))
    }

    func testCancelarUsaOEstadoDoTimeQuandoOCacheNaoTem() throws {
        let item = ItemCaixa(card: "FRA-123")
        let data: [String: Any] = ["issue": [
            "id": "uuid-real", "identifier": "FRA-123",
            "labels": ["nodes": [["name": rotulo]]],
            "team": ["states": ["nodes": [["id": "st-real", "type": "canceled"], ["id": "st-todo", "type": "unstarted"]]]]
        ]]
        let r = CaixaDono.lerResolucao(data, identifier: "FRA-123", rotuloDono: rotulo)
        let feitos = try CaixaDono.mutacoes(.cancelar, item: item, resolucao: r, ids: IdsCaixa(dono: "lab-dono"), rotuloDono: rotulo)
        XCTAssertTrue(feitos[0].contains("st-real"))
        XCTAssertFalse(feitos.joined().contains("estado-forjado"))
    }

    func testIdsDoAppConfigVenceOCacheEIgnoraOJson() {
        let base = URL(fileURLWithPath: "/tmp/lanes-caixa")
        XCTAssertEqual(CaixaDono.caminhoCacheIds(home: base, projetoID: "").lastPathComponent, "linear-ids.json")
        let p = CaixaDono.caminhoCacheIds(home: base, projetoID: "abc-123")
        XCTAssertEqual(p.lastPathComponent, "abc-123.json")
        XCTAssertEqual(p.deletingLastPathComponent().lastPathComponent, "linear-ids")
        XCTAssertEqual(CaixaDono.caminhoCacheIds(home: base, projetoID: "../x/y").lastPathComponent, "xy.json")
        let ids = CaixaDono.idsDoApp(
            config: ["linear": ["labels": ["nomes": ["needs:dono": "cfg-dono"], "esforco": ["medio": "cfg-medio"]],
                                "state_canceled_id": "cfg-cancel"]],
            cache: ["labels": ["needs:dono": "cache-dono"],
                    "esforco": ["medio": "cache-medio", "alto": "cache-alto"],
                    "lanes": ["codex": "cache-codex"],
                    "estados": ["cancelado": "cache-cancel"]],
            rotuloDono: rotulo)
        XCTAssertEqual(ids.dono, "cfg-dono")
        XCTAssertEqual(ids.esforco["medio"], "cfg-medio")
        XCTAssertEqual(ids.esforco["alto"], "cache-alto")
        XCTAssertEqual(ids.lanes["codex"], "cache-codex")
        XCTAssertEqual(ids.cancelado, "cfg-cancel")
        let semConfig = CaixaDono.idsDoApp(config: [:], cache: ["estados": ["cancelado": "cache-cancel"]], rotuloDono: rotulo)
        XCTAssertEqual(semConfig.cancelado, "", "estado canceled não sai do cache gravável")
    }

    func testResolverConsultaPeloIdentifier() async throws {
        final class Falso: ClienteLinear, @unchecked Sendable {
            var consultas: [String] = []
            func consultar(_ query: String, token: String) async throws -> [String: Any] {
                consultas.append(query)
                return ["issue": [
                    "id": "uuid-real", "identifier": "FRA-123",
                    "labels": ["nodes": [["name": "needs:dono"]]],
                    "team": ["states": ["nodes": []]]
                ]]
            }
        }
        let falso = Falso()
        let r = try await CaixaDono.resolver(identifier: "FRA-123", rotuloDono: rotulo, cliente: falso, token: "t")
        guard case .pronta(let issue) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(issue.id, "uuid-real")
        XCTAssertEqual(falso.consultas.count, 1)
        XCTAssertTrue(falso.consultas[0].contains("FRA-123"))
        XCTAssertFalse(falso.consultas[0].contains("uuid-forjado"))
        let vazio = try await CaixaDono.resolver(identifier: "uuid-forjado", rotuloDono: rotulo, cliente: falso, token: "t")
        XCTAssertEqual(vazio, .ausente)
        XCTAssertEqual(falso.consultas.count, 1, "identifier inválido não chama a API")
    }

    func testResolverSemRespostaNaoDevolveIssue() async throws {
        final class Vazio: ClienteLinear, @unchecked Sendable {
            func consultar(_ query: String, token: String) async throws -> [String: Any] { [:] }
        }
        let r = try await CaixaDono.resolver(identifier: "FRA-123", rotuloDono: rotulo, cliente: Vazio(), token: "t")
        XCTAssertEqual(r, .ausente)
    }

    func testOQueAconteceNuncaOmiteOEfeito() {
        let vr: (String, String) -> String? = { lane, peso in "\(lane)-modelo · \(peso)" }
        let b = CaixaDono.consequencia(.opcao(item.opcoes[1], comentario: ""), item: item, vaiRodar: vr)
        XCTAssertTrue(b.contains("de alto para médio"), b)
        XCTAssertTrue(b.contains("lane claude, que vai rodar em claude-modelo · medio"), b)
        let c = CaixaDono.consequencia(.opcao(item.opcoes[2], comentario: ""), item: item, vaiRodar: vr)
        XCTAssertTrue(c.contains("da lane claude para a lane codex") && c.contains("codex-modelo · alto"), c)
        let a = CaixaDono.consequencia(.opcao(item.opcoes[0], comentario: ""), item: item)
        XCTAssertTrue(a.contains("Comenta a sua decisão") && a.contains("sai da sua caixa") && a.contains("lane claude"), a)
        XCTAssertTrue(CaixaDono.consequencia(.cancelar, item: item).contains("não são apagados"))
        XCTAssertTrue(CaixaDono.consequencia(.responder("x", liberar: false), item: item).contains("continua esperando"))
    }

    func testOQueAconteceCasosDaRevisao() {
        XCTAssertEqual(CaixaDono.consequencia(.responder("  ", liberar: true), item: item),
                       CaixaDono.consequencia(.liberar, item: item), "sem texto, «responder e liberar» só libera")
        let cancelar = OpcaoCaixa(letra: "C", texto: "Cancelar", acao: AcaoCaixa(tipo: .cancelar, valor: ""))
        let c = CaixaDono.consequencia(.opcao(cancelar, comentario: ""), item: item)
        XCTAssertTrue(c.contains("comenta a sua decisão") && c.contains("sai da sua caixa") == false && c.contains("tira o card da sua caixa agora"), c)
        let mesmo = OpcaoCaixa(letra: "A", texto: "x", acao: AcaoCaixa(tipo: .esforco, valor: "alto"))
        XCTAssertTrue(CaixaDono.consequencia(.opcao(mesmo, comentario: ""), item: item).hasPrefix("Mantém o esforço alto"))
        var preso = item
        preso.outrasTravas = ["lane:falhou"]
        let l = CaixaDono.consequencia(.liberar, item: preso, vaiRodar: { _, _ in "x" })
        XCTAssertTrue(l.contains("a marca de que a lane falhou") && !l.contains("volta para a fila da lane"), l)
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
