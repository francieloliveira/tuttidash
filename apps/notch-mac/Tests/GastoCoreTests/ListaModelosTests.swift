import XCTest
@testable import GastoCore

/// FRA-564: Claude e Codex sem lista nos Ajustes, lixo no grok, fixo vazio e selo por lane.
final class ListaModelosTests: XCTestCase {
    func testSemChaveDaApiOClaudeDizComoListar() throws {
        let pasta = try PastaTemp()
        let r = ListaModelos.modelosClaude(home: pasta.url, ambiente: [:])
        XCTAssertTrue(r.modelos.isEmpty)
        XCTAssertTrue(r.motivo?.contains("ANTHROPIC_API_KEY") == true)
    }

    func testCodexUsaACacheDoCliSemRede() throws {
        let pasta = try PastaTemp()
        try pasta.escrever(".codex/models_cache.json",
                           #"{"models":[{"slug":"gpt-b","priority":2},{"slug":"gpt-a","priority":1}]}"#)
        XCTAssertEqual(ListaModelos.modelosCodex(home: pasta.url, ambiente: [:]).modelos, ["gpt-a", "gpt-b"])
        let vazia = try PastaTemp()
        XCTAssertTrue(ListaModelos.modelosCodex(home: vazia.url, ambiente: [:]).motivo?.contains("OPENAI_API_KEY") == true)
    }

    func testRespostaRecusadaViraMotivoDeLoginVencido() {
        let corpo = Data(#"{"data":[{"id":"claude-opus-5-5"},{"id":"claude-sonnet-5-5"}]}"#.utf8)
        XCTAssertEqual(ListaModelos.resultado((200, corpo), ferramenta: "Claude", vencido: "venceu").modelos,
                       ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(ListaModelos.resultado((401, nil), ferramenta: "Claude", vencido: "venceu").motivo, "venceu")
        XCTAssertEqual(ListaModelos.resultado((403, nil), ferramenta: "Claude", vencido: "venceu").motivo, "venceu")
        XCTAssertNotNil(ListaModelos.resultado((nil, nil), ferramenta: "Claude", vencido: "venceu").motivo)
        XCTAssertNotNil(ListaModelos.resultado((500, nil), ferramenta: "Claude", vencido: "venceu").motivo)
    }

    func testCodexLeAListaDoCLISemOsOcultos() {
        let json = """
        {"fetched_at":"2026-10-23T18:41:46Z","models":[
          {"slug":"gpt-reserve","visibility":"hide","priority":4},
          {"slug":"gpt-5.6-luna","visibility":"list","priority":9},
          {"slug":"gpt-5.6-terra","visibility":"list","priority":8},
          {"slug":"codex-auto-review","visibility":"hide","priority":43},
          {"slug":"sem-prioridade"},
          {"display_name":"sem slug"}
        ]}
        """
        XCTAssertEqual(ListaModelos.modelosCacheCodex(Data(json.utf8)), ["gpt-5.6-terra", "gpt-5.6-luna", "sem-prioridade"])
        XCTAssertNil(ListaModelos.modelosCacheCodex(Data(#"{"outra":[]}"#.utf8)))
    }

    func testGrokIgnoraAsFrasesDoCabecalho() {
        let saida = """
        You are logged in with grok.com.
        Default model: grok-4.7
        Available models:
          * grok-4.7 (default)
          - grok-4.7-build-fast
          - grok-4.6
          - grok-4.5
        """
        let pedido = ListaModelos.Pedido(lane: "grok", prefixo: "", privado: false)
        let r = ListaModelos.atualizar([pedido], cache: .vazio, agora: "t",
                                       rodar: { $0 == "grok" ? saida : nil },
                                       claude: { .ok([]) }, codex: { .ok([]) }, pode: { _ in [:] })
        XCTAssertEqual(r.cache.listas["grok"], ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"])
        XCTAssertNil(r.motivos["grok"])
    }

    func testFalhaGuardaAListaAnteriorDaOMotivoENaoGanhaSelo() {
        var cache = CacheModelos.vazio
        cache = ListaModelos.aplicar(cache, lane: "claude", modelos: ["claude-opus-5-5"], agora: "t1")
        let pedidos = [ListaModelos.Pedido(lane: "claude", prefixo: "", privado: false),
                       ListaModelos.Pedido(lane: "codex", prefixo: "", privado: false)]
        let r = ListaModelos.atualizar(pedidos, cache: cache, agora: "t2", rodar: { _ in nil },
                                       claude: { .falha("login vencido") },
                                       codex: { .ok(["gpt-5.6-terra"]) }, pode: { _ in [:] })
        XCTAssertEqual(r.cache.listas["claude"], ["claude-opus-5-5"])
        XCTAssertEqual(r.motivos["claude"], "login vencido")
        XCTAssertEqual(r.cache.porLane["claude"], "t1")
        XCTAssertEqual(r.cache.porLane["codex"], "t2")
        XCTAssertNil(r.motivos["codex"])
        XCTAssertEqual(r.cache.atualizadoEm, "t2")
    }

    func testSeloPorLaneSobreviveAoArquivo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modelos-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = CacheModelos(atualizadoEm: "t2", listas: ["grok": ["grok-4.7"]], anteriores: [:],
                                 porLane: ["grok": "t2"])
        try ListaModelos.gravar(cache, em: url)
        XCTAssertEqual(ListaModelos.ler(url), cache)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil(obj?["atualizado_em_por_lane"], "mesma chave que o dispatcher lê")
    }

    func testFixoSemModeloUsaOAutomaticoComAviso() {
        let cfg = ConfigModelo(modo: .fixo, fixo: "", porPeso: [:], aviso: "")
        let padrao = ["alto": EscolhaPeso(modelo: "opus", esforco: "xhigh", esforcoExplicito: false)]
        let r = ModeloLane.resolver(lane: "claude", peso: "alto", config: cfg, padrao: padrao, cache: .vazio)
        XCTAssertEqual(r.modelo, "opus")
        XCTAssertFalse(r.fixo)
        XCTAssertEqual(r.aviso, ModeloLane.avisoFixoVazio)
    }
}
