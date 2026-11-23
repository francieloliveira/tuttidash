import XCTest
@testable import GastoCore

final class EventosFluxoTests: XCTestCase {
    func testLeEIgnoraLixo() {
        let linhas = """
        {"schema":1,"ts":"2026-11-22T20:00:00","projeto":"p1","card":"fra-1","lane":"claude","etapa":"claim","status":"iniciado"}
        nao json
        {"schema":2,"ts":"2026-11-22T20:00:00","projeto":"p1","card":"FRA-1","lane":"claude","etapa":"claim"}
        {"schema":1,"ts":"2026-11-22T20:10:00","projeto":"p1","card":"FRA-1","lane":"claude","etapa":"finalize","status":"In Review"}
        """
        let ev = LeitorEventos.ler(dados: Data(linhas.utf8))
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(ev.first?.card, "FRA-1")
        XCTAssertEqual(ev.last?.status, "In Review")
    }

    func testResumoContaEMedeClaimAteFinalize() {
        let ev = [
            EventoFluxo(ts: "2026-11-22T20:00:00", projeto: "p1", card: "FRA-1", lane: "claude", etapa: "claim"),
            EventoFluxo(ts: "2026-11-22T20:30:00", projeto: "p1", card: "FRA-1", lane: "claude",
                        etapa: "finalize", status: "In Review"),
            EventoFluxo(ts: "2026-11-22T21:00:00", projeto: "p1", card: "FRA-1", lane: "claude", etapa: "merge"),
            EventoFluxo(ts: "2026-11-22T20:00:00", projeto: "p2", card: "FRA-2", lane: "grok", etapa: "claim"),
        ]
        let r = Fluxo.resumo(ev)
        XCTAssertEqual(r.map(\.projeto), ["p1", "p2"])
        let p1 = r[0]
        XCTAssertEqual(p1.claims, 1)
        XCTAssertEqual(p1.finalizes, 1)
        XCTAssertEqual(p1.merges, 1)
        XCTAssertEqual(p1.duracaoMediaMin ?? 0, 30, accuracy: 0.001)
        let p2 = r[1]
        XCTAssertEqual(p2.claims, 1)
        XCTAssertEqual(p2.abertos, 1)
        XCTAssertNil(p2.duracaoMediaMin)
    }

    func testArquivoAusente() {
        XCTAssertEqual(LeitorEventos.ler(url: URL(fileURLWithPath: "/nao/existe/eventos.jsonl")), [])
    }
}
