import XCTest
@testable import GastoCore

/// Lanes ACP (PRD lanes-acp): mesma leitura, validação e nome sugerido do Python.
final class LanesACPTests: XCTestCase {
    private var catalogo: [Agentes.Def] {
        Agentes.todos
    }

    private func dados(_ lanes: [[String: Any]]) -> [String: Any] {
        ["lanes": ["acp": lanes]]
    }

    func testOpenCodeFalaACPNoCatalogo() {
        XCTAssertTrue(LanesACP.agentesACP(catalogo).contains("opencode"))
        XCTAssertFalse(LanesACP.agentesACP(catalogo).contains("claude"))
    }

    func testLeituraValidaEPadroes() {
        let l = LanesACP.ler(dados([
            ["nome": "opencode-beam-free", "agente": "opencode", "modelo": "opencode/beam-free", "ligada": true],
            ["nome": "opencode-ds", "agente": "opencode", "modelo": "opencode/deepseek-v4.1-flash"],
        ]), catalogo: catalogo)
        XCTAssertEqual(l.map(\.nome), ["opencode-beam-free", "opencode-ds"])
        XCTAssertEqual(l[0].conta, "opencode", "conta padrão = agente")
        XCTAssertTrue(l[0].ligada)
        XCTAssertFalse(l[1].ligada, "ligada só com true explícito")
    }

    func testDescartaInvalidas() {
        let l = LanesACP.ler(dados([
            ["nome": "Maiuscula", "agente": "opencode"],
            ["nome": "claude", "agente": "opencode"],
            ["nome": "auto", "agente": "opencode"],
            ["nome": "sem-acp", "agente": "claude"],
            ["nome": "modelo-ruim", "agente": "opencode", "modelo": "x; rm -rf /"],
            ["nome": "ligada-numero", "agente": "opencode", "modelo": "opencode/x", "ligada": 1],
            ["nome": "repetida", "agente": "opencode"],
            ["nome": "repetida", "agente": "opencode"],
        ]), catalogo: catalogo)
        XCTAssertEqual(l.map(\.nome), ["ligada-numero", "repetida"])
        XCTAssertFalse(l[0].ligada, "1 não é true")
    }

    func testChavePlanaEGravacao() {
        var d: [String: Any] = ["lanes.acp": [["nome": "opencode-x", "agente": "opencode", "modelo": "opencode/x"]],
                                "outra": 1]
        XCTAssertEqual(LanesACP.ler(d, catalogo: catalogo).map(\.nome), ["opencode-x"])
        LanesACP.gravar([LaneACP(nome: "opencode-y", agente: "opencode", modelo: "opencode/y", ligada: true)], em: &d)
        XCTAssertNil(d["lanes.acp"])
        XCTAssertEqual(d["outra"] as? Int, 1)
        XCTAssertEqual(LanesACP.ler(d, catalogo: catalogo).map(\.nome), ["opencode-y"])
    }

    func testLimiteEPreco() {
        var d: [String: Any] = [:]
        XCTAssertNil(LanesACP.limite(conta: "opencode", d), "sem limite é o padrão")
        LanesACP.gravarLimite(3, conta: "opencode", em: &d)
        XCTAssertEqual(LanesACP.limite(conta: "opencode", d), 3)
        LanesACP.gravarLimite(0, conta: "opencode", em: &d)
        XCTAssertEqual(LanesACP.limite(conta: "opencode", d), 1)
        LanesACP.gravarLimite(nil, conta: "opencode", em: &d)
        XCTAssertNil(LanesACP.limite(conta: "opencode", d))
        XCTAssertNil(LanesACP.limite(conta: "x", ["lanes": ["limite_conta": ["x": true]]]))
        XCTAssertNil(LanesACP.preco(conta: "opencode", d))
        LanesACP.gravarPreco(20, conta: "opencode", em: &d)
        XCTAssertEqual(LanesACP.preco(conta: "opencode", d), 20)
        LanesACP.gravarPreco(nil, conta: "opencode", em: &d)
        XCTAssertNil(LanesACP.preco(conta: "opencode", d))
    }

    func testNomeSugeridoIgualAoPython() {
        XCTAssertEqual(LanesACP.nomeSugerido(agente: "opencode", modelo: "opencode/beam-free", catalogo: catalogo),
                       "opencode-beam-free")
        XCTAssertEqual(LanesACP.nomeSugerido(agente: "opencode", modelo: "opencode-go/DeepSeek V4.1 Flash", catalogo: catalogo),
                       "opencode-deepseek-v4-1-flash")
        XCTAssertEqual(LanesACP.nomeSugerido(agente: "opencode", modelo: "", catalogo: catalogo), "opencode-lane")
        XCTAssertEqual(LanesACP.nomeSugerido(agente: "opencode", modelo: "opencode/beam-free",
                                             usados: ["opencode-beam-free"], catalogo: catalogo),
                       "opencode-beam-free-2")
        let longo = LanesACP.nomeSugerido(agente: "opencode", modelo: "opencode/" + String(repeating: "x", count: 80),
                                          catalogo: catalogo)
        XCTAssertLessThanOrEqual(longo.count, 40)
        for nome in [longo, LanesACP.nomeSugerido(agente: "9", modelo: "/!!", catalogo: catalogo)] {
            XCTAssertNil(LanesACP.problema(LaneACP(nome: nome, agente: "opencode", modelo: ""), catalogo: catalogo), nome)
        }
    }

    func testModeloVazioEAutomatico() {
        let l = LanesACP.ler(dados([["nome": "opencode-auto", "agente": "opencode"]]), catalogo: catalogo)
        XCTAssertEqual(l.first?.modelo, LanesACP.modeloAuto)
        XCTAssertEqual(LanesACP.nomeSugerido(agente: "opencode", modelo: LanesACP.modeloAuto, catalogo: catalogo),
                       "opencode-auto")
        let porPeso = LanesACP.modelosPorPeso(agente: "opencode")
        XCTAssertFalse((porPeso["medio"] ?? "").isEmpty, "o automático tem um padrão (médio)")
        let d = LanesACP.defs(dados([["nome": "opencode-auto", "agente": "opencode", "modelo": "auto"]]), catalogo: catalogo)
        XCTAssertTrue(d.first?.rotulo.hasSuffix("· automático") == true)
    }

    func testDefsDaInstancia() {
        let defs = LanesACP.defs(dados([["nome": "opencode-beam-free", "agente": "opencode",
                                         "modelo": "opencode/beam-free"]]), catalogo: catalogo)
        XCTAssertEqual(defs.count, 1)
        let d = defs[0]
        let base = catalogo.first { $0.nome == "opencode" }!
        XCTAssertEqual(d.nome, "opencode-beam-free")
        XCTAssertEqual(d.rotulo, "\(base.rotulo) · beam-free")
        XCTAssertEqual(d.corBase, base.corBase)
        XCTAssertEqual(d.cli, base.cli)
        XCTAssertTrue(d.painel)
        XCTAssertTrue(ClarezaCota.recebeCard(d))
        XCTAssertEqual([d.agente, d.conta, d.modelo], ["opencode", "opencode", "opencode/beam-free"])
    }

    func testHabilitadasPelaConta() {
        let d = dados([
            ["nome": "opencode-a", "agente": "opencode", "modelo": "opencode/a", "ligada": true],
            ["nome": "opencode-b", "agente": "opencode", "modelo": "opencode/b"],
        ])
        XCTAssertEqual(LanesACP.habilitadas(d, contasAtivas: ["opencode"], catalogo: catalogo), ["opencode-a"])
        XCTAssertEqual(LanesACP.habilitadas(d, contasAtivas: ["claude"], catalogo: catalogo), [])
    }

    func testEnabledPreservaLanesACPDaConfig() throws {
        let t = try PastaTemp()
        try t.escrever("dispatcher.py", "# dispatcher")
        try LanesHabilitadas.gravar(["claude", "lane-que-nao-existe"], stateDir: t.url)
        XCTAssertEqual(LanesHabilitadas.ler(stateDir: t.url), ["claude"], "nome desconhecido continua fora")
    }
}
