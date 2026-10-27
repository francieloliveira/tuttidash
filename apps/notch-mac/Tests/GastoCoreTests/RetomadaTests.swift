import Foundation
import XCTest
@testable import GastoCore

final class RetomadaTests: XCTestCase {
    private func linhaInit(sessao: String, cwd: String) -> String {
        #"{"type":"system","subtype":"init","session_id":"\#(sessao)","cwd":"\#(cwd)","model":"m"}"#
    }

    /// Log da lane + worktree com `.lane/finalized`.
    @discardableResult
    private func lane(_ pasta: PastaTemp, log: String, card: String, sessao: String,
                      finalizado: String?) throws -> String {
        let wt = pasta.url.appendingPathComponent("wt/\(card.lowercased())").path
        try pasta.escrever("logs/\(log)", "stderr qualquer\n" + linhaInit(sessao: sessao, cwd: wt) + "\n")
        if let f = finalizado { try pasta.escrever("wt/\(card.lowercased())/.lane/finalized", f + "\n") }
        return wt
    }

    private let agora = data("2026-10-06T22:00:00")

    func testLaneQueFalhouVemComOComandoPronto() throws {
        let p = try PastaTemp()
        let wt = try lane(p, log: "FRA-248-grok-20261006-204333.jsonl", card: "FRA-248", sessao: "01a11399-e338",
                          finalizado: "lane:falhou (sem .lane/result.json válido (agente: cancelada))")
        let r = Retomadas.ler(logsDir: p.url.appendingPathComponent("logs"), cardsRodando: [], agora: agora,
                              calendario: calendarioFixo())
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.card, "FRA-248")
        XCTAssertEqual(r.first?.rotulo, "lane:falhou")
        XCTAssertEqual(r.first?.motivo, "sem .lane/result.json válido (agente: cancelada)")
        XCTAssertEqual(r.first?.comando, "cd \(wt) && grok --resume 01a11399-e338")
    }

    func testClaudeENeedsDono() throws {
        let p = try PastaTemp()
        try lane(p, log: "FRA-13-claude-20261006-201323.jsonl", card: "FRA-13", sessao: "c521bb7f",
                 finalizado: "needs:dono")
        // sem rótulo de dono configurado, não é retomável
        XCTAssertTrue(Retomadas.ler(logsDir: p.url.appendingPathComponent("logs"), cardsRodando: [], agora: agora,
                                    calendario: calendarioFixo()).isEmpty)
        let r = Retomadas.ler(logsDir: p.url.appendingPathComponent("logs"), cardsRodando: [], rotuloDono: "needs:dono",
                              agora: agora, calendario: calendarioFixo())
        XCTAssertEqual(r.first?.rotulo, "needs:dono")
        XCTAssertNil(r.first?.motivo)
        XCTAssertTrue(r.first?.comando.hasSuffix("&& claude --resume c521bb7f") ?? false)
    }

    func testFicamDeForaFechadaRodandoAntigaESemFinalized() throws {
        let p = try PastaTemp()
        try lane(p, log: "FRA-249-claude-20261006-200000.jsonl", card: "FRA-249", sessao: "a",
                 finalizado: "In Review (https://github.com/x/y/pull/52)")
        try lane(p, log: "FRA-250-grok-20261006-200000.jsonl", card: "FRA-250", sessao: "b",
                 finalizado: "lane:falhou (x)")
        try lane(p, log: "FRA-251-grok-20260901-200000.jsonl", card: "FRA-251", sessao: "c",
                 finalizado: "lane:falhou (x)")
        try lane(p, log: "FRA-252-grok-20261006-200000.jsonl", card: "FRA-252", sessao: "d", finalizado: nil)
        let r = Retomadas.ler(logsDir: p.url.appendingPathComponent("logs"), cardsRodando: ["FRA-250"],
                              agora: agora, calendario: calendarioFixo())
        XCTAssertEqual(r, [])
    }

    func testSoOLogMaisNovoDoCardConta() throws {
        let p = try PastaTemp()
        try lane(p, log: "FRA-248-grok-20261006-201330.jsonl", card: "FRA-248", sessao: "velha",
                 finalizado: "lane:falhou (x)")
        try lane(p, log: "FRA-248-grok-20261006-204333.jsonl", card: "FRA-248", sessao: "nova",
                 finalizado: "lane:falhou (x)")
        let r = Retomadas.ler(logsDir: p.url.appendingPathComponent("logs"), cardsRodando: [], agora: agora,
                              calendario: calendarioFixo())
        XCTAssertEqual(r.map(\.sessao), ["nova"])
    }

    func testComandoUsaOCliDaPropriaLane() {
        let r = Retomada(card: "FRA-1", lane: "codex", worktree: "/w", sessao: "s1", desfecho: "lane:falhou (x)",
                         inicio: agora)
        XCTAssertEqual(r.comando, "cd /w && codex --resume s1")
        let desconhecida = Retomada(card: "FRA-2", lane: "umanova", worktree: "/w", sessao: "s2",
                                    desfecho: "lane:falhou (x)", inicio: agora)
        XCTAssertEqual(desconhecida.comando, "cd /w && claude --resume s2")
    }

    func testAspasSoQuandoPrecisa() {
        XCTAssertEqual(Retomadas.aspas("/Users/f/wt/fra-248"), "/Users/f/wt/fra-248")
        XCTAssertEqual(Retomadas.aspas("/a b/it's"), #"'/a b/it'"'"'s'"#)
    }
}
