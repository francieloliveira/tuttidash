import XCTest
@testable import GastoCore

/// FRA-580: o ciclo de 30 s só relê o disco quando algum arquivo vigiado mudou.
final class LeituraDiscoTests: XCTestCase {
    /// Logs em `Logs/lanes`, estado em `estado`, ledger em `tools`; tudo dentro da pasta do teste.
    private func config(_ t: PastaTemp) throws -> Configuracao {
        try t.escrever("Logs/lanes/FRA-10-claude-20261005-100000.jsonl",
                       #"{"type":"result","subtype":"success","total_cost_usd":1.0}"#)
        try t.escrever("Logs/lanes-dispatcher.log", "2026-10-05 10:00:00 ciclo\n")
        try t.escrever("estado/planos.json", "{}")
        var cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        cfg.logsDir = t.url.appendingPathComponent("Logs/lanes")
        cfg.stateDir = t.url.appendingPathComponent("estado")
        cfg.ledger = t.url.appendingPathComponent("tools/ledger.jsonl")
        return cfg
    }

    func testNadaMudouPulaLeitura() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        XCTAssertFalse(primeira.pulou)
        XCTAssertEqual(primeira.leitura.resultado.execucoes.map(\.card), ["FRA-10"])

        let segunda = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        XCTAssertTrue(segunda.pulou)
        XCTAssertEqual(segunda.leitura.lidaEm, agora, "reaproveitada: continua a leitura de antes")
        XCTAssertEqual(segunda.leitura.resultado.execucoes, primeira.leitura.resultado.execucoes)
    }

    func testLogAlteradoRele() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        try t.escrever("Logs/lanes/FRA-10-claude-20261005-100000.jsonl",
                       #"{"type":"result","subtype":"success","total_cost_usd":2.5}"#)
        let segunda = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        XCTAssertFalse(segunda.pulou)
        XCTAssertEqual(segunda.leitura.resultado.execucoes.first?.custoConhecido, 2.5)
        XCTAssertEqual(segunda.leitura.lidaEm, agora + 30)
    }

    func testArquivoNovoOuApagadoRele() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        let pausa = try t.escrever("estado/PAUSE", "")
        let segunda = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        XCTAssertFalse(segunda.pulou)
        XCTAssertTrue(segunda.leitura.entrada.pausa)

        try FileManager.default.removeItem(at: pausa)
        let terceira = LeituraDisco.ler(config: cfg, carregador: c, anterior: segunda.leitura, agora: agora + 60)
        XCTAssertFalse(terceira.pulou)
        XCTAssertFalse(terceira.leitura.entrada.pausa)
    }

    func testLogDoDispatcherReleOutroLogDaPastaNao() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        try t.escrever("Logs/outro-bot.log", "barulho que o painel não lê\n")
        let segunda = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        XCTAssertTrue(segunda.pulou)

        try t.escrever("Logs/lanes-dispatcher.log", "2026-10-05 10:00:00 ciclo\n2026-10-05 10:01:00 ciclo\n")
        let terceira = LeituraDisco.ler(config: cfg, carregador: c, anterior: segunda.leitura, agora: agora + 60)
        XCTAssertFalse(terceira.pulou)
        XCTAssertTrue(terceira.leitura.entrada.logTexto.contains("10:01:00"))
    }

    /// A prova grava no `.lane` do worktree, fora da pasta de estado: o carimbo vigia essa pasta.
    func testProvaNoWorktreeRele() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let worktree = t.url.appendingPathComponent("wt")
        try t.escrever("estado/lane-claude.json", """
            {"lane":"claude","card":"FRA-12","log":"/x/FRA-12-claude-20261005-120000.jsonl","worktree":"\(worktree.path)"}
            """)
        try t.escrever("wt/.lane/proof_started", "1759676400")
        try t.escrever("wt/.lane/proof.log", "Test Suite started\n")
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        XCTAssertEqual(primeira.leitura.entrada.pastasLane.map(\.lastPathComponent), [".lane"])
        // a primeira leitura ainda não conhecia o worktree; a partir da segunda o carimbo o inclui
        let segunda = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        let terceira = LeituraDisco.ler(config: cfg, carregador: c, anterior: segunda.leitura, agora: agora + 60)
        XCTAssertTrue(terceira.pulou)

        try t.escrever("wt/.lane/proof.log", "Test Suite started\nExecuted 3 tests, with 0 failures\n")
        let quarta = LeituraDisco.ler(config: cfg, carregador: c, anterior: terceira.leitura, agora: agora + 90)
        XCTAssertFalse(quarta.pulou)
        XCTAssertTrue(quarta.leitura.entrada.provas.first?.log.contains("Executed 3 tests") ?? false)
    }

    /// «Atualizar agora» e abrir o painel: lê mesmo sem mudança.
    func testForcarSempreLe() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        let forcada = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, forcar: true,
                                       agora: agora + 1)
        XCTAssertFalse(forcada.pulou)
        XCTAssertEqual(forcada.leitura.lidaEm, agora + 1)
    }

    func testConfigMudadaRele() throws {
        let t = try PastaTemp()
        var cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        cfg.lanesHabilitadas = ["grok"]
        let segunda = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        XCTAssertFalse(segunda.pulou)
        XCTAssertTrue(segunda.leitura.resultado.execucoes.isEmpty)
    }

    func testLeituraVelhaRele() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let c = Carregador()
        let agora = Date()
        let politica = PoliticaAtualizacao(idadeMaximaLeitura: 120)
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, politica: politica, agora: agora)
        let antes = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, politica: politica,
                                     agora: agora + 119)
        XCTAssertTrue(antes.pulou)
        let depois = LeituraDisco.ler(config: cfg, carregador: c, anterior: antes.leitura, politica: politica,
                                      agora: agora + 120)
        XCTAssertFalse(depois.pulou)
        // relógio que voltou: não confia na leitura guardada
        let voltou = LeituraDisco.ler(config: cfg, carregador: c, anterior: depois.leitura, politica: politica,
                                      agora: agora)
        XCTAssertFalse(voltou.pulou)
    }

    /// O leitor só guarda limite de conta futuro; quando ele vence, a leitura guardada caduca.
    func testLimiteDeContaVencidoRele() throws {
        let t = try PastaTemp()
        let cfg = try config(t)
        let agora = Date()
        try t.escrever("estado/limite-claude.json", #"{"until":\#(agora.timeIntervalSince1970 + 60)}"#)
        let c = Carregador()
        let primeira = LeituraDisco.ler(config: cfg, carregador: c, anterior: nil, agora: agora)
        XCTAssertNotNil(primeira.leitura.entrada.limitesAte["claude"])
        let antes = LeituraDisco.ler(config: cfg, carregador: c, anterior: primeira.leitura, agora: agora + 30)
        XCTAssertTrue(antes.pulou)
        let depois = LeituraDisco.ler(config: cfg, carregador: c, anterior: antes.leitura, agora: agora + 61)
        XCTAssertFalse(depois.pulou)
        XCTAssertNil(depois.leitura.entrada.limitesAte["claude"])
    }
}

final class CarimboArquivosTests: XCTestCase {
    func testMesmoDiscoMesmoCarimbo() throws {
        let t = try PastaTemp()
        try t.escrever("a/x.json", "{}")
        try t.escrever("b.log", "linha\n")
        func carimbo() -> CarimboArquivos {
            var c = CarimboArquivos()
            c.marcar(t.url.appendingPathComponent("a"))
            c.marcar(t.url.appendingPathComponent("b.log"))
            c.marcar(t.url.appendingPathComponent("nao-existe"))
            return c
        }
        XCTAssertEqual(carimbo(), carimbo())
        XCTAssertEqual(carimbo().marcas.count, 2)
    }

    func testDataDeModificacaoSozinhaMudaOCarimbo() throws {
        let t = try PastaTemp()
        let arquivo = try t.escrever("a/x.json", "{}")
        var antes = CarimboArquivos()
        antes.marcar(t.url.appendingPathComponent("a"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)],
                                              ofItemAtPath: arquivo.path)
        var depois = CarimboArquivos()
        depois.marcar(t.url.appendingPathComponent("a"))
        XCTAssertNotEqual(antes, depois)
    }

    func testFiltroDeItensDaPasta() throws {
        let t = try PastaTemp()
        try t.escrever("p/quero.log", "1")
        func carimbo() -> CarimboArquivos {
            var c = CarimboArquivos()
            c.marcar(t.url.appendingPathComponent("p")) { $0.hasPrefix("quero") }
            return c
        }
        let antes = carimbo()
        try t.escrever("p/ignoro.log", "2")
        XCTAssertEqual(carimbo(), antes)
        try t.escrever("p/quero.log", "12")
        XCTAssertNotEqual(carimbo(), antes)
    }

    /// Pasta de estado apontada por link simbólico: vale o conteúdo do destino.
    func testSegueLinkSimbolico() throws {
        let t = try PastaTemp()
        try t.escrever("real/heartbeat.json", "{}")
        let link = t.url.appendingPathComponent("estado")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.url.appendingPathComponent("real"))
        var antes = CarimboArquivos()
        antes.marcar(link)
        XCTAssertEqual(antes.marcas.count, 1)
        try t.escrever("real/heartbeat.json", #"{"at":"agora"}"#)
        var depois = CarimboArquivos()
        depois.marcar(link)
        XCTAssertNotEqual(antes, depois)
    }
}
