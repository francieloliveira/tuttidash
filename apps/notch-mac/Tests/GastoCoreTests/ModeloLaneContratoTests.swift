import XCTest
@testable import GastoCore

/// Contrato com o Python (`tests/fixtures/resolucao_modelo.json`, PRD de 29/10): mesma config,
/// peso e cache dão o mesmo modelo, esforço e aviso no app e no dispatcher.
final class ModeloLaneContratoTests: XCTestCase {
    private var fixture: [String: Any] = [:]
    private var agentes: [String: CatalogoAgentes.ModeloAgente] = [:]

    override func setUpWithError() throws {
        let url = Fixtures.raizRepo.appendingPathComponent("tests/fixtures/resolucao_modelo.json")
        fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let lidos = CatalogoAgentes.carregar(caminhos: [Fixtures.raizRepo.appendingPathComponent("agents.d")])
        agentes = Dictionary(uniqueKeysWithValues: lidos.map { ($0.nome, $0) })
    }

    private func cache(_ v: Any?) throws -> CacheModelos {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try JSONSerialization.data(withJSONObject: v ?? [:]).write(to: tmp)
        return ListaModelos.ler(tmp)
    }

    private func conferir(_ grupo: String, cache c: CacheModelos) throws {
        let casos = try XCTUnwrap(fixture[grupo] as? [[String: Any]])
        XCTAssertFalse(casos.isEmpty)
        for caso in casos {
            let nome = caso["nome"] as? String ?? "?"
            let lane = try XCTUnwrap(caso["lane"] as? String)
            let agente = try XCTUnwrap(agentes[lane], "agente \(lane)")
            let bruto: Any? = (caso["config"] is NSNull) ? nil : caso["config"]
            let r = ModeloLane.resolver(lane: lane, peso: try XCTUnwrap(caso["peso"] as? String),
                                        config: ModeloLane.ler(bruto), padrao: ModeloLane.padrao(agente),
                                        cache: c, agente: agente)
            let esperado = try XCTUnwrap(caso["esperado"] as? [String: String])
            XCTAssertEqual(r.modelo, esperado["modelo"], "\(nome): modelo")
            XCTAssertEqual(r.esforco, esperado["esforco"], "\(nome): esforço")
            XCTAssertEqual(r.aviso, esperado["aviso"], "\(nome): aviso")
        }
    }

    func testContratoComCache() throws {
        try conferir("casos", cache: try cache(fixture["cache"]))
    }

    func testContratoSemCache() throws {
        try conferir("sem_cache", cache: .vazio)
    }

    func testEsforcosDoHelpDoClaude() {
        let texto = "  --effort <level>     Effort level for the current session\n" +
            "                        (low, medium, high, xhigh, max)\n  --environment <id>  x\n"
        XCTAssertEqual(ListaModelos.esforcosDoHelp(texto), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ListaModelos.esforcosDoHelp("sem a flag"), [])
        XCTAssertEqual(ListaModelos.esforcosDoHelp("--effort-mode (a, b)\n  --effort <n>  x (low, high)"), ["low", "high"])
        XCTAssertEqual(ListaModelos.esforcosDoHelp("--effortless (a)"), [])
    }

    func testEsforcosDoCacheDoCodex() throws {
        let obj: [String: Any] = ["models": [
            ["slug": "gpt-5.6-luna", "visibility": "list",
             "supported_reasoning_levels": [["effort": "low"], ["effort": "high"], ["effort": "max"]]],
            ["slug": "oculto", "visibility": "hidden", "supported_reasoning_levels": [["effort": "low"]]],
            ["slug": "sem-nivel", "visibility": "list"]]]
        XCTAssertEqual(ListaModelos.esforcosCacheCodex(try JSONSerialization.data(withJSONObject: obj)),
                       ["gpt-5.6-luna": ["low", "high", "max"]])
    }

    func testCacheGuardaOsEsforcos() throws {
        var c = CacheModelos.vazio
        c.esforcos["claude"] = ["*": ["low", "max"]]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ListaModelos.gravar(c, em: tmp)
        XCTAssertEqual(ListaModelos.ler(tmp).esforcos["claude"], ["*": ["low", "max"]])
        let novo = ListaModelos.atualizar([], cache: c, agora: "x", rodar: { _ in nil },
                                          claude: { .ok([]) }, codex: { .ok([]) }, pode: { _ in [:] })
        XCTAssertEqual(novo.cache.esforcos["claude"], ["*": ["low", "max"]], "sem busca, o que havia fica")
    }

    func testEsforcoDoFixoVaiEVolta() {
        let cfg = ModeloLane.ler(["modo": "fixo", "fixo": "opus", "esforco": "medium"])
        XCTAssertEqual(cfg.esforcoFixo, "medium")
        XCTAssertEqual(ModeloLane.paraGravar(cfg)["esforco"] as? String, "medium")
        XCTAssertNil(ModeloLane.paraGravar(ModeloLane.ler(["modo": "fixo", "fixo": "opus"]))["esforco"])
    }

    func testAjustarEsforcoQuandoOModeloMuda() throws {
        let claude = try XCTUnwrap(agentes["claude"])
        var cache = CacheModelos.vazio
        cache.esforcos["claude"] = ["haiku": ["low", "medium"], "*": ["low", "medium", "high", "xhigh", "max"]]
        var cfg = ConfigModelo.automatico
        cfg.porPeso["alto"] = EscolhaPeso(modelo: "haiku", esforco: "xhigh", esforcoExplicito: true)
        cfg.porPeso["medio"] = EscolhaPeso(modelo: "", esforco: "max", esforcoExplicito: true)
        let (novo, aviso) = ModeloLane.ajustarEsforco(cfg, agente: claude, cache: cache)
        XCTAssertEqual(novo.porPeso["alto"], EscolhaPeso(modelo: "haiku", esforco: "", esforcoExplicito: false))
        XCTAssertEqual(novo.porPeso["medio"]?.esforco, "max", "opus aceita max")
        XCTAssertNotNil(aviso)
        var fixo = ConfigModelo(modo: .fixo, fixo: "haiku", porPeso: [:], aviso: "", esforcoFixo: "max")
        fixo = ModeloLane.ajustarEsforco(fixo, agente: claude, cache: cache).0
        XCTAssertEqual(fixo.esforcoFixo, "")
        XCTAssertNil(ModeloLane.ajustarEsforco(novo, agente: claude, cache: cache).1, "sem mudança, sem aviso")
    }

    func testLaneSemEsforco() throws {
        XCTAssertFalse(ModeloLane.temEsforco(agentes["opencode"]))
        XCTAssertTrue(ModeloLane.temEsforco(agentes["claude"]))
        XCTAssertEqual(ModeloLane.esforcosAceitos(lane: "opencode", modelo: "opencode/x",
                                                 agente: agentes["opencode"], cache: .vazio), [])
    }
}
