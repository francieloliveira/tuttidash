import XCTest
@testable import GastoCore

/// Painel v2: números dos cartões do topo, `#N`, branch e recortes de custo.
final class IndicadoresTests: XCTestCase {
    private let calendario = calendarioFixo()
    private let agora = data("2026-10-16 18:00:00")   // sexta, semana 2026-W42

    private func montar(_ entrada: EntradaPainel = .vazia, _ execs: [Execucao],
                        ordinais: [String: Int]? = nil) -> SnapshotPainel {
        MontadorPainel.montar(entrada: entrada, execucoes: execs, agora: agora, calendario: calendario,
                              ordinais: ordinais)
    }

    func testOrdinalSegueOInicioENaoMudaComFiltro() {
        let execs = [
            ex("FRA-2-codex-20261016-100000", custo: 1),
            ex("FRA-1-claude-20261015-090000", custo: 1),
            ex("FRA-3-claude-20261016-110000", custo: 1),
        ]
        let n = Indicadores.ordinais(execs)
        XCTAssertEqual(n["FRA-1-claude-20261015-090000"], 1)
        XCTAssertEqual(n["FRA-2-codex-20261016-100000"], 2)
        XCTAssertEqual(n["FRA-3-claude-20261016-110000"], 3)
        // o app conta no histórico inteiro e só depois tira a lane desligada
        let snap = montar(.vazia, execs.filter { $0.lane == "claude" }, ordinais: n)
        XCTAssertEqual(snap.lanes.first { $0.lane == "claude" }?.ultimaBuild, 3)
        XCTAssertNil(snap.lanes.first { $0.lane == "codex" }?.ultimaBuild)
    }

    func testBuildsHojeOntemEFalhasDas24h() {
        let execs = [
            ex("FRA-1-claude-20261015-190000", custo: 1),                  // ontem, dentro das 24 h
            ex("FRA-2-claude-20261015-120000", custo: 1, status: .erro),   // ontem, fora das 24 h
            ex("FRA-3-codex-20261016-090000", custo: 1, status: .erro),
            ex("FRA-4-codex-20261016-173000", custo: 1, status: .morta),
            ex("FRA-5-claude-20261016-174500", custo: nil, status: .emAndamento),
        ]
        let ind = montar(.vazia, execs).indicadores
        XCTAssertEqual(ind.buildsHoje, 3)
        XCTAssertEqual(ind.buildsOntem, 2)
        XCTAssertEqual(ind.execucoes24h, 4)
        XCTAssertEqual(ind.falhas24h, 2)
        XCTAssertEqual(ind.falhasPct ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(ind.buildsSerie.count, 12)
        XCTAssertEqual(ind.buildsSerie[11], 2)      // 17:30 e 17:45 caem na hora corrente
        XCTAssertEqual(ind.buildsSerie[2], 1)       // 09:00 = 9 h atrás
        XCTAssertEqual(ind.falhasSerie.reduce(0, +), 2)
        let builds = montar(.vazia, execs).buildsHoje
        XCTAssertEqual(builds.map(\.card), ["FRA-5", "FRA-4", "FRA-3"])
        XCTAssertEqual(builds.first?.numero, 5)
        XCTAssertNil(builds.first?.custoUSD)
    }

    func testVariacaoDaSemanaComparaOMesmoPontoDaSemanaAnterior() {
        let execs = [
            ex("FRA-1-claude-20261013-100000", custo: 30),   // W42
            ex("FRA-2-claude-20261006-100000", custo: 15),   // W41, antes do mesmo ponto
            ex("FRA-3-claude-20261009-170000", custo: 5),    // W41, sexta 17h: ainda conta
            ex("FRA-4-claude-20261010-100000", custo: 99),   // W41, sábado: depois do mesmo ponto
            ex("FRA-5-grok-20261007-100000", custo: nil),    // desconhecido nunca vira zero
        ]
        let snap = montar(.vazia, execs)
        XCTAssertEqual(snap.indicadores.semanaAnterior ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(snap.indicadores.variacaoSemanaPct ?? 0, 50, accuracy: 0.001)
        XCTAssertTrue(snap.alertasPainel.contains("Custo semanal 50% maior que a semana anterior"))
        XCTAssertFalse(snap.alertas.contains { $0.hasPrefix("Custo semanal") }, "o notch não muda")
    }

    func testSemGastoAnteriorNaoInventaVariacao() {
        let snap = montar(.vazia, [ex("FRA-1-claude-20261013-100000", custo: 30)])
        XCTAssertNil(snap.indicadores.semanaAnterior)
        XCTAssertNil(snap.indicadores.variacaoSemanaPct)
        XCTAssertEqual(snap.alertasPainel, snap.alertas)
    }

    func testBranchDaLaneVemDoEstado() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:00", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        entrada.rodando = [.init(lane: "claude", card: "FRA-9", titulo: nil, startedAt: "2026-10-16 17:50:00",
                                 log: "FRA-9-claude-20261016-175000.jsonl", travada: false,
                                 branch: "dev/fra-9-ajuste")]
        let snap = montar(entrada, [])
        XCTAssertEqual(snap.lanes.first { $0.lane == "claude" }?.branch, "dev/fra-9-ajuste")
        XCTAssertNil(snap.lanes.first { $0.lane == "codex" }?.branch)
        XCTAssertEqual(snap.indicadores.lanesTotal, LanesPainel.ordem.count)
        XCTAssertEqual(snap.indicadores.lanesAtivas, snap.lanes.filter { $0.estado == .rodando || $0.estado == .livre }.count)
    }

    func testBranchLidaDoArquivoDaLane() {
        let l = EstadoLanes.laneRodando(nomeArquivo: "lane-claude.json", dados: [
            "lane": "claude", "card": "fra-9", "log": "/x/FRA-9-claude-20261016-175000.jsonl",
            "branch": "dev/fra-9-ajuste",
        ])
        XCTAssertEqual(l?.branch, "dev/fra-9-ajuste")
    }

    func testRecortesMesEAno() {
        let execs = [
            ex("FRA-1-claude-20261001-100000", custo: 2),    // outubro, W40
            ex("FRA-2-codex-20261014-100000", custo: 3),     // outubro, W42
            ex("FRA-3-claude-20260915-100000", custo: 7),    // setembro
            ex("FRA-4-grok-20261015-100000", custo: nil),    // desconhecido
        ]
        let custos = montar(.vazia, execs).custos
        let mes = custos.periodos[.mes]!
        XCTAssertEqual(mes.total ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(mes.desconhecidas, 1)
        XCTAssertEqual(mes.barras.map(\.rotulo), ["S40", "S41", "atual"])
        XCTAssertEqual(mes.barras.map(\.total), [2, 0, 3])
        XCTAssertEqual(mes.top.first?.card, "FRA-2")
        let ano = custos.periodos[.ano]!
        XCTAssertEqual(ano.total ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(ano.barras.count, 10)
        XCTAssertEqual(ano.barras[8].total, 7, accuracy: 0.001)
        XCTAssertTrue(ano.barras[9].ehHoje)
        XCTAssertEqual(custos.periodos[.semana]?.top, custos.top)
    }

    func testTopGuardaOInicioMaisNovoDoCard() {
        let execs = [
            ex("FRA-7-claude-20261016-100000", custo: 4),
            ex("FRA-7-claude-20261016-150000", custo: 4),
        ]
        let top = montar(.vazia, execs).custos.top
        XCTAssertEqual(top.first?.ultimoInicio, data("2026-10-16 15:00:00"))
    }
}
