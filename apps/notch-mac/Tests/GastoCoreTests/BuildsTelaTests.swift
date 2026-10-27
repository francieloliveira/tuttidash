import XCTest
@testable import GastoCore

/// FRA-528: classificação das execuções e coerência entre o lock e a lista de builds.
final class BuildsTelaTests: XCTestCase {
    private func ler(_ nome: String, _ eventos: [String], rodando: Bool = false) -> Execucao {
        let meta = ParserLog.lerNome(nome)!
        let dados = Data((eventos.joined(separator: "\n") + "\n").utf8)
        return ParserLog.interpretar(dados: dados, meta: meta, nomeArquivo: nome,
                                     emAndamento: rodando ? [nome] : [], mtime: meta.dataInicio.addingTimeInterval(60),
                                     tamanho: dados.count)
    }

    let ocFim = [#"{"type":"step_start","sessionID":"s"}"#,
                 #"{"type":"step_finish","sessionID":"s","part":{"reason":"tool-calls","cost":0,"tokens":{"input":10,"output":5,"cache":{"read":100}}}}"#,
                 #"{"type":"text","sessionID":"s","part":{"text":"Card entregue."}}"#]

    func testNomeComHifen() {
        let m = ParserLog.lerNome("FRA-514-opencode-go-20261023-194452.jsonl")
        XCTAssertEqual(m?.card, "FRA-514")
        XCTAssertEqual(m?.lane, "opencode-go")
    }

    func testOpencodeTerminouEhConcluidaEGratis() {
        let ex = ler("FRA-519-opencode-20261023-175926.jsonl", ocFim)
        XCTAssertEqual(ex.status, .ok)
        XCTAssertEqual(ex.status.rotulo, "concluída")
        XCTAssertEqual(ex.custo, .gratis)
        XCTAssertEqual(ex.custoConhecido, 0)
        XCTAssertEqual(ex.tokensTotal, 115)
    }

    func testOpencodeSumiuNoMeioEhMorta() {
        let ex = ler("FRA-1-opencode-20261023-100000.jsonl", [ocFim[0], #"{"type":"tool_use","sessionID":"s"}"#])
        XCTAssertEqual(ex.status, .morta)
    }

    func testOpencodeRodando() {
        XCTAssertEqual(ler("FRA-1-opencode-20261023-100000.jsonl", [ocFim[0]], rodando: true).status, .emAndamento)
    }

    func testOpencodeGoErroDeRegiaoFalhou() {
        let ex = ler("FRA-514-opencode-go-20261023-194452.jsonl", [ocFim[0],
            #"{"type":"error","sessionID":"s","error":{"type":"provider.invalid-request","message":"This Go model requires Global regions."}}"#])
        XCTAssertEqual(ex.status, .erro)
        XCTAssertEqual(ex.status.rotulo, "falhou")
        XCTAssertEqual(ex.custo, .plano)
    }

    func testAbortadoEhCancelada() {
        let ex = ler("FRA-1-opencode-20261023-100000.jsonl", [ocFim[0],
            #"{"type":"error","sessionID":"s","error":{"name":"MessageAbortedError","message":"aborted"}}"#])
        XCTAssertEqual(ex.status, .cancelada)
    }

    func testCodex() {
        XCTAssertEqual(ler("FRA-517-codex-20261023-154136.jsonl", [#"{"type":"thread.started"}"#,
            #"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#]).status, .erro)
        let ok = ler("FRA-2-codex-20261023-100000.jsonl", [#"{"type":"thread.started"}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":4}}"#])
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(ok.custo, .plano)
    }

    func testClaudeCanceladoEClaudeSemResultMorta() {
        XCTAssertEqual(ler("FRA-3-claude-20261023-100000.jsonl",
                           [#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"cancelled"}"#]).status, .cancelada)
        XCTAssertEqual(ler("FRA-3-claude-20261023-100000.jsonl", [#"{"type":"assistant","message":{"id":"m"}}"#]).status, .morta)
    }

    func testCustoDaLinha() {
        var b = BuildPainel(numero: 1, card: "FRA-1", lane: "opencode", inicio: nil, status: .ok, duracaoMs: nil, custoUSD: 0)
        b.custo = .gratis
        XCTAssertEqual(b.textoCusto(.usd), "grátis")
        b.custo = .desconhecido; b.custoUSD = nil
        XCTAssertEqual(b.textoCusto(.usd), "—")
    }

    // MARK: lock x lista

    private func execucao(_ card: String, _ lane: String, _ inicio: String, _ status: StatusExecucao) -> Execucao {
        Execucao(id: "\(card)-\(lane)-\(inicio)", card: card, lane: lane, inicio: inicio, dia: String(inicio.prefix(10)),
                 semana: "2026-W43", status: status)
    }

    func testLinhaDoDonoDoLockApareceNaProva() {
        let agora = data("2026-10-23T19:00:00")
        let execs = [execucao("FRA-513", "opencode", "2026-10-23T18:47:42", .ok),
                     execucao("FRA-513", "opencode", "2026-10-23T17:00:00", .erro),
                     execucao("FRA-519", "opencode", "2026-10-23T17:59:26", .ok)]
        let b = Indicadores.buildsDeHoje(execs, ordinais: [:], agora: agora, calendario: calendarioFixo(),
                                         lockLane: "opencode", lockCard: "FRA-513")
        XCTAssertEqual(b.filter(\.naProva).count, 1, "só a execução mais nova do dono do lock")
        XCTAssertEqual(b.first { $0.naProva }?.inicio, Datas.lerLocal("2026-10-23T18:47:42", calendario: calendarioFixo()))
        XCTAssertEqual(b.first { $0.naProva }?.textoStatus, "na prova")
        XCTAssertEqual(ResumoLock.dono(lockLane: "opencode", lockCard: "FRA-513"), "opencode · FRA-513 (prova compilando)")
        XCTAssertNil(ResumoLock.contexto(lockLane: "opencode", rodando: []))
    }

    func testLockLivreExplicaALaneNaFaseDoAgente() {
        let rodando = LinhaLane(lane: "opencode", estado: .rodando, card: "FRA-513", descricao: "", detalhe: "",
                                pct: nil, janela: nil, plano: nil, segundosNoCard: 60)
        let b = Indicadores.buildsDeHoje([execucao("FRA-513", "opencode", "2026-10-23T18:47:42", .emAndamento)],
                                         ordinais: [:], agora: data("2026-10-23T19:00:00"), calendario: calendarioFixo())
        XCTAssertEqual(b.first?.textoStatus, "rodando")
        XCTAssertFalse(b.contains { $0.naProva })
        XCTAssertEqual(ResumoLock.dono(lockLane: nil, lockCard: nil), "Livre")
        XCTAssertEqual(ResumoLock.contexto(lockLane: nil, rodando: [rodando]),
                       "Na fase do agente: opencode · FRA-513. O lock só é pego na prova.")
    }

    func testDesfechoDoDispatcher() {
        let f = [FechamentoLog(quando: "2026-10-23 18:07:02", lane: "opencode", card: "FRA-519",
                               resto: "In Review (https://github.com/x/y/pull/235)"),
                 FechamentoLog(quando: "2026-10-23 19:54:53", lane: "opencode-go", card: "FRA-514",
                               resto: "aguardando o limite da conta até 20:54"),
                 FechamentoLog(quando: "2026-10-23 15:17:00", lane: "opencode", card: "FRA-515", resto: "needs:dono")]
        let b = Indicadores.buildsDeHoje([execucao("FRA-519", "opencode", "2026-10-23T17:59:26", .ok),
                                          execucao("FRA-514", "opencode-go", "2026-10-23T19:46:28", .erro)],
                                         ordinais: [:], agora: data("2026-10-23T20:00:00"), calendario: calendarioFixo(),
                                         fechamentos: f)
        XCTAssertEqual(b.first { $0.card == "FRA-519" }?.desfecho, "PR aberto")
        XCTAssertEqual(b.first { $0.card == "FRA-514" }?.desfecho, "limite da conta")
        XCTAssertEqual(MontadorPainel.esperandoVoce(f), 1)
    }

    func testFechamentoDeLaneComHifen() {
        let (_, f) = LeitorLogDispatcher.ler(texto: "2026-10-23 19:54:53 lane:opencode-go FECHOU FRA-514 → aguardando o limite\n")
        XCTAssertEqual(f.first?.lane, "opencode-go")
    }

    func testUltimasLinhasDoLog() {
        var snap = MontadorPainel.montar(entrada: .vazia, execucoes: [])
        snap.logTexto = (1...15).map { "linha \($0)" }.joined(separator: "\n")
        XCTAssertEqual(snap.ultimasLinhasLog(10).first, "linha 6")
        XCTAssertEqual(snap.ultimasLinhasLog(10).count, 10)
    }

    func testEstadoDeLaneComHifen() {
        XCTAssertTrue(EstadoLanes.ehEstadoDeLane(nomeArquivo: "lane-opencode-go.json",
                                                 dados: ["lane": "opencode-go", "card": "FRA-514", "log": "x.jsonl"]))
    }
}

final class ContasLaneHifenTests: XCTestCase {
    func testContaOpencodeGoHabilitaALane() throws {
        let t = try PastaTemp()
        try t.escrever("Library/Application Support/TuttiDash/config.json",
                       #"{"contas":[{"id":"opencode","tipo":"opencode"},{"id":"opencode-go","tipo":"opencode-go"}]}"#)
        let cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(cfg.lanesHabilitadas?.contains("opencode-go"), Agentes.ordem.contains("opencode-go"))
        XCTAssertEqual(cfg.lanesHabilitadas?.contains("opencode"), true)
    }
}
