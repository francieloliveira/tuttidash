import XCTest
@testable import GastoCore

final class ParserLogTests: XCTestCase {
    func testNomeValido() throws {
        let n = try XCTUnwrap(ParserLog.lerNome("FRA-259-grok-20261004-153012.jsonl", calendario: calendarioFixo()))
        XCTAssertEqual(n.id, "FRA-259-grok-20261004-153012")
        XCTAssertEqual(n.card, "FRA-259")
        XCTAssertEqual(n.lane, "grok")
        XCTAssertEqual(n.inicio, "2026-10-04T15:30:12")
        XCTAssertEqual(n.dia, "2026-10-04")
        XCTAssertEqual(n.semana, "2026-W40")
    }

    func testNomeCardMinusculoViraMaiusculo() {
        XCTAssertEqual(ParserLog.lerNome("fra-12-claude-20261005-090000.jsonl")?.card, "FRA-12")
    }

    func testNomesInvalidos() {
        for nome in ["notas.jsonl", "FRA-1-claude-20261005-0900.jsonl", "FRA-1-Claude-20261005-090000.jsonl",
                     "FRA-1-claude-20261005-090000.json", "FRA-1-claude-20261305-090000.jsonl",
                     "FRA-1-claude-20261005-250000.jsonl"] {
            XCTAssertNil(ParserLog.lerNome(nome), nome)
        }
    }

    func testSemanaISONaViradaDoAno() {
        XCTAssertEqual(ParserLog.lerNome("FRA-1-claude-20270101-100000.jsonl", calendario: calendarioFixo())?.semana,
                       "2026-W53")
        XCTAssertEqual(ParserLog.lerNome("FRA-1-claude-20261005-100000.jsonl", calendario: calendarioFixo())?.semana,
                       "2026-W41")
    }

    /// Mesmos resultados do parser.py nas fixtures (conferidos com `gasto.py relatorio --json`).
    func testFixturesIguaisAoPython() throws {
        let rodando: Set<String> = ["FRA-253-claude-20261005-200000.jsonl"]
        func ler(_ nome: String) throws -> Execucao {
            try XCTUnwrap(ParserLog.ler(url: Fixtures.logs.appendingPathComponent(nome), emAndamento: rodando))
        }
        var e = try ler("FRA-248-claude-20260927-230000.jsonl")
        XCTAssertEqual(e.status, .erro); XCTAssertEqual(e.custo, .estimado); XCTAssertEqual(e.custoUSD, 3.02)
        XCTAssertEqual(e.turnos, 55); XCTAssertEqual(e.duracaoMs, 2_400_000); XCTAssertEqual(e.subtipo, "error_max_budget_usd")
        XCTAssertEqual(e.tokensTotal, 2_110_300)

        e = try ler("FRA-250-claude-20261003-101500.jsonl")
        XCTAssertEqual(e.status, .ok); XCTAssertEqual(e.custoUSD, 2.3141); XCTAssertEqual(e.turnos, 42)
        XCTAssertEqual(e.tokensTotal, 1_275_120)

        e = try ler("FRA-259-grok-20261004-153012.jsonl")
        XCTAssertEqual(e.status, .ok); XCTAssertEqual(e.custo, .informado); XCTAssertEqual(e.custoUSD, 0.48)
        XCTAssertEqual(e.turnos, 16); XCTAssertEqual(e.duracaoMs, 175_000)

        // grok OAuth: custo 0 = desconhecido, nunca grátis
        e = try ler("FRA-260-grok-20261004-180000.jsonl")
        XCTAssertEqual(e.status, .ok); XCTAssertEqual(e.custo, .desconhecido); XCTAssertNil(e.custoUSD)
        XCTAssertNil(e.custoConhecido)

        // morta: sem result, lane não aponta mais para esse log; linha de stderr ignorada
        e = try ler("FRA-251-claude-20261005-090000.jsonl")
        XCTAssertEqual(e.status, .morta); XCTAssertNil(e.custoUSD); XCTAssertNil(e.turnos)
        XCTAssertEqual(e.respostasParciais, 2); XCTAssertNil(e.duracaoMs)

        // cancelada
        e = try ler("FRA-252-grok-20261005-140000.jsonl")
        XCTAssertEqual(e.status, .cancelada); XCTAssertEqual(e.erros, ["cancelled"]); XCTAssertEqual(e.turnos, 3)
        XCTAssertNil(e.duracaoMs); XCTAssertEqual(e.custo, .desconhecido); XCTAssertNil(e.tokensTotal)

        // em andamento
        e = try ler("FRA-253-claude-20261005-200000.jsonl")
        XCTAssertEqual(e.status, .emAndamento); XCTAssertEqual(e.respostasParciais, 1); XCTAssertNil(e.custoUSD)
    }

    func testCustoParcialOuIncompletoEhDesconhecido() {
        XCTAssertEqual(ParserLog.classificarCusto(lane: "claude", result: ["total_cost_usd": 1.0, "cost_is_partial": true]).1,
                       .desconhecido)
        XCTAssertEqual(ParserLog.classificarCusto(lane: "grok", result: ["total_cost_usd": 1.0, "usage_is_incomplete": true]).1,
                       .desconhecido)
        XCTAssertEqual(ParserLog.classificarCusto(lane: "claude", result: ["total_cost_usd": true]).1, .desconhecido)
        XCTAssertEqual(ParserLog.classificarCusto(lane: "claude", result: nil).1, .desconhecido)
        XCTAssertEqual(ParserLog.classificarCusto(lane: "claude", result: ["total_cost_usd": 0.5]).1, .estimado)
        XCTAssertEqual(ParserLog.classificarCusto(lane: "grok", result: ["total_cost_usd": 0.5]).1, .informado)
    }

    func testMesmaMensagemContaUmaVezESubagenteFica() {
        let meta = ParserLog.lerNome("FRA-9-claude-20261005-100000.jsonl", calendario: calendarioFixo())!
        let linhas = """
        {"type":"system","subtype":"init","model":"x"}
        {"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}
        {"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}
        {"type":"assistant","parent_tool_use_id":"t1","message":{"id":"sub","usage":{"input_tokens":99}}}
        {"type":"assistant","parent_tool_use_id":"","message":{"id":"m2","usage":{"input_tokens":1}}}
        lixo de stderr
        [1,2]
        """
        let e = ParserLog.interpretar(dados: Data(linhas.utf8), meta: meta, nomeArquivo: "FRA-9-claude-20261005-100000.jsonl",
                                      emAndamento: [], mtime: meta.dataInicio.addingTimeInterval(120), tamanho: 1)
        XCTAssertEqual(e.status, .morta)
        XCTAssertEqual(e.respostasParciais, 2)
        XCTAssertEqual(e.tokensTotal, 16)
        XCTAssertEqual(e.duracaoEstimadaMs, 120_000)
    }

    func testUltimoResultVale() {
        let meta = ParserLog.lerNome("FRA-9-grok-20261005-100000.jsonl", calendario: calendarioFixo())!
        let linhas = """
        {"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"total_cost_usd":0.1}
        {"type":"result","subtype":"success","num_turns":4,"duration_ms":5000,"total_cost_usd":0.25}
        """
        let e = ParserLog.interpretar(dados: Data(linhas.utf8), meta: meta, nomeArquivo: "x", emAndamento: [],
                                      mtime: Date(), tamanho: 1)
        XCTAssertEqual(e.status, .ok); XCTAssertEqual(e.turnos, 4); XCTAssertEqual(e.custoUSD, 0.25)
        XCTAssertEqual(e.duracaoMs, 5000); XCTAssertNil(e.duracaoEstimadaMs)
    }
}
