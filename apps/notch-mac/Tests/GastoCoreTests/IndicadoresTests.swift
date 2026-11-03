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
        XCTAssertEqual(ind.execucoes24h, 3, "em andamento fica fora do %")
        XCTAssertEqual(ind.falhas24h, 2)
        XCTAssertEqual(ind.falhasPct ?? 0, 200.0 / 3, accuracy: 0.001)
        XCTAssertEqual(ind.buildsSerie.count, 12)
        XCTAssertEqual(ind.buildsSerie[11], 2)      // 17:30 e 17:45 caem na hora corrente
        XCTAssertEqual(ind.buildsSerie[2], 1)       // 09:00 = 9 h atrás
        XCTAssertEqual(ind.falhasSerie.reduce(0, +), 2)
        let builds = montar(.vazia, execs).buildsHoje
        XCTAssertEqual(builds.map(\.card), ["FRA-5", "FRA-4", "FRA-3"])
        XCTAssertEqual(builds.first?.numero, 5)
        XCTAssertNil(builds.first?.custoUSD)
    }

    /// Revisão de 02/11: janela atual = hoje + 6 dias (10/10 00:00 até agora); anterior = os
    /// 7 dias antes dela até o mesmo horário (03/10 00:00 até 09/10 18:00).
    func testVariacaoCompara7DiasCom7DiasAnterioresNoMesmoHorario() {
        let execs = [
            ex("FRA-1-claude-20261013-100000", custo: 30),   // janela atual
            ex("FRA-7-claude-20261010-080000", custo: 10),   // sábado: janela atual (na semana ISO seria a anterior)
            ex("FRA-2-claude-20261003-100000", custo: 15),   // 1º dia da janela anterior
            ex("FRA-3-claude-20261009-170000", custo: 5),    // antes do mesmo horário: conta
            ex("FRA-4-claude-20261009-190000", custo: 99),   // depois do mesmo horário: fora
            ex("FRA-6-claude-20261002-230000", custo: 50),   // antes da janela anterior: fora
            ex("FRA-5-grok-20261007-100000", custo: nil),    // desconhecido nunca vira zero
        ]
        let snap = montar(.vazia, execs)
        XCTAssertEqual(snap.custos.semana ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(snap.indicadores.semanaAnterior ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(snap.indicadores.variacaoSemanaPct ?? 0, 100, accuracy: 0.001)
        XCTAssertTrue(snap.alertasPainel.contains("Custo dos últimos 7 dias 100% maior que nos 7 dias anteriores"))
        XCTAssertFalse(snap.alertas.contains { $0.hasPrefix("Custo dos últimos") }, "o notch não muda")
    }

    /// Revisão de 02/11: KPI, gasto por lane, gráfico, top 5 e lista usam a mesma janela.
    func testBloco7DiasUsaUmaJanelaSo() {
        let execs = [
            ex("FRA-1-claude-20261016-100000", custo: 2),    // hoje (sexta)
            ex("FRA-2-grok-20261011-100000", custo: 8),      // domingo: semana ISO anterior, mas dentro dos 7 dias
            ex("FRA-3-claude-20261009-100000", custo: 50),   // fora dos 7 dias
        ]
        let snap = montar(.vazia, execs)
        let p = snap.custos.periodos[.semana]
        XCTAssertEqual(snap.custos.semana ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(p?.total ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(snap.custos.dias.map(\.total).reduce(0, +), 10, accuracy: 0.001)
        let somaLanes = (p?.porLane ?? []).compactMap(\.custoUSD).reduce(0, +)
        XCTAssertEqual(somaLanes, 10, accuracy: 0.001)
        XCTAssertEqual(Set(p?.top.map(\.card) ?? []), ["FRA-1", "FRA-2"])
        XCTAssertEqual(PeriodoCustos.semana.rotulo, "7 dias")
    }

    /// Lane que gastou mas não está no painel entra no fim do «Gasto por lane».
    func testGastoDeLaneForaDoPainelNaoSome() {
        let snap = montar(.vazia, [ex("FRA-1-fantasma-20261016-100000", custo: 3)])
        let lanes = snap.custos.periodos[.semana]?.porLane ?? []
        XCTAssertEqual(lanes.last?.lane, "fantasma")
        XCTAssertEqual(lanes.last?.custoUSD ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(Array(lanes.map(\.lane).prefix(LanesPainel.ordem.count)), LanesPainel.ordem)
    }

    /// Revisão de 02/11: a mesma regra de folga do dispatcher (janela longa afrouxa).
    func testFolgaSegueAJanelaDoDispatcher() {
        XCTAssertEqual(LanesPainel.folga("alto", janela: "5h"), 60)
        XCTAssertEqual(LanesPainel.folga("alto", janela: "30 dias"), 85)
        XCTAssertEqual(LanesPainel.folga("baixo", janela: "semana"), 95)
        XCTAssertEqual(LanesPainel.folga("medio", janela: "mês"), 90)
        XCTAssertEqual(LanesPainel.folga("medio", janela: nil), 80)
        XCTAssertFalse(LanesPainel.janelaLonga("5 h"))
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

/// Revisão de 02/11: a suíte vale pela última tentativa da prova.
final class ProvaUltimaTentativaTests: XCTestCase {
    func testSuiteQueFalhaNaPrimeiraEPassaNaSegundaContaComoOk() {
        let log = """
        [prova] TranscentIATests: 1ª tentativa SKIP_PREFLIGHT=1
        Test Case '-[ScenarioTests testPortao]' failed (2.000 seconds)
        Test Case '-[OutraTests testA]' passed (1.000 seconds)
        [prova] TranscentIATests: 1ª falhou; 2ª tentativa com preflight
        Test Case '-[ScenarioTests testPortao]' passed (2.500 seconds)
        Test Case '-[OutraTests testA]' passed (1.000 seconds)
        Executed 2 tests, with 0 failures (0 unexpected) in 3.500 (3.600) seconds
        ** TEST SUCCEEDED **
        """
        let a = Provas.analisar(log)
        XCTAssertEqual(a.suites.map(\.nome), ["ScenarioTests", "OutraTests"])
        XCTAssertTrue(a.suites.allSatisfy { $0.estado == .ok }, "a 1ª tentativa não vale mais")
        XCTAssertEqual(a.tentativa, 2)
    }

    func testFalhaNasDuasTentativasContinuaFalha() {
        let log = """
        [prova] TranscentIATests: 1ª tentativa SKIP_PREFLIGHT=1
        Test Case '-[ScenarioTests testPortao]' failed (2.000 seconds)
        [prova] TranscentIATests: 1ª falhou; 2ª tentativa com preflight
        Test Case '-[ScenarioTests testPortao]' failed (2.000 seconds)
        ** TEST FAILED **
        """
        XCTAssertEqual(Provas.analisar(log).suites.map(\.estado), [.falha])
    }

    func testPythonNaSegundaTentativa() {
        let log = """
        [prova] tests.test_x: 1ª tentativa SKIP_PREFLIGHT=1
        Ran 3 tests in 0.1s
        FAILED (failures=1)
        [prova] tests.test_x: 1ª falhou; 2ª tentativa com preflight
        Ran 3 tests in 0.1s
        OK
        """
        XCTAssertEqual(Provas.analisar(log).suites.map(\.estado), [.ok])
    }

    func testDuasSuitesSoARefeitaPerdeA1aTentativa() {
        let log = """
        [prova] AppTests: 1ª tentativa SKIP_PREFLIGHT=1
        Test Case '-[AppTests testA]' passed (1.000 seconds)
        [prova] UITests: 1ª tentativa SKIP_PREFLIGHT=1
        Test Case '-[UITests testB]' failed (1.000 seconds)
        [prova] UITests: 1ª falhou; 2ª tentativa com preflight
        Test Case '-[UITests testB]' passed (1.000 seconds)
        """
        let a = Provas.analisar(log)
        XCTAssertEqual(a.suites.map(\.nome), ["AppTests", "UITests"])
        XCTAssertEqual(a.suites.map(\.estado), [.ok, .ok])
    }
}
