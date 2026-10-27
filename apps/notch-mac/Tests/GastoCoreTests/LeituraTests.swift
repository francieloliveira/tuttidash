import XCTest
@testable import GastoCore

final class LedgerTests: XCTestCase {
    func testLedgerIgnoraLinhasInvalidasEDesconhecidoNaoViraZero() {
        let texto = """
        {"id":"FRA-1-claude-20261005-100000","card":"FRA-1","lane":"claude","inicio":"2026-10-05T10:00:00","dia":"2026-10-05","semana":"2026-W41","status":"ok","custo":"estimado","custo_usd":1.5,"turnos":10,"duracao_ms":60000,"fonte":{"tamanho":10,"mtime":1.234}}
        nao é json
        {"sem_id":true}
        {"id":"FRA-2-grok-20261005-110000","card":"FRA-2","lane":"grok","inicio":"2026-10-05T11:00:00","dia":"2026-10-05","semana":"2026-W41","status":"ok","custo":"desconhecido","custo_usd":null,"parcial":null}
        {"id":"FRA-3-grok-20261005-120000","card":"FRA-3","lane":"grok","inicio":"2026-10-05T12:00:00","dia":"2026-10-05","semana":"2026-W41","status":"morta","custo":"informado","custo_usd":null,"parcial":{"respostas":7,"tokens":{"total":99}}}

        """
        let r = Ledger.interpretar(dados: Data(texto.utf8))
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r["FRA-1-claude-20261005-100000"]?.custoConhecido, 1.5)
        XCTAssertEqual(r["FRA-1-claude-20261005-100000"]?.fonte, Fonte(tamanho: 10, mtime: 1.234))
        XCTAssertNil(r["FRA-2-grok-20261005-110000"]?.custoConhecido)
        XCTAssertEqual(r["FRA-2-grok-20261005-110000"]?.custo, .desconhecido)
        // custo_usd null com tipo "informado" também é desconhecido (como report._soma)
        XCTAssertEqual(r["FRA-3-grok-20261005-120000"]?.custo, .desconhecido)
        XCTAssertEqual(r["FRA-3-grok-20261005-120000"]?.respostasParciais, 7)
        XCTAssertEqual(r["FRA-3-grok-20261005-120000"]?.tokensTotal, 99)
    }

    func testLedgerAusente() {
        XCTAssertTrue(Ledger.carregar(url: URL(fileURLWithPath: "/nao/existe/ledger.jsonl")).isEmpty)
    }
}

final class EstadoTests: XCTestCase {
    func testFixtureIgnoraLaneMcp() {
        let e = EstadoLanes.ler(pasta: Fixtures.estado)
        XCTAssertEqual(e.lanes.count, 1)
        XCTAssertEqual(e.lanes.first?.lane, "claude")
        XCTAssertEqual(e.lanes.first?.card, "FRA-253")
        XCTAssertEqual(e.lanes.first?.startedAt, "2026-10-05 20:00:00")
        XCTAssertEqual(e.logsEmAndamento, ["FRA-253-claude-20261005-200000.jsonl"])
        XCTAssertEqual(e.heartbeat?.at, "2026-10-05 20:30:00")
        XCTAssertEqual(e.heartbeat?.dryRun, false)
        XCTAssertEqual(e.heartbeat?.habilitadas, ["claude", "grok"])
    }

    func testFormaDoEstado() {
        let ok: [String: Any] = ["lane": "grok", "card": "FRA-1", "log": "/x/FRA-1-grok-20261005-100000.jsonl"]
        XCTAssertTrue(EstadoLanes.ehEstadoDeLane(nomeArquivo: "lane-grok.json", dados: ok))
        XCTAssertFalse(EstadoLanes.ehEstadoDeLane(nomeArquivo: "lane-claude.json", dados: ok))   // lane != nome
        XCTAssertFalse(EstadoLanes.ehEstadoDeLane(nomeArquivo: "lane-mcp.json", dados: ["mcpServers": [:]]))
        XCTAssertFalse(EstadoLanes.ehEstadoDeLane(nomeArquivo: "lane-grok.json",
                                                  dados: ["lane": "grok", "card": "", "log": "x"]))
        XCTAssertFalse(EstadoLanes.ehEstadoDeLane(nomeArquivo: "lane-Grok.json", dados: ok))
        XCTAssertEqual(EstadoLanes.laneRodando(nomeArquivo: "lane-grok.json",
                                               dados: ["lane": "grok", "card": "FRA-1", "log": "C:\\a\\b.jsonl"])?.nomeLog,
                       "b.jsonl")
    }

    func testPastaAusente() {
        let e = EstadoLanes.ler(pasta: URL(fileURLWithPath: "/nao/existe"))
        XCTAssertNil(e.heartbeat); XCTAssertTrue(e.lanes.isEmpty)
    }
}

final class ConfiguracaoTests: XCTestCase {
    func testPadroesDoMacSemConfig() throws {
        let t = try PastaTemp()
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.logsDir.path, t.url.appendingPathComponent("Library/Logs/TranscentIA/lanes").path)
        XCTAssertEqual(c.stateDir.path, t.url.appendingPathComponent(".transcentia/lanes").path)
        XCTAssertEqual(c.ledger.path, t.url.appendingPathComponent(".transcentia/tools/ledger.jsonl").path)
        XCTAssertNil(c.tetoSemanalUSD)
        XCTAssertEqual(c.avisoPct, 80)
        XCTAssertFalse(c.arquivoConfigExiste)
        XCTAssertNil(c.erro)
    }

    func testArquivoDeConfigEAmbiente() throws {
        let t = try PastaTemp()
        try t.escrever(".transcentia/tools/config.json",
                       #"{"logs_dir":"~/logs","ledger":"$BASE/l.jsonl","teto_semanal_usd":28,"aviso_pct":"75"}"#)
        var c = Configuracao.resolver(ambiente: ["BASE": "/tmp/base"], home: t.url)
        XCTAssertTrue(c.arquivoConfigExiste)
        XCTAssertEqual(c.logsDir.path, t.url.appendingPathComponent("logs").path)
        XCTAssertEqual(c.ledger.path, "/tmp/base/l.jsonl")
        XCTAssertEqual(c.tetoSemanalUSD, 28)
        XCTAssertEqual(c.avisoPct, 75)
        // ambiente vence o arquivo
        c = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_TETO": "50", "TRANSCENTIA_LANES_LOGS": "%DADOS%/x",
                                             "DADOS": "/d"], home: t.url)
        XCTAssertEqual(c.tetoSemanalUSD, 50)
        XCTAssertEqual(c.logsDir.path, "/d/x")
        // %VAR% sem a variável no ambiente fica como está
        c = Configuracao.resolver(ambiente: ["TRANSCENTIA_LANES_LOGS": "/a/%NADA%/x"], home: t.url)
        XCTAssertEqual(c.logsDir.path, "/a/%NADA%/x")
    }

    func testTetoZeroOuInvalido() throws {
        let t = try PastaTemp()
        try t.escrever(".transcentia/tools/config.json", #"{"teto_semanal_usd":0}"#)
        XCTAssertNil(Configuracao.resolver(ambiente: [:], home: t.url).tetoSemanalUSD)
        try t.escrever(".transcentia/tools/config.json", #"{"teto_semanal_usd":"abc"}"#)
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertNil(c.tetoSemanalUSD)
        XCTAssertNotNil(c.erro)
        try t.escrever(".transcentia/tools/config.json", "{ quebrado")
        XCTAssertNotNil(Configuracao.resolver(ambiente: [:], home: t.url).erro)
    }

    func testContasDefinemLanesHabilitadas() throws {
        let t = try PastaTemp()
        XCTAssertNil(Configuracao.resolver(ambiente: [:], home: t.url).lanesHabilitadas)
        try t.escrever("cfg.json", #"{"contas":[{"id":"g","tipo":"grok","rotulo":"G"}]}"#)
        let c = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_CONFIG": t.url.appendingPathComponent("cfg.json").path],
                                      home: t.url)
        XCTAssertEqual(c.lanesHabilitadas, ["grok"])
    }

    func testConfigIndicadaPorAmbienteQueNaoExiste() throws {
        let t = try PastaTemp()
        let c = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_CONFIG": "/nao/existe.json"], home: t.url)
        XCTAssertNotNil(c.erro)
    }
}

final class CarregadorTests: XCTestCase {
    /// Ledger guarda o histórico (log apagado continua); log novo ou alterado é lido em Swift;
    /// log apontado por lane-<lane>.json vira em andamento. Nada é gravado.
    func testJuntaLedgerELogs() throws {
        let t = try PastaTemp()
        let logs = t.url.appendingPathComponent("logs")
        let estado = t.url.appendingPathComponent("estado")
        try t.escrever("logs/FRA-10-claude-20261005-100000.jsonl",
                       #"{"type":"result","subtype":"success","num_turns":3,"duration_ms":1000,"total_cost_usd":1.25}"#)
        try t.escrever("logs/FRA-11-grok-20261005-110000.jsonl",
                       #"{"type":"assistant","message":{"id":"a","usage":{"input_tokens":5}}}"#)
        try t.escrever("logs/notas.txt", "x")
        try t.escrever("estado/lane-grok.json",
                       #"{"lane":"grok","card":"FRA-11","log":"/x/FRA-11-grok-20261005-110000.jsonl","started_at":"2026-10-05 11:00:00"}"#)
        try t.escrever("estado/lane-mcp.json", #"{"mcpServers":{}}"#)
        // ledger: um log que não existe mais e uma versão antiga do FRA-10 (fonte diferente)
        let ledger = try t.escrever("tools/ledger.jsonl", """
        {"id":"FRA-9-claude-20261001-100000","card":"FRA-9","lane":"claude","inicio":"2026-10-01T10:00:00","dia":"2026-10-01","semana":"2026-W40","status":"ok","custo":"estimado","custo_usd":2.0,"fonte":{"tamanho":1,"mtime":1}}
        {"id":"FRA-10-claude-20261005-100000","card":"FRA-10","lane":"claude","inicio":"2026-10-05T10:00:00","dia":"2026-10-05","semana":"2026-W41","status":"em_andamento","custo":"desconhecido","custo_usd":null,"fonte":{"tamanho":1,"mtime":1}}

        """)
        let antes = try Data(contentsOf: ledger)
        var cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        cfg.logsDir = logs; cfg.stateDir = estado; cfg.ledger = ledger

        let c = Carregador()
        let r = c.carregar(config: cfg)
        let porId = Dictionary(uniqueKeysWithValues: r.execucoes.map { ($0.id, $0) })
        XCTAssertEqual(r.execucoes.count, 3)
        XCTAssertEqual(porId["FRA-9-claude-20261001-100000"]?.custoConhecido, 2.0)
        XCTAssertEqual(porId["FRA-10-claude-20261005-100000"]?.status, .ok)
        XCTAssertEqual(porId["FRA-10-claude-20261005-100000"]?.custoConhecido, 1.25)
        XCTAssertEqual(porId["FRA-11-grok-20261005-110000"]?.status, .emAndamento)
        XCTAssertEqual(r.lidosDosLogs, 2)
        XCTAssertEqual(r.estado.lanes.map(\.lane), ["grok"])

        // segunda leitura sem mudança: vem do cache, nada relido
        let r2 = c.carregar(config: cfg)
        XCTAssertEqual(r2.lidosDosLogs, 0)
        XCTAssertEqual(r2.execucoes, r.execucoes)
        // só leitura: o ledger não mudou
        XCTAssertEqual(try Data(contentsOf: ledger), antes)
    }

    /// Toggle geral (FRA-372): lane desligada não entra em gasto, estado nem retomadas.
    func testLanesDesabilitadasNaoEntramEmNada() throws {
        let t = try PastaTemp()
        try t.escrever("logs/FRA-10-claude-20261005-100000.jsonl",
                       #"{"type":"result","subtype":"success","total_cost_usd":1.0}"#)
        try t.escrever("logs/FRA-11-grok-20261005-110000.jsonl",
                       #"{"type":"result","subtype":"success","total_cost_usd":2.0}"#)
        try t.escrever("estado/lane-grok.json",
                       #"{"lane":"grok","card":"FRA-11","log":"/x/FRA-11-grok-20261005-110000.jsonl"}"#)
        var cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        cfg.logsDir = t.url.appendingPathComponent("logs"); cfg.stateDir = t.url.appendingPathComponent("estado")
        cfg.ledger = t.url.appendingPathComponent("tools/ledger.jsonl")
        XCTAssertNil(cfg.lanesHabilitadas, "sem chave contas: valem todas")

        cfg.lanesHabilitadas = ["claude"]
        let r = Carregador().carregar(config: cfg)
        XCTAssertEqual(r.execucoes.map(\.lane), ["claude"])
        XCTAssertTrue(r.estado.lanes.isEmpty)
        XCTAssertTrue(r.retomadas.allSatisfy { $0.lane == "claude" })
    }

    func testLedgerEmDiaNaoReleLog() throws {
        let t = try PastaTemp()
        let log = try t.escrever("logs/FRA-10-claude-20261005-100000.jsonl",
                                 #"{"type":"result","subtype":"success","total_cost_usd":9.99}"#)
        let attrs = try FileManager.default.attributesOfItem(atPath: log.path)
        let tam = (attrs[.size] as! NSNumber).intValue
        let mtime = ((attrs[.modificationDate] as! Date).timeIntervalSince1970 * 1000).rounded() / 1000
        // o ledger diz 1.00 com a mesma fonte: vale o ledger (é o que o Python gravou)
        let ledger = try t.escrever("tools/ledger.jsonl",
            #"{"id":"FRA-10-claude-20261005-100000","card":"FRA-10","lane":"claude","inicio":"2026-10-05T10:00:00","dia":"2026-10-05","semana":"2026-W41","status":"ok","custo":"estimado","custo_usd":1.0,"fonte":{"tamanho":\#(tam),"mtime":\#(mtime)}}"# + "\n")
        var cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        cfg.logsDir = t.url.appendingPathComponent("logs"); cfg.stateDir = t.url.appendingPathComponent("estado")
        cfg.ledger = ledger
        let r = Carregador().carregar(config: cfg)
        XCTAssertEqual(r.lidosDosLogs, 0)
        XCTAssertEqual(r.execucoes.first?.custoConhecido, 1.0)
    }

    func testFixturesDoRepoBatemComOPython() {
        var cfg = Configuracao.resolver(ambiente: [:], home: URL(fileURLWithPath: "/nao/existe"))
        cfg.logsDir = Fixtures.logs; cfg.stateDir = Fixtures.estado
        let r = Carregador().carregar(config: cfg)
        XCTAssertFalse(r.ledgerExiste)
        XCTAssertEqual(r.execucoes.count, 7)   // notas.jsonl fica de fora
        let conhecido = r.execucoes.compactMap(\.custoConhecido).reduce(0, +)
        XCTAssertEqual(conhecido, 5.8141, accuracy: 1e-9)   // total.custo_conhecido_usd do relatorio --json
        XCTAssertEqual(r.execucoes.filter { $0.custoConhecido == nil }.count, 4)
    }
}
