import XCTest
@testable import GastoCore

final class AgregadorTests: XCTestCase {
    let agora = data("2026-10-05T21:44:00")   // segunda, semana 41

    private func resumir(_ execs: [Execucao], teto: Double? = nil, aviso: Double = 80,
                         estado: EstadoLanes = EstadoLanes()) -> Resumo {
        Agregador.resumir(execucoes: execs, estado: estado, teto: teto, avisoPct: aviso, agora: agora,
                          calendario: calendarioFixo())
    }

    private var amostra: [Execucao] {
        [
            ex("FRA-249-claude-20261005-114313", custo: 10.0),
            ex("FRA-249-claude-20261005-153833", custo: 14.05),
            ex("FRA-249-claude-20261005-194658", custo: nil, status: .emAndamento, duracaoMs: nil,
               estimadaMs: 720_000, respostas: 57),
            ex("FRA-257-claude-20261003-213352", custo: 0.5),
            ex("FRA-257-claude-20261003-213704", custo: 0.33, status: .erro),
            ex("FRA-261-grok-20261004-171354", custo: 0.57, status: .erro),
            ex("FRA-261-grok-20261004-172712", custo: nil),
            ex("FRA-259-grok-20261004-125857", custo: 0.48),
            ex("FRA-200-claude-20260927-100000", custo: 50.0),   // fora dos 7 dias
        ]
    }

    func testSemanaSoSomaConhecido() {
        let r = resumir(amostra, teto: 28)
        XCTAssertEqual(r.semana, "2026-W41")
        XCTAssertEqual(r.numeroSemana, 41)
        XCTAssertEqual(r.gastoSemana, 24.05, accuracy: 1e-9)
        XCTAssertEqual(r.execucoesSemana, 3)
        XCTAssertEqual(r.desconhecidasSemana, 1)
        XCTAssertEqual(r.estimadoSemana, 24.05, accuracy: 1e-9)
        XCTAssertEqual(r.pct!, 24.05 / 28 * 100, accuracy: 1e-9)
        XCTAssertEqual(r.nivel, .perto)
    }

    func testNiveisDoTeto() {
        XCTAssertEqual(Agregador.nivel(gasto: 10, teto: nil, avisoPct: 80).0, .semTeto)
        XCTAssertNil(Agregador.nivel(gasto: 10, teto: nil, avisoPct: 80).1)
        XCTAssertEqual(Agregador.nivel(gasto: 10, teto: 0, avisoPct: 80).0, .semTeto)
        XCTAssertEqual(Agregador.nivel(gasto: 79.9, teto: 100, avisoPct: 80).0, .ok)
        XCTAssertEqual(Agregador.nivel(gasto: 80, teto: 100, avisoPct: 80).0, .perto)
        XCTAssertEqual(Agregador.nivel(gasto: 100, teto: 100, avisoPct: 80).0, .estourado)
        XCTAssertEqual(Agregador.nivel(gasto: 130, teto: 100, avisoPct: 80).1, 130)
    }

    func testSemTeto() {
        let r = resumir(amostra, teto: nil)
        XCTAssertNil(r.teto); XCTAssertNil(r.pct); XCTAssertEqual(r.nivel, .semTeto)
        XCTAssertEqual(r.gastoSemana, 24.05, accuracy: 1e-9)
    }

    func testSeteDias() {
        let r = resumir(amostra)
        XCTAssertEqual(r.dias.map(\.dia), ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02",
                                          "2026-10-03", "2026-10-04", "2026-10-05"])
        XCTAssertEqual(r.dias.map(\.diaSemana), ["ter", "qua", "qui", "sex", "sáb", "dom", "hoje"])
        XCTAssertEqual(r.dias.map(\.dataCurta), ["29/09", "30/09", "01/10", "02/10", "03/10", "04/10", "05/10"])
        XCTAssertEqual(r.dias[4].porLane["claude"]!, 0.83, accuracy: 1e-9)
        XCTAssertEqual(r.dias[5].porLane["grok"]!, 1.05, accuracy: 1e-9)
        XCTAssertEqual(r.dias[5].desconhecidas, 1)
        XCTAssertEqual(r.dias[6].total, 24.05, accuracy: 1e-9)
        XCTAssertEqual(r.dias[6].desconhecidas, 1)
        XCTAssertEqual(r.dias[0].total, 0)
        XCTAssertEqual(r.execucoes7d, 8)
        XCTAssertEqual(r.desconhecidas7d, 2)
    }

    func testCardsMaisCaros() {
        let r = resumir(amostra)
        XCTAssertEqual(r.cards.map(\.card), ["FRA-249", "FRA-257", "FRA-261", "FRA-259"])
        let c249 = r.cards[0]
        XCTAssertEqual(c249.custoConhecido, 24.05, accuracy: 1e-9)
        XCTAssertEqual(c249.execucoes, 3); XCTAssertEqual(c249.desconhecidas, 1); XCTAssertEqual(c249.lanes, ["claude"])
        XCTAssertEqual(r.cards[1].erros, 1)
        XCTAssertEqual(r.cards[2].lanes, ["grok"]); XCTAssertEqual(r.cards[2].erros, 1); XCTAssertEqual(r.cards[2].execucoes, 2)
        XCTAssertFalse(r.cards.contains { $0.card == "FRA-200" })
    }

    func testCardSoComCustoDesconhecidoVaiParaOFim() {
        let r = resumir([ex("FRA-1-grok-20261005-100000", custo: nil), ex("FRA-2-claude-20261005-110000", custo: 0.1)])
        XCTAssertEqual(r.cards.map(\.card), ["FRA-2", "FRA-1"])
        XCTAssertTrue(r.cards[1].todasDesconhecidas)
    }

    func testDivisaoPorLane() {
        let r = resumir(amostra)
        XCTAssertEqual(r.lanes.map(\.lane), ["claude", "grok"])
        XCTAssertEqual(r.lanes[0].custoConhecido, 24.88, accuracy: 1e-9)
        XCTAssertEqual(r.lanes[0].execucoes, 5)
        XCTAssertEqual(r.lanes[0].desconhecidas, 1)
        XCTAssertEqual(r.lanes[0].duracaoMs, 4 * 60_000)
        XCTAssertEqual(r.lanes[0].duracaoEstimadaMs, 720_000)
        XCTAssertEqual(r.lanes[1].custoConhecido, 1.05, accuracy: 1e-9)
        XCTAssertEqual(r.lanes[1].execucoes, 3)
    }

    func testAgoraVemDoEstadoEDoLog() {
        let estado = EstadoLanes(
            heartbeat: .init(at: "2026-10-05 21:43:00", dryRun: false, habilitadas: ["claude", "grok"]),
            lanes: [.init(lane: "claude", card: "FRA-249", titulo: nil, startedAt: "2026-10-05 21:32:00",
                          log: "/Users/x/Library/Logs/TranscentIA/lanes/FRA-249-claude-20261005-194658.jsonl",
                          travada: false)])
        let r = resumir(amostra, estado: estado)
        XCTAssertEqual(r.rodando.count, 1)
        XCTAssertEqual(r.rodando[0].card, "FRA-249")
        XCTAssertEqual(r.rodando[0].respostas, 57)
        XCTAssertEqual(r.rodando[0].desde, data("2026-10-05T21:32:00"))
        XCTAssertEqual(Formato.ha(r.rodando[0].desde!, agora: agora), "há 12 min")
        XCTAssertEqual(r.heartbeatData, data("2026-10-05T21:43:00"))
    }

    func testSemExecucoes() {
        let r = resumir([])
        XCTAssertEqual(r.gastoSemana, 0); XCTAssertTrue(r.cards.isEmpty); XCTAssertTrue(r.lanes.isEmpty)
        XCTAssertEqual(r.dias.count, 7); XCTAssertTrue(r.rodando.isEmpty)
    }
}

final class FormatoTests: XCTestCase {
    func testValores() {
        XCTAssertEqual(Formato.valor(24.05), "24,05")
        XCTAssertEqual(Formato.valor(0.826), "0,83")
        XCTAssertEqual(Formato.valor(1234.5), "1.234,50")
        XCTAssertEqual(Formato.valor(1_000_000), "1.000.000,00")
        XCTAssertEqual(Formato.valor(0), "0,00")
        XCTAssertEqual(Formato.usd(28), "US$ 28,00")
    }

    func testDuracao() {
        XCTAssertEqual(Formato.duracao(ms: 7 * 60_000 + 59_000), "7 min")
        XCTAssertEqual(Formato.duracao(ms: 102 * 60_000), "1h42")
        XCTAssertEqual(Formato.duracao(ms: 60 * 60_000), "1h00")
        XCTAssertEqual(Formato.ha(Date(), agora: Date().addingTimeInterval(30)), "agora")
    }

    func testDatas() {
        XCTAssertNil(Datas.lerLocal("2026-13-40"))
        XCTAssertNil(Datas.lerLocal("ontem"))
        XCTAssertNotNil(Datas.lerLocal("2026-10-05 20:30:00"))
        XCTAssertEqual(Datas.lerLocal("2026-10-05T20:30:00"), Datas.lerLocal("2026-10-05 20:30:00"))
    }
}
