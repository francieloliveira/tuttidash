import XCTest
@testable import GastoCore

/// FRA-531: «Quem cuida das lanes». O PAUSE decide quem cuida; o resto só explica o porquê.
final class QuemCuidaTests: XCTestCase {
    private func estado(_ modo: String, _ pct: Double?) -> EstadoChave {
        EstadoChave(modo: modo, pct: pct, medidoEm: "2026-10-23 20:30:00-0300", motivo: nil)
    }

    func testAutomaticoAbaixoDoLimiteTheoCuida() {
        let q = QuemCuida.calcular(modo: .auto, estado: estado("grokbot", 42), pauseManual: false, pause: true,
                                   gestor: nil, limitePct: 90, chaveLigada: true)
        XCTAssertEqual(q.responsavel, .gestor)
        XCTAssertEqual(q.titulo, "O gestor está cuidando")
        XCTAssertTrue(q.motivo.contains("42%") && q.motivo.contains("90%"), q.motivo)
        XCTAssertTrue(q.avisos.isEmpty)
    }

    func testAutomaticoNoLimiteVigiaAssume() {
        let q = QuemCuida.calcular(modo: .auto, estado: estado("vigia", 93), pauseManual: false, pause: false,
                                   gestor: nil, limitePct: 90, chaveLigada: true)
        XCTAssertEqual(q.responsavel, .vigia)
        XCTAssertTrue(q.motivo.contains("93%"))
    }

    func testMedidaFalhouVigiaAssume() {
        let q = QuemCuida.calcular(modo: .auto, estado: estado("vigia", nil), pauseManual: false, pause: false,
                                   gestor: nil, limitePct: 90, chaveLigada: true)
        XCTAssertEqual(q.responsavel, .vigia)
        XCTAssertTrue(q.motivo.contains("Na dúvida"))
    }

    func testPausaGeralVenceTudo() {
        for m in ModoForcado.allCases {
            let q = QuemCuida.calcular(modo: m, estado: estado("grokbot", 10), pauseManual: true, pause: true,
                                       gestor: "vigia", limitePct: 90, chaveLigada: true)
            XCTAssertEqual(q.responsavel, .pausaGeral, "\(m)")
        }
    }

    func testForcadoEExplicaETrocaPendente() {
        let q = QuemCuida.calcular(modo: .vigia, estado: estado("grokbot", 10), pauseManual: false, pause: true,
                                   gestor: nil, limitePct: 90, chaveLigada: true)
        XCTAssertEqual(q.responsavel, .gestor, "vale o PAUSE de agora")
        XCTAssertEqual(q.motivo, "Você escolheu «Sempre o vigia».")
        XCTAssertTrue(q.avisos.contains { $0.contains("próxima conferência") })
    }

    func testChaveDesligadaAvisaQueCongelou() {
        let q = QuemCuida.calcular(modo: .auto, estado: estado("grokbot", 10), pauseManual: false, pause: true,
                                   gestor: nil, limitePct: 90, chaveLigada: false)
        XCTAssertTrue(q.avisos.contains { $0.contains("congelada") })
    }

    func testGestorPassadoAMao() {
        let q = QuemCuida.calcular(modo: .auto, estado: nil, pauseManual: false, pause: true,
                                   gestor: "opencode", limitePct: 90, chaveLigada: nil)
        XCTAssertEqual(q.responsavel, .outro("opencode"))
        XCTAssertEqual(QuemCuida.calcular(modo: .auto, estado: nil, pauseManual: false, pause: true,
                                          gestor: "inventado", limitePct: 90, chaveLigada: nil).responsavel, .gestor)
    }

    /// Lê PAUSE, PAUSE.manual e gestor do disco, sem criar nem apagar nada.
    func testGestaoLeArquivosSemMexer() throws {
        let t = try PastaTemp()
        let g = GestaoLanes(modelo: ModeloAjustes(home: t.url)) { _ in 0 }
        XCTAssertEqual(g.quemCuida(chaveLigada: true).responsavel, .vigia)
        _ = try t.escrever(".transcentia/bots/PAUSE", "")
        XCTAssertEqual(g.quemCuida(chaveLigada: true).responsavel, .gestor)
        _ = try t.escrever(".transcentia/bots/PAUSE.manual", "")
        XCTAssertEqual(g.quemCuida(chaveLigada: true).responsavel, .pausaGeral)
        XCTAssertTrue(FileManager.default.fileExists(atPath: g.pause.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: g.pauseManual.path))
        XCTAssertEqual(g.limitePct, 90)
    }

    func testRotulosDoSeletor() {
        XCTAssertEqual(ModoForcado.allCases.map(\.rotulo), ["Automático", "Sempre o vigia", "Sempre o gestor"])
    }
}

/// FRA-531: estados de uma ação (ocioso, rodando, ok, erro) e os textos de tempo.
final class RetornoAcaoTests: XCTestCase {
    func testCicloOkVoltaAOcioso() {
        var m = MaquinaAcao()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(m.estado, .ocioso)
        XCTAssertTrue(m.iniciar(agora: t0))
        XCTAssertTrue(m.estado.rodando)
        XCTAssertFalse(m.iniciar(agora: t0), "clique duplo não roda duas vezes")
        XCTAssertEqual(m.decorrido(agora: t0.addingTimeInterval(4)), 4)
        m.expirar(agora: t0.addingTimeInterval(999))
        XCTAssertTrue(m.estado.rodando, "rodando nunca expira")
        m.concluir("Salvo", agora: t0.addingTimeInterval(5))
        XCTAssertEqual(m.estado, .ok("Salvo", em: t0.addingTimeInterval(5)))
        m.expirar(agora: t0.addingTimeInterval(6))
        XCTAssertNotEqual(m.estado, .ocioso)
        m.expirar(agora: t0.addingTimeInterval(5 + MaquinaAcao.tempoOk))
        XCTAssertEqual(m.estado, .ocioso)
    }

    func testErroFicaMaisTempo() {
        var m = MaquinaAcao()
        let t0 = Date(timeIntervalSince1970: 0)
        m.iniciar(agora: t0)
        m.falhar("sem permissão", agora: t0)
        m.expirar(agora: t0.addingTimeInterval(MaquinaAcao.tempoOk))
        XCTAssertEqual(m.estado, .erro("sem permissão", em: t0))
        m.expirar(agora: t0.addingTimeInterval(MaquinaAcao.tempoErro))
        XCTAssertEqual(m.estado, .ocioso)
        XCTAssertTrue(m.iniciar(agora: t0), "depois do erro dá para tentar de novo")
    }

    func testMotivoDoErroEmPortugues() {
        XCTAssertEqual(MaquinaAcao.motivo(ModeloAjustes.Erro.invalido("Entre 1 e 10")), "Entre 1 e 10")
    }

    func testTextosDeTempo() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TextoTempo.atualizado(t0, agora: t0.addingTimeInterval(2)), "atualizado agora")
        XCTAssertEqual(TextoTempo.atualizado(t0, agora: t0.addingTimeInterval(12)), "atualizado há 12 s")
        XCTAssertEqual(TextoTempo.atualizado(t0, agora: t0.addingTimeInterval(190)), "atualizado há 3 min")
        XCTAssertEqual(TextoTempo.atualizado(nil), "ainda sem leitura")
        XCTAssertEqual(TextoTempo.duracao(45), "45 s")
        XCTAssertEqual(TextoTempo.duracao(125), "2 min 05 s")
        XCTAssertEqual(TextoTempo.duracao(3780), "1 h 03 min")
    }

    func testProgressoEstimadoNuncaChegaA100() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ProgressoProcesso.estimado(inicio: t0, duracaoTipica: 100, agora: t0.addingTimeInterval(50)).fracao, 0.5)
        XCTAssertEqual(ProgressoProcesso.estimado(inicio: t0, duracaoTipica: 100, agora: t0.addingTimeInterval(500)).fracao, 0.95)
        XCTAssertNil(ProgressoProcesso.estimado(inicio: t0, duracaoTipica: 0).fracao)
        let p = ProgressoProcesso(etapa: "na prova", inicio: t0)
        XCTAssertEqual(p.legenda(agora: t0.addingTimeInterval(250)), "na prova · 4 min 10 s")
        XCTAssertEqual(ProgressoProcesso(fracao: 3).fracao, 1)
    }

    func testCorDaBarraDeUsoPorNivel() {
        XCTAssertEqual(Uso.nivel(50), .ok)
        XCTAssertEqual(Uso.nivel(85), .atencao)
        XCTAssertEqual(Uso.nivel(97), .critico)
    }

    func testProgressoDaBuildEmCurso() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = BuildPainel(numero: 1, card: "FRA-1", lane: "claude", inicio: t0, status: .emAndamento, duracaoMs: nil, custoUSD: nil)
        let p = b.progresso(tipica: 600, agora: t0.addingTimeInterval(300))
        XCTAssertEqual(p?.fracao, 0.5)
        XCTAssertEqual(p?.etapa, "fase do agente")
        XCTAssertNil(b.progresso(tipica: 600, agora: t0.addingTimeInterval(900))?.fracao, "passou do típico: sem estimativa")
        b.status = .ok; b.naProva = true
        XCTAssertEqual(b.progresso(tipica: 600, agora: t0)?.etapa, "na prova")
        b.naProva = false
        XCTAssertNil(b.progresso(tipica: 600), "build terminada não tem barra")
        let feitas = [10, 30, 20].map { BuildPainel(numero: nil, card: "c", lane: "l", inicio: nil, status: .ok, duracaoMs: $0 * 1000, custoUSD: nil) }
        XCTAssertEqual(BuildPainel.duracaoTipica(feitas), 20)
        XCTAssertEqual(BuildPainel.duracaoTipica([]), 1200)
    }
}
