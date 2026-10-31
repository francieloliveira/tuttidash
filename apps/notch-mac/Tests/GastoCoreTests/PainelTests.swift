import XCTest
@testable import GastoCore

final class PainelLeitoresTests: XCTestCase {
    func testMedidaAceitaPercentualNulo() {
        let json = #"{"at":1700000000,"m":{"claude":[100,"semana"],"codex":[null,"mês"],"opencode":[35.5,"5 h"]}}"#
        let medidas = LeitorMedida.ler(dados: Data(json.utf8))
        XCTAssertEqual(medidas.map(\.lane), ["claude", "codex", "opencode"])
        XCTAssertEqual(medidas[0].pct, 100)
        XCTAssertEqual(medidas[0].janela, "semana")
        XCTAssertNil(medidas[1].pct)
        XCTAssertEqual(medidas[2].pct, 35.5)
        XCTAssertTrue(LeitorMedida.ler(dados: Data("[]".utf8)).isEmpty)
    }

    func testPlanosNaoInventaValorDesconhecido() {
        let json = #"{"claude":"pago","codex":"Grátis","opencode":{"plano":"free"},"grok":"enterprise","outro":"pago"}"#
        let planos = LeitorPlanos.ler(dados: Data(json.utf8))
        XCTAssertEqual(planos["claude"], .pago)
        XCTAssertEqual(planos["codex"], .free)
        XCTAssertEqual(planos["opencode"], .free)
        XCTAssertNil(planos["grok"])
        XCTAssertNil(planos["outro"])
    }

    func testStrikesSemLimiteNaoViraTres() {
        let comLimite = LeitorStrikes.ler(dados: Data(#"{"strikes":1,"max":3,"motivos":["caiu"]}"#.utf8))
        XCTAssertEqual(comLimite, StrikesOpencode(atual: 1, limite: 3, motivos: ["caiu"]))
        let semLimite = LeitorStrikes.ler(dados: Data(#"{"atual":2}"#.utf8))
        XCTAssertEqual(semLimite?.atual, 2)
        XCTAssertNil(semLimite?.limite)
        XCTAssertNil(LeitorStrikes.ler(dados: Data("nao json".utf8)))
    }

    func testLogDoDispatcherExtraiFilaEProxima() {
        let texto = """
        2026-10-16 21:06:02 MODO real · lanes: claude, codex, opencode
        2026-10-16 21:08:02 lane:opencode ocupada com FRA-399
        2026-10-16 21:08:02 lane:claude livre → fila vazia: precisa de card pronto
        2026-10-16 21:08:02 lane:codex → ASSUMIRIA FRA-405 (esforço baixo: ; branch x); fila: FRA-406, FRA-407
        2026-10-16 21:08:03 lane:claude segura FRA-404: conta em 100% (semana)
        2026-10-16 21:09:00 lane:opencode FECHOU FRA-401 → In Review (https://github.com/org/repo/pull/158)
        """
        let lido = LeitorLogDispatcher.ler(texto: texto)
        XCTAssertEqual(lido.decisao.fila, ["FRA-405", "FRA-406", "FRA-407"])
        XCTAssertEqual(lido.decisao.proxima, "segura FRA-404 na claude")
        XCTAssertEqual(lido.decisao.modo, "MODO real · lanes: claude, codex, opencode")
        XCTAssertEqual(lido.fechamentos.map(\.card), ["FRA-401"])
        XCTAssertEqual(lido.fechamentos.first?.lane, "opencode")
        XCTAssertEqual(MontadorPainel.pr(lido.fechamentos[0].resto), "PR #158")
        XCTAssertEqual(EnderecosPainel.urlPR(lido.fechamentos[0].resto), "https://github.com/org/repo/pull/158")
    }

    func testURLDoPRSoAceitaGitHubDoFechamento() {
        XCTAssertEqual(
            EnderecosPainel.urlPR("In Review (https://github.com/exemplo/projeto/pull/241)"),
            "https://github.com/exemplo/projeto/pull/241")
        XCTAssertEqual(
            EnderecosPainel.urlPR("https://github.com/org/repo/pull/158/files"),
            "https://github.com/org/repo/pull/158")
        XCTAssertNil(EnderecosPainel.urlPR("→ In Review"))
        XCTAssertNil(EnderecosPainel.urlPR("https://example.com/org/repo/pull/9"))
        XCTAssertNil(EnderecosPainel.urlPR("fechou #241"))
    }

    func testIssueLinearUsaWorkspaceDoApp() {
        XCTAssertEqual(
            EnderecosPainel.issueLinear(workspace: "https://linear.app/acme/", card: "FRA-527")?.absoluteString,
            "https://linear.app/acme/issue/FRA-527")
        XCTAssertEqual(
            EnderecosPainel.issueLinear(workspace: "https://linear.app/acme", card: "FRA-1")?.absoluteString,
            "https://linear.app/acme/issue/FRA-1")
        XCTAssertNil(EnderecosPainel.issueLinear(workspace: "", card: "FRA-527"))
        XCTAssertNil(EnderecosPainel.issueLinear(workspace: "https://linear.app/acme", card: ""))
    }

    func testFilaProntaSobreviveALinhaSoltaDepois() {
        let texto = """
        2026-10-16 21:08:02 lane:opencode ocupada com FRA-399
        2026-10-16 21:08:02 lane:codex → ASSUMIRIA FRA-405 (esforço baixo: ; branch x); fila: —
        2026-10-16 21:08:02 fora: —
        2026-10-16 21:20:00 lane:codex limite da conta liberou; volta a assumir cards
        """
        let lido = LeitorLogDispatcher.ler(texto: texto)
        XCTAssertEqual(lido.decisao.fila, ["FRA-405"])
    }

    func testBuildInstaladaLeShaCurto() {
        let texto = """
        2026-10-16 12:00:00 main 27a89c1
        2026-10-16 12:04:00 DEVICE INSTALL OK
        2026-10-16 12:06:00 WATCH INSTALL OK 27a89c1
        """
        let inst = LeitorBuildInstalada.ler(texto: texto)
        XCTAssertTrue(inst.leu)
        XCTAssertEqual(inst.iphone, "27a89c1")
        XCTAssertEqual(inst.relogio, "27a89c1")
        XCTAssertFalse(LeitorBuildInstalada.ler(texto: "").leu)
    }
}

final class PainelProvaTests: XCTestCase {
    func testZeroTestesContaComoFalhaMesmoComSucessoDoXcodebuild() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let log = """
        [prova] TranscentIATests: 1ª tentativa SKIP_PREFLIGHT=1
        Executed 0 tests, with 0 failures (0 unexpected) in 0.010 (0.020) seconds
        ** TEST SUCCEEDED **
        """
        let bruta = ProvaBruta(lane: "opencode", card: "FRA-399", descricao: "testes de tela",
                               pedidoEm: agora.addingTimeInterval(-120), log: log, saida: 0,
                               esperandoLock: false, historico: false)
        let quadro = Provas.organizar([bruta], agora: agora)
        let carta = quadro.cartas[0]
        XCTAssertTrue(carta.zeroTestes)
        XCTAssertTrue(carta.falha)
        XCTAssertFalse(carta.emCurso)
        XCTAssertEqual(carta.fases.last?.marca, .falha)
        XCTAssertEqual(carta.fases.last?.detalhe, "0 testes")
        XCTAssertEqual(quadro.historico.first?.selo, "0 testes")
        XCTAssertTrue(carta.motivo?.contains("0 testes") == true)
    }

    func testDuasLanesUmaNoLockEOutraNaFila() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let rodando = ProvaBruta(lane: "opencode", card: "FRA-399", descricao: "testes de tela",
                                 pedidoEm: agora.addingTimeInterval(-234), log: "CompileSwift A.swift\n",
                                 saida: nil, esperandoLock: false, historico: false)
        let espera = ProvaBruta(lane: "codex", card: "FRA-405", descricao: "buffer de áudio",
                                pedidoEm: agora.addingTimeInterval(-192), log: "",
                                saida: nil, esperandoLock: true, historico: false)
        let quadro = Provas.organizar([espera, rodando], agora: agora)
        XCTAssertEqual(quadro.cartas.map(\.lane), ["opencode", "codex"])
        XCTAssertTrue(quadro.cartas[0].seguraLock)
        XCTAssertTrue(quadro.cartas[0].emCurso)
        XCTAssertNil(quadro.cartas[0].posicaoFila)
        XCTAssertFalse(quadro.cartas[1].seguraLock)
        XCTAssertEqual(quadro.cartas[1].posicaoFila, 1)
        XCTAssertEqual(quadro.cartas[1].esperaSegundos, 192)
        XCTAssertFalse(quadro.cartas[1].emCurso)
    }

    func testLockUnicoEmpurraASegundaProvaParaAFila() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let primeira = ProvaBruta(lane: "opencode", card: "FRA-399", descricao: nil,
                                  pedidoEm: agora.addingTimeInterval(-400), log: "Compiling A\n",
                                  saida: nil, esperandoLock: false, historico: false)
        let segunda = ProvaBruta(lane: "codex", card: "FRA-405", descricao: nil,
                                 pedidoEm: agora.addingTimeInterval(-100), log: "Compiling B\n",
                                 saida: nil, esperandoLock: false, historico: false)
        let quadro = Provas.organizar([segunda, primeira], agora: agora)
        XCTAssertEqual(quadro.cartas[0].lane, "opencode")
        XCTAssertTrue(quadro.cartas[0].seguraLock)
        XCTAssertEqual(quadro.cartas[1].posicaoFila, 1)
        XCTAssertEqual(quadro.cartas[1].esperaSegundos, 100)
    }

    /// A prova do TuttiDash roda `python3 -m unittest`: «Ran N tests … OK» não é
    /// «0 testes». Sem isso o contador de hoje ficava em zero e a prova verde virava falha.
    func testProvaPythonVerdeNaoViraZeroTestes() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let log = """
        [prova] tests.test_catalogo
        ..................
        ----------------------------------------------------------------------
        Ran 18 tests in 0.044s

        OK
        """
        let bruta = ProvaBruta(lane: "grok", card: "FRA-614", descricao: "catálogo",
                               pedidoEm: agora.addingTimeInterval(-120), log: log, saida: 0,
                               esperandoLock: false, historico: false)
        let carta = Provas.organizar([bruta], agora: agora).cartas[0]
        XCTAssertFalse(carta.zeroTestes)
        XCTAssertFalse(carta.falha)
        XCTAssertEqual(carta.suites.map(\.nome), ["tests.test_catalogo"])
        XCTAssertEqual(carta.suites.first?.estado, .ok)
        XCTAssertEqual(carta.fases.last?.detalhe, "ok")
    }

    func testProvaPythonVermelhaMarcaASuiteEFalha() {
        let agora = Date(timeIntervalSince1970: 1_700_000_000)
        let log = """
        [prova] tests.test_parser: 1ª tentativa SKIP_PREFLIGHT=1
        .F
        ======================================================================
        FAIL: test_x (tests.test_parser.X)
        ----------------------------------------------------------------------
        Ran 2 tests in 0.001s

        FAILED (failures=1)
        """
        let bruta = ProvaBruta(lane: "grok", card: "FRA-614", descricao: nil,
                               pedidoEm: agora.addingTimeInterval(-120), log: log, saida: 0,
                               esperandoLock: false, historico: false)
        let carta = Provas.organizar([bruta], agora: agora).cartas[0]
        XCTAssertFalse(carta.zeroTestes)
        XCTAssertTrue(carta.falha)
        XCTAssertEqual(carta.suites.map(\.nome), ["tests.test_parser"])
        XCTAssertEqual(carta.suites.first?.estado, .falha)
    }
}

final class PainelMontagemTests: XCTestCase {
    let agora = data("2026-10-16T18:00:00")
    var calendario: Calendar { calendarioFixo() }

    func testAlertaQuandoProvaPassaDeDezMinutos() {
        let pedido = agora.addingTimeInterval(-601)
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:50", dryRun: false, habilitadas: ["opencode"])
        entrada.habilitadas = ["opencode"]
        entrada.provas = [ProvaBruta(lane: "opencode", card: "FRA-399", descricao: "tela",
                                     pedidoEm: pedido, log: "Compiling Fonte.swift\n", saida: nil,
                                     esperandoLock: false, historico: false)]
        let snap = montar(entrada)
        XCTAssertTrue(snap.alertas.contains { $0.contains("FRA-399") && $0.contains("10 min") })
        XCTAssertEqual(snap.geral, .atencao)
        XCTAssertEqual(snap.lanes.first { $0.lane == "opencode" }?.estado, .rodando)
        XCTAssertEqual(snap.lanes.first { $0.lane == "opencode" }?.card, "FRA-399")

        entrada.provas[0].pedidoEm = agora.addingTimeInterval(-600)
        let noLimite = montar(entrada)
        XCTAssertFalse(noLimite.alertas.contains { $0.contains("10 min") })
    }

    func testUsoAoVivoGanhaDaMedidaCache() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:50", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        entrada.medidas = [
            MedidaConta(lane: "claude", pct: 10, janela: "semana"),
            MedidaConta(lane: "codex", pct: 40, janela: "mês"),
        ]
        let uso = UsoConta(conta: "claude", rotulo: "Claude", fonte: "api",
                           janelas: [JanelaUso(chave: "5h", rotulo: "5 h", pct: 96)])
        let snap = MontadorPainel.montar(entrada: entrada, execucoes: [], usos: [uso],
                                         agora: agora, calendario: calendario)
        XCTAssertEqual(snap.notch.contaCritica, "claude 96%")
        XCTAssertEqual(snap.lanes.first { $0.lane == "claude" }?.estado, .semFolga)
        XCTAssertEqual(snap.lanes.first { $0.lane == "codex" }?.pct, 40)
        XCTAssertEqual(snap.geral, .atencao)
    }

    func testTopCincoCalculadoComMotivoDeRepeticao() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:00", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        entrada.titulos = ["FRA-399": "testes de tela"]
        let execs = [
            ex("FRA-399-opencode-20261016-100000", custo: 10, status: .erro),
            ex("FRA-399-opencode-20261016-110000", custo: 8, status: .erro),
            ex("FRA-399-opencode-20261016-120000", custo: 4),
            ex("FRA-401-codex-20261016-100100", custo: 9),
            ex("FRA-395-claude-20261016-100200", custo: 1),
            ex("FRA-395-claude-20261016-100300", custo: 1),
            ex("FRA-395-claude-20261016-100400", custo: 1),
            ex("FRA-187-claude-20261016-100500", custo: 2),
            ex("FRA-406-codex-20261016-100600", custo: 0.5, status: .erro),
            ex("FRA-408-grok-20261016-100700", custo: 0.2),
        ]
        let top = montar(entrada, execucoes: execs).custos.top
        XCTAssertEqual(top.map(\.card), ["FRA-399", "FRA-401", "FRA-395", "FRA-187", "FRA-406"])
        XCTAssertEqual(top[0].motivo, "falha repetida")
        XCTAssertTrue(top[0].destaque)
        XCTAssertEqual(top[0].custoUSD ?? 0, 22, accuracy: 0.001)
        XCTAssertEqual(top[0].descricao, "testes de tela")
        XCTAssertEqual(top[2].motivo, "prova repetida")
        XCTAssertEqual(top[4].motivo, "falha")
        XCTAssertFalse(top.contains { $0.card == "FRA-408" })
    }

    func testNotchRecolhidoTemQuatroPontosEContaCritica() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:40", dryRun: false, habilitadas: ["claude", "codex", "opencode"])
        entrada.habilitadas = ["claude", "codex", "opencode"]
        entrada.desligadasPeloUsuario = ["grok"]
        entrada.medidas = [
            MedidaConta(lane: "claude", pct: 100, janela: "semana"),
            MedidaConta(lane: "codex", pct: 40, janela: "mês"),
        ]
        entrada.planos = ["claude": .pago, "codex": .free, "grok": .free]
        entrada.medidas.append(MedidaConta(lane: "grok", pct: 88, janela: "semana"))
        let snap = montar(entrada)
        XCTAssertEqual(snap.notch.pontos.map(\.lane), LanesPainel.ordem)
        XCTAssertEqual(snap.notch.pontos.map(\.aceso),
                       LanesPainel.ordem.map { ["claude", "codex", "opencode"].contains($0) })
        XCTAssertTrue(snap.notch.pontos[0].atencao)
        XCTAssertEqual(snap.notch.contaCritica, "claude 100%")
        XCTAssertEqual(snap.notch.geral, .atencao)
        XCTAssertEqual(snap.lanes.first { $0.lane == "claude" }?.estado, .semFolga)
        XCTAssertEqual(snap.lanes.first { $0.lane == "claude" }?.plano, .pago)
        XCTAssertEqual(snap.lanes.first { $0.lane == "grok" }?.descricao, "desligada")
        XCTAssertEqual(snap.lanes.first { $0.lane == "grok" }?.detalhe, "")
        XCTAssertNil(snap.lanes.first { $0.lane == "grok" }?.pct)
        XCTAssertNil(snap.lanes.first { $0.lane == "grok" }?.plano)
        XCTAssertEqual(snap.notch.testes, "sem prova")
        XCTAssertEqual(snap.notch.build, "lock livre")
        XCTAssertEqual(snap.notch.custoHoje, "sem dado")
    }

    func testTudoOkQuandoNaoHaAlerta() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:50", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        entrada.medidas = [MedidaConta(lane: "codex", pct: 12, janela: "5 h")]
        let snap = montar(entrada)
        XCTAssertEqual(snap.geral, .tudoOk)
        XCTAssertEqual(snap.notch.rotulo, "Tudo ok")
        XCTAssertEqual(snap.notch.contaCritica, "codex 12%")
        XCTAssertTrue(snap.alertas.isEmpty)
    }

    func testPausaDeixaParadoENaoAbreOLog() {
        var entrada = EntradaPainel.vazia
        entrada.pausa = true
        entrada.heartbeat = .init(at: "2026-10-16 17:59:50", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        entrada.logTexto = "2026-10-16 17:59:50 PAUSE presente: nenhum claim novo"
        let snap = montar(entrada)
        XCTAssertEqual(snap.geral, .parado)
        XCTAssertTrue(snap.alertas.contains { $0.contains("Pausa ligada") })
        XCTAssertFalse(snap.logAberto)
        XCTAssertFalse(snap.blocos.contains(.log))
        XCTAssertTrue(snap.abrindoLog().blocos.contains(.log))
        XCTAssertEqual(snap.blocos, [.alertas, .lanes, .testes, .builds, .dispatcher, .entregas, .custos])
    }

    func testVazioNaoTravaENaoInventaNumero() {
        let snap = montar(.vazia)
        XCTAssertEqual(snap.lanes.map(\.lane), LanesPainel.ordem)
        XCTAssertTrue(snap.provas.isEmpty)
        XCTAssertEqual(snap.notch.contaCritica, "sem medida")
        XCTAssertEqual(snap.strikesTexto, "sem registro")
        XCTAssertEqual(snap.simulador, "sem leitura ainda")
        XCTAssertEqual(snap.iphone, "sem leitura ainda")
        XCTAssertEqual(snap.relogio, "sem leitura ainda")
        XCTAssertEqual(snap.proximaDecisao, "sem decisão nova")
        XCTAssertTrue(snap.custos.top.isEmpty)
        XCTAssertNil(snap.custos.hoje)
        XCTAssertEqual(snap.geral, .parado)
    }

    func testNotchExpandidoResumeProvaLockECusto() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:20", dryRun: false, habilitadas: ["opencode", "codex", "claude", "grok"])
        entrada.habilitadas = ["opencode", "codex", "claude", "grok"]
        entrada.rodando = [.init(lane: "opencode", card: "FRA-399", titulo: "testes de tela",
                                 startedAt: "2026-10-16 17:56:00", log: "/tmp/FRA-399-opencode-20261016-175600.jsonl",
                                 travada: false)]
        entrada.provas = [
            ProvaBruta(lane: "opencode", card: "FRA-399", descricao: "testes de tela",
                       pedidoEm: agora.addingTimeInterval(-240), log: provaComFalha, saida: nil,
                       esperandoLock: false, historico: false),
            ProvaBruta(lane: "codex", card: "FRA-405", descricao: "buffer",
                       pedidoEm: agora.addingTimeInterval(-90), log: "", saida: nil,
                       esperandoLock: true, historico: false),
        ]
        let execs = [ex("FRA-399-opencode-20261016-120000", custo: 3.5)]
        let snap = montar(entrada, execucoes: execs)
        XCTAssertEqual(snap.notch.linhas.first { $0.lane == "opencode" }?.card, "FRA-399")
        XCTAssertEqual(snap.notch.linhas.first { $0.lane == "codex" }?.estado, .esperando)
        XCTAssertEqual(snap.notch.linhas.first { $0.lane == "codex" }?.posicaoTexto, "posição 1 na fila, há 1 min 30 s de espera")
        XCTAssertEqual(snap.notch.testes, "FRA-399, tentativa 1 de 2, 1 falha")
        XCTAssertEqual(snap.notch.build, "lock com opencode há 4 min")
        XCTAssertEqual(snap.notch.custoHoje, "US$ 3,50")
        XCTAssertEqual(snap.custos.moeda, .usd)
        XCTAssertEqual(snap.filaLock, ["1º codex · FRA-405"])
        XCTAssertEqual(snap.filaPronta, ["FRA-405"])
        XCTAssertEqual(snap.laneSugerida, "opencode")
    }

    func testEntregasNaoRepetemEHistoricoListaRodadasFechadas() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:20", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        entrada.rodando = [.init(lane: "opencode", card: "FRA-399", titulo: "testes de tela",
                                 startedAt: "2026-10-16 17:56:00", log: "/tmp/FRA-399-opencode-20261016-175600.jsonl",
                                 travada: false)]
        entrada.fechamentos = [
            .init(quando: "2026-10-16 10:00:00", lane: "claude", card: "FRA-404", resto: "→ In Review"),
            .init(quando: "2026-10-16 11:00:00", lane: "claude", card: "FRA-404", resto: "→ In Review"),
            .init(quando: "2026-10-16 12:00:00", lane: "codex", card: "FRA-401", resto: "→ In Review"),
            .init(quando: "2026-10-16 13:00:00", lane: "opencode", card: "FRA-399", resto: "→ In Review"),
            .init(quando: "2026-10-16 14:00:00", lane: "claude", card: "FRA-404",
                  resto: "→ In Review (https://github.com/org/repo/pull/2)"),
            .init(quando: "2026-10-16 15:00:00", lane: "codex", card: "FRA-405", resto: "→ In Review"),
        ]
        let ok = "Executed 3 tests, with 0 failures (0 unexpected) in 1.000 (1.200) seconds\n** TEST SUCCEEDED **\n"
        entrada.provas = [
            ProvaBruta(lane: "opencode", card: "FRA-399", descricao: "tela",
                       pedidoEm: agora.addingTimeInterval(-90), log: "Compiling A\n",
                       saida: nil, esperandoLock: false, historico: false),
            ProvaBruta(lane: "codex", card: "FRA-405", descricao: "buffer",
                       pedidoEm: agora.addingTimeInterval(-40), log: "",
                       saida: nil, esperandoLock: true, historico: false),
            ProvaBruta(lane: "claude", card: "FRA-404", descricao: "fechou",
                       pedidoEm: agora.addingTimeInterval(-120), log: ok,
                       saida: 0, esperandoLock: false, historico: false),
            ProvaBruta(lane: "claude", card: "FRA-404", descricao: "arquivo",
                       pedidoEm: agora.addingTimeInterval(-300), log: ok,
                       saida: 0, esperandoLock: false, historico: true),
            ProvaBruta(lane: "claude", card: "FRA-404", descricao: "arquivo antigo",
                       pedidoEm: agora.addingTimeInterval(-400), log: ok,
                       saida: 0, esperandoLock: false, historico: true),
            ProvaBruta(lane: "codex", card: "FRA-401", descricao: "ok",
                       pedidoEm: agora.addingTimeInterval(-80), log: ok,
                       saida: 0, esperandoLock: false, historico: false),
            ProvaBruta(lane: "grok", card: "FRA-390", descricao: "instantanea",
                       pedidoEm: agora, log: ok,
                       saida: 0, esperandoLock: false, historico: false),
        ]
        let execs = [
            ex("FRA-404-claude-20261016-100000", custo: 1, duracaoMs: 400),
            ex("FRA-401-codex-20261016-120000", custo: 1, duracaoMs: 2500),
            ex("FRA-399-opencode-20261016-130000", custo: 1, duracaoMs: 500),
        ]
        let snap = montar(entrada, execucoes: execs)
        XCTAssertEqual(snap.entregas.map(\.card), ["FRA-404", "FRA-401"])
        XCTAssertEqual(snap.entregas[0].urlPR, "https://github.com/org/repo/pull/2")
        XCTAssertEqual(snap.entregas[0].pr, "PR #2")
        XCTAssertNil(snap.entregas[1].urlPR)
        XCTAssertNil(snap.entregas[1].pr)
        XCTAssertNil(snap.entregas[0].segundos)
        XCTAssertEqual(snap.entregas[1].segundos, 2)
        XCTAssertFalse(snap.entregas.contains { $0.segundos == 0 })
        XCTAssertFalse(snap.entregas.contains { $0.card == "FRA-399" || $0.card == "FRA-405" })
        XCTAssertEqual(snap.historico.filter { $0.card == "FRA-404" }.count, 3)
        XCTAssertEqual(snap.historico.map(\.card), ["FRA-401", "FRA-404", "FRA-404", "FRA-404"])
        XCTAssertFalse(snap.historico.contains { $0.emCurso || $0.segundos == 0 })
        XCTAssertFalse(snap.historico.contains { $0.card == "FRA-399" || $0.card == "FRA-405" || $0.card == "FRA-390" })
        XCTAssertTrue(snap.historico.contains { $0.card == "FRA-401" && $0.selo == "ok" })
    }

    func testEntregaGuardaURLDoRepositorioDoPR() {
        var entrada = EntradaPainel.vazia
        entrada.fechamentos = [
            .init(quando: "2026-10-16 12:00:00", lane: "claude", card: "FRA-188",
                  resto: "needs:dono #12"),
            .init(quando: "2026-10-16 13:00:00", lane: "opencode-go", card: "FRA-514",
                  resto: "In Review"),
            .init(quando: "2026-10-16 14:00:00", lane: "codex", card: "FRA-401",
                  resto: "In Review (https://github.com/org/outro/pull/9)"),
            .init(quando: "2026-10-16 15:00:00", lane: "opencode", card: "FRA-527",
                  resto: "In Review (https://github.com/exemplo/projeto/pull/241)"),
        ]
        let snap = montar(entrada)
        XCTAssertEqual(snap.entregas.map(\.card), ["FRA-527", "FRA-401", "FRA-514", "FRA-188"])
        XCTAssertEqual(snap.entregas[0].pr, "PR #241")
        XCTAssertEqual(snap.entregas[0].urlPR, "https://github.com/exemplo/projeto/pull/241")
        XCTAssertEqual(snap.entregas[1].urlPR, "https://github.com/org/outro/pull/9")
        XCTAssertNil(snap.entregas[2].pr)
        XCTAssertNil(snap.entregas[2].urlPR)
        XCTAssertEqual(snap.entregas[3].pr, "PR #12")
        XCTAssertNil(snap.entregas[3].urlPR)
    }

    func testEntregasListaORegistroAlemDasCinco() {
        var entrada = EntradaPainel.vazia
        entrada.rodando = [.init(lane: "opencode", card: "FRA-399", titulo: "andamento",
                                 startedAt: "2026-10-16 17:00:00", log: "/tmp/x", travada: false)]
        entrada.fechamentos = (1...8).map { i in
            FechamentoLog(quando: String(format: "2026-10-16 %02d:00:00", i),
                          lane: "claude", card: "FRA-\(500 + i)", resto: "→ In Review")
        } + [.init(quando: "2026-10-16 17:30:00", lane: "opencode", card: "FRA-399", resto: "→ In Review")]
        let snap = montar(entrada)
        XCTAssertEqual(snap.entregas.map(\.card), (1...8).reversed().map { "FRA-\(500 + $0)" })
        XCTAssertEqual(snap.entregas.count, 8)
        XCTAssertFalse(snap.entregas.contains { $0.card == "FRA-399" })
    }

    func testEntregasCortaNoTetoDoRegistro() {
        var entrada = EntradaPainel.vazia
        let n = MontadorPainel.limiteEntregas + 3
        entrada.fechamentos = (0..<n).map { i in
            FechamentoLog(quando: "2026-10-16 10:00:00", lane: "claude", card: "FRA-\(i)", resto: "In Review")
        }
        let snap = montar(entrada)
        XCTAssertEqual(snap.entregas.count, MontadorPainel.limiteEntregas)
        XCTAssertEqual(snap.entregas.first?.card, "FRA-\(n - 1)")
        XCTAssertEqual(snap.entregas.last?.card, "FRA-\(n - MontadorPainel.limiteEntregas)")
        XCTAssertFalse(snap.entregas.contains { $0.card == "FRA-\(n - MontadorPainel.limiteEntregas - 1)" })
    }

    func testCustoEmReaisQuandoHaTaxa() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:20", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        let execs = [ex("FRA-399-opencode-20261016-120000", custo: 3.5)]
        let comTaxa = MontadorPainel.montar(entrada: entrada, execucoes: execs, agora: agora,
                                            calendario: calendario, taxaUsdBrl: 5)
        XCTAssertEqual(comTaxa.custos.moeda, .brl(taxa: 5))
        XCTAssertEqual(comTaxa.custos.moeda.rotulo, "R$")
        XCTAssertEqual(comTaxa.notch.custoHoje, "R$ 17,50")
        let semTaxa = montar(entrada, execucoes: execs)
        XCTAssertEqual(semTaxa.custos.moeda, .usd)
        XCTAssertEqual(semTaxa.custos.moeda.rotulo, "US$")
        XCTAssertEqual(semTaxa.notch.custoHoje, "US$ 3,50")
        let taxaZero = MontadorPainel.montar(entrada: entrada, execucoes: execs, agora: agora,
                                             calendario: calendario, taxaUsdBrl: 0)
        XCTAssertEqual(taxaZero.custos.moeda, .usd)
    }

    func testLeituraDoDiscoNaoCriaPauseNemMexeNoEnabled() throws {
        let t = try PastaTemp()
        let enabled = "claude codex\n"
        try t.escrever("enabled", enabled)
        try t.escrever("heartbeat.json", #"{"at":"2026-10-16 17:00:00","dry_run":false,"enabled":["claude"]}"#)
        try t.escrever("medida-cache.json", #"{"at":1,"m":{"claude":[10,"semana"]}}"#)
        try t.escrever("planos.json", #"{"claude":"pago"}"#)
        try t.escrever("opencode-strikes.json", #"{"strikes":1,"max":3}"#)
        try t.escrever("disabled-by-user", "grok\n")
        let wt = t.url.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt.appendingPathComponent(".lane"), withIntermediateDirectories: true)
        let log = """
        [prova] TranscentIATests: 1ª tentativa SKIP_PREFLIGHT=1
        Executed 0 tests, with 0 failures
        ** TEST SUCCEEDED **
        """
        try log.write(to: wt.appendingPathComponent(".lane/proof.log"), atomically: true, encoding: .utf8)
        try "0".write(to: wt.appendingPathComponent(".lane/proof_exit"), atomically: true, encoding: .utf8)
        try "\(agora.addingTimeInterval(-30).timeIntervalSince1970)".write(
            to: wt.appendingPathComponent(".lane/proof_started"), atomically: true, encoding: .utf8)
        let lane: [String: Any] = ["lane": "opencode", "card": "FRA-399", "title": "zero",
                                   "log": "/tmp/FRA-399-opencode-20261016-170000.jsonl", "worktree": wt.path]
        let dados = try JSONSerialization.data(withJSONObject: lane)
        try dados.write(to: t.url.appendingPathComponent("lane-opencode.json"))
        let logs = t.url.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let antes = try String(contentsOf: t.url.appendingPathComponent("enabled"), encoding: .utf8)
        let entrada = LeitorPainelDisco.ler(pasta: t.url,
                                            logDispatcher: t.url.appendingPathComponent("ausente.log"),
                                            logsDir: logs, agora: agora)
        let snap = montar(entrada)
        let depois = try String(contentsOf: t.url.appendingPathComponent("enabled"), encoding: .utf8)
        XCTAssertEqual(antes, depois)
        XCTAssertEqual(antes, enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.url.appendingPathComponent("PAUSE").path))
        XCTAssertTrue(snap.provas.contains { $0.card == "FRA-399" && $0.zeroTestes && $0.falha })
        XCTAssertEqual(entrada.planos["claude"], .pago)
        XCTAssertEqual(entrada.strikes?.texto, "1/3")
        XCTAssertTrue(entrada.desligadasPeloUsuario.contains("grok"))
        XCTAssertEqual(entrada.habilitadas, Set(["claude", "codex"]))
        XCTAssertTrue(entrada.medidas.isEmpty, "medida de 2023 não pode virar barra de agora")
    }

    private var provaComFalha: String {
        """
        [prova] TranscentIATests: 1ª tentativa SKIP_PREFLIGHT=1
        Test Case '-[ScenarioScreenUITests testPortao]' failed (52.000 seconds)
        error: a tela não achou o portão.
        """
    }

    private func montar(_ entrada: EntradaPainel, execucoes: [Execucao] = []) -> SnapshotPainel {
        MontadorPainel.montar(entrada: entrada, execucoes: execucoes, agora: agora, calendario: calendario)
    }
}

/// FRA-554: a tela Testes guarda o histórico das provas fechadas, além das 5 «últimas».
final class HistoricoProvasTests: XCTestCase {
    private let agora = Date(timeIntervalSince1970: 1_700_000_000)
    private let logOk = "Executed 2 tests, with 0 failures (0 unexpected) in 1.000 (1.100) seconds\n** TEST SUCCEEDED **\n"
    private let logFalha = """
    Test Case '-[Suite testPortao]' failed (2.000 seconds)
    ** TEST FAILED **
    """

    func testHistoricoDaTelaListaMaisDeCincoProvasFechadas() {
        let brutas = (0..<8).map { i in
            fechada(lane: "lane\(i)", card: "FRA-\(600 + i)", ha: Double(60 * (i + 1)))
        }
        let quadro = Provas.organizar(brutas, agora: agora)
        XCTAssertEqual(Provas.limiteHistorico, 80)
        XCTAssertEqual(quadro.historico.count, 8)
        XCTAssertEqual(quadro.historico.map(\.card), (0..<8).map { "FRA-\(600 + $0)" })
        XCTAssertEqual(quadro.historico.map(\.lane), (0..<8).map { "lane\($0)" })
        XCTAssertTrue(quadro.historico.allSatisfy { $0.selo == "ok" && $0.segundos > 0 })
        XCTAssertEqual(quadro.historico[0].segundos, 60)
    }

    func testHistoricoGuardaCadaRodadaENaoListaAndamento() {
        let brutas = [
            fechada(lane: "claude", card: "FRA-404", ha: 120),
            fechada(lane: "claude", card: "FRA-404", ha: 400, log: logFalha, saida: 1),
            fechada(lane: "opencode", card: "FRA-399", ha: 30, historico: false),
            fechada(lane: "codex", card: "FRA-405", ha: 10, log: "Compiling A\n", saida: nil),
            fechada(lane: "grok", card: "FRA-390", ha: 0),
        ]
        let quadro = Provas.organizar(brutas, agora: agora)
        XCTAssertEqual(quadro.historico.map(\.card), ["FRA-399", "FRA-404", "FRA-404"])
        XCTAssertEqual(quadro.historico.map(\.lane), ["opencode", "claude", "claude"])
        XCTAssertEqual(quadro.historico.map(\.selo), ["ok", "ok", "falha"])
        XCTAssertFalse(quadro.historico.contains { $0.card == "FRA-405" || $0.card == "FRA-390" || $0.segundos == 0 || $0.emCurso })
    }

    func testHistoricoCortaNoTeto() {
        let brutas = (0..<(Provas.limiteHistorico + 3)).map { i in
            fechada(lane: "l", card: "FRA-\(1000 + i)", ha: Double(i + 1))
        }
        let quadro = Provas.organizar(brutas, agora: agora)
        XCTAssertEqual(quadro.historico.count, Provas.limiteHistorico)
        XCTAssertEqual(quadro.historico.first?.card, "FRA-1000")
        XCTAssertEqual(quadro.historico.last?.card, "FRA-\(1000 + Provas.limiteHistorico - 1)")
        XCTAssertFalse(quadro.historico.contains { $0.card == "FRA-\(1000 + Provas.limiteHistorico)" })
    }

    func testUltimasCurtasContinuamUmaPorCardECinco() {
        var brutas = (0..<7).map { i in
            fechada(lane: "lane\(i)", card: "FRA-\(500 + i)", ha: Double(30 * (i + 1)))
        }
        brutas.append(fechada(lane: "lane0", card: "FRA-500", ha: 9_000))
        let curtas = Provas.ultimas([], arquivadas: brutas, agora: agora)
        XCTAssertEqual(Provas.limiteUltimas, 5)
        XCTAssertEqual(curtas.count, 5)
        XCTAssertEqual(curtas.map(\.card), (0..<5).map { "FRA-\(500 + $0)" })
        XCTAssertEqual(curtas.filter { $0.card == "FRA-500" }.count, 1)
    }

    func testDiscoLeMaisDeCincoProvasArquivadas() throws {
        let t = try PastaTemp()
        let enabled = "claude\n"
        try t.escrever("enabled", enabled)
        for i in 0..<7 {
            try arquivar(t, indice: i, card: 700 + i, ha: Double((i + 1) * 60))
        }
        try t.escrever("stale-proof-sem-card-0100/proof.log", logOk)
        try t.escrever("outra/proof.log", logOk)
        let entrada = try ler(t)
        let depois = try String(contentsOf: t.url.appendingPathComponent("enabled"), encoding: .utf8)
        XCTAssertEqual(depois, enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.url.appendingPathComponent("PAUSE").path))
        XCTAssertEqual(entrada.provas.filter(\.historico).count, 7)
        XCTAssertEqual(Set(entrada.provas.map(\.card)), Set((0..<7).map { "FRA-\(700 + $0)" }))
        XCTAssertTrue(entrada.provas.allSatisfy { $0.historico && $0.lane.isEmpty })
        let snap = MontadorPainel.montar(entrada: entrada, execucoes: [], agora: agora)
        XCTAssertEqual(snap.historico.count, 7)
        XCTAssertTrue(snap.historico.allSatisfy { $0.selo == "ok" && $0.segundos > 0 && $0.lane.isEmpty })
    }

    func testDiscoRespeitaOTetoDoHistorico() throws {
        let t = try PastaTemp()
        let total = Provas.limiteHistorico + 2
        for i in 0..<total {
            try arquivar(t, indice: i, card: 2000 + i, ha: Double(i + 1))
        }
        let entrada = try ler(t)
        let cards = Set(entrada.provas.map(\.card))
        XCTAssertEqual(entrada.provas.count, Provas.limiteHistorico)
        XCTAssertTrue(cards.contains("FRA-\(2000 + total - 1)"))
        XCTAssertFalse(cards.contains("FRA-2000"))
        XCTAssertFalse(cards.contains("FRA-2001"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.url.appendingPathComponent("PAUSE").path))
    }

    /// O card fecha, a lane pega outro e o `lane-<lane>.json` passa a apontar para
    /// outro worktree. A prova de hoje continua no worktree do card e precisa contar.
    func testProvaDeCardQueSaiuDaLaneContaNoDia() throws {
        let t = try PastaTemp()
        let worktrees = t.url.appendingPathComponent("worktrees")
        try provaNoWorktree(worktrees, card: "fra-614", ha: 60, log: logDoisVerdes)
        let entrada = try ler(t, worktrees: worktrees)
        XCTAssertEqual(entrada.provas.map(\.card), ["FRA-614"])
        let ind = indicadores(entrada)
        XCTAssertEqual(ind.provasHoje, 1)
        XCTAssertEqual(ind.testesPassou, 1, "uma classe Swift é uma suíte")
        XCTAssertEqual(ind.testesFalhou, 0)
        XCTAssertEqual(MontadorPainel.montar(entrada: entrada, execucoes: [], agora: agora,
                                             calendario: calendarioFixo()).historico.first?.selo, "ok")
    }

    /// A mesma prova no worktree e em `stale-proof-*` conta uma vez só.
    func testProvaNoWorktreeNaoDuplicaAArquivada() throws {
        let t = try PastaTemp()
        let worktrees = t.url.appendingPathComponent("worktrees")
        let pedido = agora.addingTimeInterval(-60)
        try provaNoWorktree(worktrees, card: "fra-614", ha: 60, log: logDoisVerdes)
        try t.escrever("stale-proof-fra-614-0145/proof_started", "\(pedido.timeIntervalSince1970)")
        try t.escrever("stale-proof-fra-614-0145/proof_exit", "0")
        try t.escrever("stale-proof-fra-614-0145/proof.log", logDoisVerdes)
        let entrada = try ler(t, worktrees: worktrees)
        XCTAssertEqual(entrada.provas.filter { $0.card == "FRA-614" }.count, 1)
        XCTAssertEqual(indicadores(entrada).provasHoje, 1)
    }

    /// Prova de ontem no worktree não entra no contador de hoje.
    func testProvaDeOutroDiaNoWorktreeFicaFora() throws {
        let t = try PastaTemp()
        let worktrees = t.url.appendingPathComponent("worktrees")
        try provaNoWorktree(worktrees, card: "fra-613", ha: 26 * 3600, log: logDoisVerdes)
        let entrada = try ler(t, worktrees: worktrees)
        XCTAssertTrue(entrada.provas.isEmpty)
        XCTAssertEqual(indicadores(entrada).provasHoje, 0)
    }

    private var logDoisVerdes: String {
        """
        Test Case '-[GastoCoreTests.CatalogoBundleTests testUm]' passed (0.001 seconds).
        Test Case '-[GastoCoreTests.CatalogoBundleTests testDois]' passed (0.002 seconds).
        Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
        ** TEST SUCCEEDED **
        """
    }

    private func provaNoWorktree(_ raiz: URL, card: String, ha: TimeInterval, log: String) throws {
        let base = raiz.appendingPathComponent(card).appendingPathComponent(".lane")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try "\(agora.addingTimeInterval(-ha).timeIntervalSince1970)"
            .write(to: base.appendingPathComponent("proof_started"), atomically: true, encoding: .utf8)
        try "0".write(to: base.appendingPathComponent("proof_exit"), atomically: true, encoding: .utf8)
        try log.write(to: base.appendingPathComponent("proof.log"), atomically: true, encoding: .utf8)
    }

    private func indicadores(_ entrada: EntradaPainel) -> IndicadoresPainel {
        Indicadores.calcular(linhas: [], execucoes: [], provas: entrada.provas, semanaAtual: nil,
                             agora: agora, calendario: calendarioFixo())
    }

    private func fechada(lane: String, card: String, ha: TimeInterval, historico: Bool = true,
                         log: String? = nil, saida: Int? = 0) -> ProvaBruta {
        ProvaBruta(lane: lane, card: card, descricao: nil,
                   pedidoEm: agora.addingTimeInterval(-ha),
                   log: log ?? logOk, saida: saida,
                   esperandoLock: false, historico: historico)
    }

    /// `indice` 0 é a pasta mais antiga. O card entra no nome como o dispatcher grava (`fra-N`).
    private func arquivar(_ t: PastaTemp, indice: Int, card: Int, ha: TimeInterval) throws {
        let nome = String(format: "stale-proof-fra-%d-%04d", card, indice)
        let dir = t.url.appendingPathComponent(nome)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pedido = agora.addingTimeInterval(-ha).timeIntervalSince1970
        try String(pedido).write(to: dir.appendingPathComponent("proof_started"), atomically: true, encoding: .utf8)
        try "0".write(to: dir.appendingPathComponent("proof_exit"), atomically: true, encoding: .utf8)
        try logOk.write(to: dir.appendingPathComponent("proof.log"), atomically: true, encoding: .utf8)
        let quando = agora.addingTimeInterval(TimeInterval(indice))
        try FileManager.default.setAttributes([.modificationDate: quando], ofItemAtPath: dir.path)
    }

    private func ler(_ t: PastaTemp, worktrees: URL? = nil) throws -> EntradaPainel {
        let logs = t.url.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return LeitorPainelDisco.ler(pasta: t.url,
                                     logDispatcher: t.url.appendingPathComponent("ausente.log"),
                                     logsDir: logs, agora: agora,
                                     worktrees: worktrees.map { [$0] } ?? [])
    }
}

final class PainelCtlTests: XCTestCase {
    func testDesativarChamaLanesCtlENaoGravaEnabled() {
        let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pasta) }
        let enabled = pasta.appendingPathComponent("enabled")
        try? "claude grok\n".write(to: enabled, atomically: true, encoding: .utf8)
        let script = pasta.appendingPathComponent("lanes_ctl.py").path
        var chamadas: [PedidoDesativar] = []
        let resultado = AcaoDesativar.executar(lane: "grok", script: script) { pedido in
            chamadas.append(pedido)
            return 0
        }
        XCTAssertTrue(resultado.executou)
        XCTAssertEqual(resultado.codigo, 0)
        XCTAssertEqual(chamadas, [PedidoDesativar(executavel: "/usr/bin/python3",
                                                  argumentos: [script, "disable", "grok"])])
        XCTAssertEqual(try String(contentsOf: enabled, encoding: .utf8), "claude grok\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pasta.appendingPathComponent("PAUSE").path))
    }

    func testLaneInvalidaNaoExecuta() {
        var chamou = false
        let resultado = AcaoDesativar.executar(lane: "Grok", script: "/tmp/lanes_ctl.py") { _ in
            chamou = true
            return 0
        }
        XCTAssertFalse(chamou)
        XCTAssertFalse(resultado.executou)
        XCTAssertEqual(resultado.codigo, 2)
    }

    func testProvaHistoricaUsaTituloDoCacheDoDispatcher() throws {
        let t = try PastaTemp()
        try t.escrever("titulos-cache.json", #"{"FRA-560": "Whisper: feedback de carregamento"}"#)
        try t.escrever("stale-proof-FRA-560-claude/proof_started", "1793000000")
        try t.escrever("stale-proof-FRA-560-claude/proof_exit", "0")
        try t.escrever("stale-proof-FRA-560-claude/proof.log", "")
        let entrada = LeitorPainelDisco.ler(pasta: t.url, logDispatcher: t.url.appendingPathComponent("x.log"),
                                            logsDir: t.url.appendingPathComponent("logs"))
        let historico = Provas.organizar(entrada.provas, agora: Date()).historico
        XCTAssertEqual(historico.first?.titulo, "Whisper: feedback de carregamento")
    }
}

private extension LinhaLane {
    var posicaoTexto: String { detalhe }
}
