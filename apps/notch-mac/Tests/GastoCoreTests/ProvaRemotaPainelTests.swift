import XCTest
@testable import GastoCore

/// PRD testes-prova-remota: a tela Testes mostra o check `prova-remota` do GitHub.
final class ProvaRemotaPainelTests: XCTestCase {
    let jsonl = """
    {"card":"FRA-651","lane":"opencode","titulo":"Span","sha":"a","pr":"https://github.com/o/r/pull/69","check":"https://github.com/o/r/actions/runs/1","inicio":1000,"fim":1300,"estado":"verde"}
    lixo
    {"card":"fra-652","lane":"deepseek","titulo":"","sha":"b","pr":"https://github.com/o/r/pull/70","check":"","inicio":2000,"fim":2600,"estado":"vermelho"}
    {"card":"FRA-9","lane":"x","estado":"inventado"}
    {"card":"FRA-653","lane":"x","sha":"c","pr":"p","inicio":3000,"fim":3010,"estado":"main-vermelha"}
    """

    func testLeitorDoJsonl() {
        let r = LeitorProvasRemotas.ler(texto: jsonl)
        XCTAssertEqual(r.map(\.card), ["FRA-653", "FRA-652", "FRA-651"], "o mais novo primeiro; estado inválido sai")
        XCTAssertEqual(r[1].estado, .vermelho)
        XCTAssertEqual(r[1].link, "https://github.com/o/r/pull/70", "sem check, o link é o PR")
        XCTAssertEqual(r[2].segundos(agora: Date()), 300)
        XCTAssertEqual(LeitorProvasRemotas.ler(texto: jsonl, limite: 1).map(\.card), ["FRA-653"])
    }

    func testHistoricoComRemotasVemPrimeiroComDataELink() {
        let remotas = LeitorProvasRemotas.ler(texto: jsonl)
        let local = ResumoProvaHistorico(card: "FRA-1", titulo: "t", lane: "claude", selo: "ok", segundos: 9,
                                         zeroTestes: false, falha: false, emCurso: false)
        let h = MontadorPainel.historicoComRemotas([local], remotas: remotas,
                                                   titulos: ["FRA-652": "Conteúdo"], agora: Date())
        XCTAssertEqual(h.map(\.card), ["FRA-653", "FRA-652", "FRA-651", "FRA-1"])
        XCTAssertEqual(h[1].titulo, "Conteúdo", "título vazio cai no cache de títulos")
        XCTAssertEqual(h[1].selo, "remota ✗")
        XCTAssertTrue(h[1].falha)
        XCTAssertFalse(h[0].falha, "main vermelha não é falha do card")
        XCTAssertEqual(h[2].quando, Date(timeIntervalSince1970: 1300))
        XCTAssertEqual(h[2].url, "https://github.com/o/r/actions/runs/1")
    }

    func testIndicadoresContamAsRemotasDeHoje() {
        let agora = Date()
        let hoje = [
            ProvaRemota(card: "A", lane: "x", inicio: agora.addingTimeInterval(-60), fim: agora, estado: .verde),
            ProvaRemota(card: "B", lane: "x", fim: agora, estado: .vermelho),
            ProvaRemota(card: "C", lane: "x", fim: agora, estado: .mainVermelha),
            ProvaRemota(card: "D", lane: "x", fim: agora.addingTimeInterval(-3 * 86400), estado: .verde),
        ]
        let ind = Indicadores.calcular(linhas: [], execucoes: [], provas: [], semanaAtual: nil, agora: agora,
                                       calendario: Datas.calendarioISO, remotas: hoje)
        XCTAssertEqual(ind.remotasVerdes, 1)
        XCTAssertEqual(ind.remotasVermelhas, 1)
        XCTAssertEqual(ind.provasHoje, 2)
    }

    func testEmCursoSaiDoEstadoDaLane() throws {
        let t = try PastaTemp()
        let json = #"{"card":"fra-652","lane":"deepseek","title":"Conteúdo","started_at":"2026-11-08 14:10:41","log":"/x/l.jsonl","prova_remota_url":"https://github.com/o/r/pull/70","prova_remota_check":"https://github.com/o/r/actions/runs/2","prova_remota_desde":1794150000,"prova_remota_sha":"abc"}"#
        try t.escrever("lane-deepseek.json", json)
        let estado = EstadoLanes.ler(pasta: t.url)
        let em = MontadorPainel.provasRemotasEmCurso(estado.lanes)
        XCTAssertEqual(em.count, 1)
        XCTAssertEqual(em.first?.card, "FRA-652")
        XCTAssertEqual(em.first?.estado, .rodando)
        XCTAssertEqual(em.first?.inicio, Date(timeIntervalSince1970: 1794150000))
        XCTAssertEqual(em.first?.check, "https://github.com/o/r/actions/runs/2")
    }
}
