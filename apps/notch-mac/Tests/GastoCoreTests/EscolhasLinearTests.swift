import XCTest
@testable import GastoCore

final class EscolhasLinearTests: XCTestCase {
    var coluna: CampoLinear { CampoLinear.colunas()[0] }

    func testNuncaMostraIdCru() {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let soId: [String: Any] = ["linear": ["state_in_progress_id": uuid]]
        let n = EscolhasLinear.nomeExibido(coluna, em: soId)
        XCTAssertNotNil(n); XCTAssertFalse(n!.contains(uuid))
        let comNome: [String: Any] = ["linear": ["state_in_progress_id": uuid, "state_in_progress_name": "Doing"]]
        XCTAssertEqual(EscolhasLinear.nomeExibido(coluna, em: comNome), "Doing")
        XCTAssertNil(EscolhasLinear.nomeExibido(coluna, em: [:]))
        XCTAssertEqual(EscolhasLinear.nomeExibido(CampoLinear.etiqueta(), em: ["linear": ["owner_label": "precisa:dono"]]), "precisa:dono")
    }

    func testValoresGuardamIdENome() {
        let v = EscolhasLinear.valores(coluna, ItemLinear(id: "s1", nome: "Doing"))
        XCTAssertEqual(v.map(\.0), ["linear.state_in_progress_id", "linear.state_in_progress_name"])
        XCTAssertEqual(v.map(\.1), ["s1", "Doing"])
        XCTAssertEqual(EscolhasLinear.valores(CampoLinear.etiqueta(), ItemLinear(id: "l", nome: "x")).map(\.1), ["x"])
    }

    /// FRA-567: sem time nem projeto globais na tela de Ajustes.
    func testSemTimeNemProjetoGlobais() {
        let chaves = CampoLinear.todos().map(\.chave)
        XCTAssertFalse(chaves.contains("linear.team_id"))
        XCTAssertFalse(chaves.contains("linear.project_ios_id"))
    }

    /// As colunas vêm do time do projeto padrão do cadastro.
    func testTimeDasColunasVemDoProjetoPadrao() {
        let p1 = "aaaaaaaa-0000-4000-8000-000000000001", p2 = "aaaaaaaa-0000-4000-8000-000000000002"
        let lin = [ProjetoLinear(id: p1, nome: "App", timeID: "t1"), ProjetoLinear(id: p2, nome: "Web", timeID: "t2")]
        let cad = [ProjetoCadastro(projetoID: p1, repo: "~/a"), ProjetoCadastro(projetoID: p2, padrao: true, repo: "~/b")]
        XCTAssertEqual(EscolhasLinear.timeDasColunas(projetos: lin, cadastro: cad), "t2")
        XCTAssertNil(EscolhasLinear.timeDasColunas(projetos: lin, cadastro: []))
        XCTAssertNil(EscolhasLinear.timeDasColunas(projetos: [], cadastro: cad))
    }

    func testNomesResolvidosPelaAPI() {
        let dados: [String: Any] = ["linear": ["state_in_progress_id": "s1", "state_in_progress_name": "Doing"]]
        let o = OpcoesTime(estados: [ItemLinear(id: "s1", nome: "Em andamento")])
        let r = EscolhasLinear.nomesResolvidos(dados: dados, times: [], opcoes: o)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: r), ["linear.state_in_progress_name": "Em andamento"])
    }

    func testRotulosEmLinguagemSimples() {
        XCTAssertEqual(CampoLinear.colunas().map(\.titulo), ["Coluna que dispara a lane", "Coluna de revisão"])
        XCTAssertTrue(CampoLinear.todos().allSatisfy { !$0.ajuda.isEmpty })
    }

    /// Fluxo: escolher a coluna grava id e nome na config, e a tela mostra o nome.
    func testEscolhaGravaNomes() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        for (k, v) in EscolhasLinear.valores(coluna, ItemLinear(id: "s1", nome: "Doing")) { try m.definirValor(k, v) }
        let c = Configuracao.lerArquivo(ambiente: [:], home: t.url)
        XCTAssertEqual(Configuracao.valor("linear.state_in_progress_id", em: c) as? String, "s1")
        XCTAssertEqual(EscolhasLinear.nomeExibido(coluna, em: c), "Doing")
    }
}
