import XCTest
@testable import GastoCore

final class EscolhasLinearTests: XCTestCase {
    let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
    var projeto: CampoLinear { CampoLinear.ondeTrabalha()[1] }

    func testNuncaMostraIdCru() {
        let soId: [String: Any] = ["linear": ["project_ios_id": uuid]]
        let n = EscolhasLinear.nomeExibido(projeto, em: soId)
        XCTAssertNotNil(n); XCTAssertFalse(n!.contains(uuid))
        let comNome: [String: Any] = ["linear": ["project_ios_id": uuid, "project_name": "App iOS"]]
        XCTAssertEqual(EscolhasLinear.nomeExibido(projeto, em: comNome), "App iOS")
        XCTAssertNil(EscolhasLinear.nomeExibido(projeto, em: [:]))
        XCTAssertEqual(EscolhasLinear.nomeExibido(CampoLinear.etiqueta(), em: ["linear": ["owner_label": "precisa:dono"]]), "precisa:dono")
    }

    func testValoresGuardamIdENome() {
        let v = EscolhasLinear.valores(projeto, ItemLinear(id: "p1", nome: "App"))
        XCTAssertEqual(v.map(\.0), ["linear.project_ios_id", "linear.project_name"]); XCTAssertEqual(v.map(\.1), ["p1", "App"])
        XCTAssertEqual(EscolhasLinear.valores(CampoLinear.etiqueta(), ItemLinear(id: "l", nome: "x")).map(\.1), ["x"])
    }

    func testTimeAutomaticoSoComUmTime() {
        let um = [ItemLinear(id: "t", nome: "Único")]
        XCTAssertEqual(EscolhasLinear.timeAutomatico(times: um, escolhido: nil)?.id, "t")
        XCTAssertEqual(EscolhasLinear.timeAutomatico(times: um, escolhido: "")?.id, "t")
        XCTAssertNil(EscolhasLinear.timeAutomatico(times: um, escolhido: "outro"))
        XCTAssertNil(EscolhasLinear.timeAutomatico(times: um + [ItemLinear(id: "u", nome: "B")], escolhido: nil))
    }

    func testNomesResolvidosPelaAPI() {
        let dados: [String: Any] = ["linear": ["project_ios_id": "p1", "state_in_progress_id": "s1", "state_in_progress_name": "Doing"]]
        let o = OpcoesTime(projetos: [ItemLinear(id: "p1", nome: "App")], estados: [ItemLinear(id: "s1", nome: "Em andamento")])
        let r = EscolhasLinear.nomesResolvidos(dados: dados, times: [], opcoes: o)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: r), ["linear.project_name": "App", "linear.state_in_progress_name": "Em andamento"])
    }

    func testRotulosEmLinguagemSimples() {
        XCTAssertEqual(CampoLinear.colunas().map(\.titulo), ["Coluna que dispara a lane", "Coluna de revisão"])
        XCTAssertTrue(CampoLinear.todos().allSatisfy { !$0.ajuda.isEmpty })
    }

    /// Fluxo: conectar (cliente falso) -> time único escolhido sozinho -> nomes gravados na config.
    func testFluxoConectarGravaNomes() async throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        let f = ClienteFalso()
        f.respostas = ["organization": ["urlKey": "acme"], "teams": ["nodes": [["id": "t1", "name": "Produto"]]]]
        let (_, times) = try await ServicoLinear(cliente: f).conectar(token: "ok")
        let time = try XCTUnwrap(EscolhasLinear.timeAutomatico(times: times, escolhido: m.valorTexto("linear.team_id")))
        for (k, v) in EscolhasLinear.valores(CampoLinear.ondeTrabalha()[0], time) { try m.definirValor(k, v) }
        let c = Configuracao.lerArquivo(ambiente: [:], home: t.url)
        XCTAssertEqual(Configuracao.valor("linear.team_id", em: c) as? String, "t1")
        XCTAssertEqual(EscolhasLinear.nomeExibido(CampoLinear.ondeTrabalha()[0], em: c), "Produto")
    }
}
