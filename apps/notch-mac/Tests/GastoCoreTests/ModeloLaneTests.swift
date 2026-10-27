import XCTest
@testable import GastoCore

final class ModeloLaneTests: XCTestCase {
    private func catalogo() -> [CatalogoAgentes.ModeloAgente] {
        CatalogoAgentes.carregar(caminhos: [Fixtures.raizRepo.appendingPathComponent("agents.d")])
    }

    private func agente(_ nome: String) -> CatalogoAgentes.ModeloAgente {
        catalogo().first { $0.nome == nome }!
    }

    func testTextoDoPainelLevaLaneModeloEPeso() {
        XCTAssertEqual(ModeloLane.textoPainel(lane: "claude", modelo: "sonnet", peso: "alto"),
                       "claude · sonnet (alto)")
        XCTAssertEqual(ModeloLane.textoPainel(lane: "claude", modelo: "opus", peso: "medio"),
                       "claude · opus (médio)")
        XCTAssertEqual(ModeloLane.textoPainel(lane: "grok", modelo: "", peso: "baixo"),
                       "grok · padrão do CLI (baixo)")
    }

    func testFormatoAntigoStringEFixo() {
        let lido = ModeloLane.ler("grok-4.7")
        XCTAssertEqual(lido.modo, .fixo)
        XCTAssertEqual(lido.fixo, "grok-4.7")
        let r = ModeloLane.resolver(lane: "grok", peso: "alto", config: lido, padrao: [:], cache: .vazio)
        XCTAssertEqual(r.modelo, "grok-4.7")
        XCTAssertTrue(r.fixo)
        XCTAssertEqual(r.aviso, "modelo fixo")
    }

    func testAutoPorPesoEscolheOModeloDoCard() {
        let cfg = ConfigModelo(modo: .auto, fixo: "", porPeso: [
            "baixo": EscolhaPeso(modelo: "haiku", esforco: "low", esforcoExplicito: true),
            "alto": EscolhaPeso(modelo: "opus", esforco: "xhigh", esforcoExplicito: true),
        ], aviso: "")
        let padrao = ModeloLane.padrao(agente("claude"))
        let baixo = ModeloLane.resolver(lane: "claude", peso: "baixo", config: cfg, padrao: padrao, cache: .vazio)
        let alto = ModeloLane.resolver(lane: "claude", peso: "alto", config: cfg, padrao: padrao, cache: .vazio)
        XCTAssertEqual(baixo.modelo, "haiku")
        XCTAssertFalse(baixo.fixo)
        XCTAssertEqual(alto.modelo, "opus")
        XCTAssertEqual(ModeloLane.esforco(das: agente("claude").flags("alto")), "xhigh")
    }

    func testFixoValeParaTodosOsPesos() {
        let cfg = ConfigModelo(modo: .fixo, fixo: "sonnet", porPeso: [
            "baixo": EscolhaPeso(modelo: "haiku", esforco: "low", esforcoExplicito: true),
        ], aviso: "")
        for peso in ModeloLane.pesos {
            let r = ModeloLane.resolver(lane: "claude", peso: peso, config: cfg, padrao: [:], cache: .vazio)
            XCTAssertEqual(r.modelo, "sonnet", peso)
            XCTAssertTrue(r.fixo)
            XCTAssertEqual(r.aviso, "modelo fixo")
        }
    }

    func testModeloSumidoVoltaAoAutomatico() {
        let cache = CacheModelos(atualizadoEm: "t",
                                 listas: ["claude": ["opus", "sonnet"]],
                                 anteriores: ["claude": ["opus", "sonnet", "haiku"]])
        let cfg = ConfigModelo(modo: .fixo, fixo: "haiku", porPeso: [:], aviso: "")
        let padrao = ["alto": EscolhaPeso(modelo: "opus", esforco: "xhigh", esforcoExplicito: false)]
        let r = ModeloLane.resolver(lane: "claude", peso: "alto", config: cfg, padrao: padrao, cache: cache)
        XCTAssertEqual(r.modelo, "opus")
        XCTAssertFalse(r.fixo)
        XCTAssertTrue(r.aviso.contains("voltou ao automático"))
        let novo = ModeloLane.reconciliar(cfg, lane: "claude", padrao: padrao, cache: cache)
        XCTAssertEqual(novo.modo, .auto)
        XCTAssertTrue(novo.aviso.contains("saiu da lista"))
    }

    func testFiltroDePrivacidadeEPrefixo() {
        let linhas = ["opencode/deepseek-v4.1-flash-free", "opencode/nemotron-3.5",
                      "opencode-go/deepseek-v4.1-flash", "anthropic/claude"]
        let pode: (String) -> Bool = { !$0.contains("nemotron") }
        let out = ListaModelos.filtrar(lane: "opencode", linhas: linhas, prefixo: "opencode/",
                                       privado: true, pode: pode)
        XCTAssertEqual(out, ["opencode/deepseek-v4.1-flash-free"])
        XCTAssertEqual(ListaModelos.filtrar(lane: "opencode", linhas: linhas, prefixo: "opencode/",
                                            privado: true, pode: nil), [])
        XCTAssertEqual(agente("opencode").privacidade, "opencode")
        XCTAssertEqual(agente("opencode-go").privacidade, "opencode")
        XCTAssertNil(agente("claude").privacidade)
        XCTAssertNil(agente("grok").privacidade)
    }

    func testCacheGuardaAListaAnteriorEDetectaSumico() {
        var cache = CacheModelos.vazio
        cache = ListaModelos.aplicar(cache, lane: "grok", modelos: ["a", "b"], agora: "t1")
        cache = ListaModelos.aplicar(cache, lane: "grok", modelos: [], agora: "t2")
        XCTAssertEqual(cache.listas["grok"], ["a", "b"])
        cache = ListaModelos.aplicar(cache, lane: "grok", modelos: ["b"], agora: "t3")
        XCTAssertEqual(cache.anteriores["grok"], ["a", "b"])
        XCTAssertEqual(cache.listas["grok"], ["b"])
        XCTAssertTrue(ModeloLane.sumiu("a", lane: "grok", prefixo: "", cache: cache))
        XCTAssertFalse(ModeloLane.sumiu("b", lane: "grok", prefixo: "", cache: cache))
        XCTAssertFalse(ModeloLane.sumiu("novo", lane: "grok", prefixo: "", cache: cache))
    }

    func testPainelPrefereOModeloComQueALaneSaiu() {
        let lane = EstadoLanes.LaneRodando(lane: "claude", card: "FRA-1", titulo: nil, startedAt: nil,
                                           log: "x.jsonl", travada: false, effort: "alto", modelo: "opus",
                                           modeloFixo: true)
        let t = ModeloLane.textosPainel(rodando: [lane], dados: [:], cache: .vazio, agentes: [])
        XCTAssertEqual(t.texto["claude"], "claude · opus (alto)")
        XCTAssertEqual(t.aviso["claude"], "modelo fixo")
    }

    func testAbaLanesNaoTemMaisModeloChumbado() {
        let abas = CatalogoAjustes.abas()
        XCTAssertEqual(abas.filter(\.modelosLane).count, 1)
        let chaves = abas.flatMap(\.campos).map(\.chave)
        XCTAssertFalse(chaves.contains("lanes.modelo.opencode"))
        XCTAssertFalse(chaves.contains("lanes.modelo.opencode-go"))
    }

    func testDefinirModeloApagaAChavePlana() throws {
        let t = try PastaTemp()
        try t.escrever("Library/Application Support/Lanekeeper/config.json",
                       #"{"version":1,"lanes.modelo.claude":"sonnet"}"#)
        let m = ModeloAjustes(home: t.url)
        let cfg = ConfigModelo(modo: .auto, fixo: "", porPeso: [
            "alto": EscolhaPeso(modelo: "opus", esforco: "xhigh", esforcoExplicito: true),
        ], aviso: "")
        try m.definirModelo("claude", cfg)
        XCTAssertNil(m.dados["lanes.modelo.claude"])
        let lido = ModeloLane.ler(ModeloLane.bruto(lane: "claude", em: m.dados))
        XCTAssertEqual(lido.modo, .auto)
        XCTAssertEqual(lido.porPeso["alto"]?.modelo, "opus")
        XCTAssertEqual(lido.porPeso["alto"]?.esforco, "xhigh")
        XCTAssertEqual(lido.porPeso["alto"]?.esforcoExplicito, true)
        XCTAssertNil(lido.porPeso["baixo"])
        let deNovo = ModeloAjustes(home: t.url)
        let relido = ModeloLane.ler(ModeloLane.bruto(lane: "claude", em: deNovo.dados))
        XCTAssertEqual(relido, lido)
    }

    func testChavePlanaGanhaDaAninhada() {
        let dados: [String: Any] = [
            "lanes.modelo.grok": "grok-4.7",
            "lanes": ["modelo": ["grok": ["modo": "auto", "fixo": "", "porPeso": [:]]]],
        ]
        let lido = ModeloLane.ler(ModeloLane.bruto(lane: "grok", em: dados))
        XCTAssertEqual(lido.modo, .fixo)
        XCTAssertEqual(lido.fixo, "grok-4.7")
    }

    func testPrefixoCurtoDoOpencode() {
        let padrao = ModeloLane.padrao(agente("opencode"))
        XCTAssertEqual(ModeloLane.prefixo(padrao), "opencode/")
        let cfg = ConfigModelo(modo: .auto, fixo: "", porPeso: [
            "baixo": EscolhaPeso(modelo: "deepseek-v4.1-flash-free", esforco: "", esforcoExplicito: false),
        ], aviso: "")
        let r = ModeloLane.resolver(lane: "opencode", peso: "baixo", config: cfg, padrao: padrao, cache: .vazio)
        XCTAssertEqual(r.modelo, "opencode/deepseek-v4.1-flash-free")
    }
}
