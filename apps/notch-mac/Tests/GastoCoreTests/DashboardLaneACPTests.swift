import XCTest
@testable import GastoCore

/// Regressão do dashboard e das listagens com uma lane ACP na config (PRD lanes-acp).
/// Sem lane ACP, as outras suítes já cobrem o comportamento antigo.
final class DashboardLaneACPTests: XCTestCase {
    private let lane = "opencode-beam-free"
    private let agora = Date()
    private var calendario: Calendar { Calendar.current }
    private var pastaConfig: PastaTemp!
    private var envAntigo: String?

    override func setUpWithError() throws {
        pastaConfig = try PastaTemp()
        let cfg: [String: Any] = [
            "lanes": ["acp": [["nome": lane, "agente": "opencode", "modelo": "opencode/beam-free", "ligada": true]]],
            "contas": [["id": "opencode", "tipo": "opencode"], ["id": "claude", "tipo": "claude"]],
        ]
        let url = pastaConfig.url.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: cfg).write(to: url)
        envAntigo = ProcessInfo.processInfo.environment[Configuracao.envConfig]
        setenv(Configuracao.envConfig, url.path, 1)
    }

    override func tearDown() {
        if let envAntigo { setenv(Configuracao.envConfig, envAntigo, 1) } else { unsetenv(Configuracao.envConfig) }
    }

    func testListasConhecemALane() {
        XCTAssertEqual(LanesPainel.ordem.last, lane, "painel e notch: depois das lanes do catálogo")
        XCTAssertEqual(Array(LanesPainel.ordem.dropLast()), Agentes.ordemPainel, "as do catálogo não mudam")
        XCTAssertTrue(Agentes.ordemLanes.contains(lane))
        XCTAssertFalse(Agentes.ordem.contains(lane), "não vira tipo de conta")
        XCTAssertFalse(ContaUso.padrao.contains { $0.id == lane }, "não vira conta padrão")
        XCTAssertEqual(Agentes.def(lane)?.rotulo, "\(Agentes.def("opencode")!.rotulo) · beam-free")
        XCTAssertEqual(LeitorNomes.lanes(texto: "\(lane) claude intrusa"), [lane, "claude"])
    }

    func testEnabledDoAppNaoApagaALane() throws {
        let t = try PastaTemp()
        try t.escrever("dispatcher.py", "# dispatcher")
        try LanesHabilitadas.gravar(["claude", lane], stateDir: t.url)
        XCTAssertEqual(LanesHabilitadas.ler(stateDir: t.url), ["claude", lane])
    }

    func testConfiguracaoHabilitaALaneDaContaAtiva() {
        let cfg = Configuracao.resolver()
        XCTAssertTrue(cfg.lanesHabilitadas?.contains(lane) == true)
        XCTAssertTrue(cfg.lanesHabilitadas?.contains("claude") == true)
    }

    func testPainelMostraALaneRodandoEContaAProva() throws {
        let t = try PastaTemp()
        try t.escrever("enabled", "claude \(lane)\n")
        try t.escrever("heartbeat.json", #"{"at":"2026-11-02 12:00:00","dry_run":false,"enabled":["claude","\#(lane)"]}"#)
        let wt = t.url.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt.appendingPathComponent(".lane"), withIntermediateDirectories: true)
        let log = "Test Case '-[PilotoTests.PilotoTests testUm]' passed (0.001 seconds).\n"
            + "Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n** TEST SUCCEEDED **\n"
        try log.write(to: wt.appendingPathComponent(".lane/proof.log"), atomically: true, encoding: .utf8)
        try "0".write(to: wt.appendingPathComponent(".lane/proof_exit"), atomically: true, encoding: .utf8)
        try "\(agora.addingTimeInterval(-60).timeIntervalSince1970)".write(
            to: wt.appendingPathComponent(".lane/proof_started"), atomically: true, encoding: .utf8)
        let estado: [String: Any] = ["lane": lane, "card": "FRA-900", "title": "piloto ACP",
                                     "log": "/tmp/FRA-900-\(lane)-20261102-120000.jsonl", "worktree": wt.path,
                                     "started": agora.addingTimeInterval(-120).timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: estado).write(to: t.url.appendingPathComponent("lane-\(lane).json"))
        let logs = t.url.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let entrada = LeitorPainelDisco.ler(pasta: t.url, logDispatcher: t.url.appendingPathComponent("x.log"),
                                            logsDir: logs, agora: agora)
        XCTAssertTrue(entrada.rodando.contains { $0.lane == lane && $0.card == "FRA-900" })
        XCTAssertTrue(entrada.habilitadas?.contains(lane) == true)
        let snap = MontadorPainel.montar(entrada: entrada, execucoes: [], agora: agora, calendario: calendario)
        let linha = snap.lanes.first { $0.lane == lane }
        XCTAssertNotNil(linha, "a lane ACP aparece na lista de lanes do dashboard")
        XCTAssertEqual(linha?.card, "FRA-900")
        XCTAssertTrue(snap.notch.pontos.contains { $0.lane == lane }, "e no notch")
        XCTAssertTrue(snap.provas.contains { $0.card == "FRA-900" }, "a prova entra na tela Testes")
        let ind = Indicadores.calcular(linhas: snap.lanes, execucoes: [], provas: entrada.provas,
                                       semanaAtual: nil, agora: agora, calendario: calendario)
        XCTAssertEqual(ind.provasHoje, 1, "card Testes do dashboard conta a prova da lane ACP")
        XCTAssertEqual(ind.testesPassou, 1)
    }

    func testLedgerDaLaneACPEntraNoGasto() throws {
        let t = try PastaTemp()
        let linha = #"{"type":"system","subtype":"init","session_id":"s","model":"opencode/beam-free","transporte":"acp","lane":"\#(lane)","agente":"opencode"}"#
            + "\n" + #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","stop_reason":"end_turn","num_turns":1,"duration_ms":1000,"total_cost_usd":0.25,"usage":{"input_tokens":10,"output_tokens":2}}"#
        try t.escrever("FRA-900-\(lane)-20261102-120000.jsonl", linha + "\n")
        let ex = try ParserLog.ler(url: t.url.appendingPathComponent("FRA-900-\(lane)-20261102-120000.jsonl"))
        XCTAssertEqual(ex?.lane, lane)
        XCTAssertEqual(ex?.status, .ok)
        XCTAssertEqual(ex?.custoUSD, 0.25)
    }
}
