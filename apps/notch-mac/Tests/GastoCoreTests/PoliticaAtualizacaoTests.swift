import XCTest
@testable import GastoCore

final class PoliticaAtualizacaoTests: XCTestCase {
    func testSemPollingComPainelRecolhido() {
        XCTAssertNil(PoliticaAtualizacao.padrao.reservaMouse(expandido: false))
        XCTAssertEqual(PoliticaAtualizacao.padrao.reservaMouse(expandido: true), 1)
    }

    func testIntervaloMinimoRespeitado() {
        let p = PoliticaAtualizacao(intervaloDados: 0.1, intervaloUso: 0, intervaloReservaMouse: 0.25)
        XCTAssertEqual(p.intervaloDados, 1)
        XCTAssertEqual(p.intervaloUso, 1)
        XCTAssertEqual(p.intervaloReservaMouse, 1)
        XCTAssertGreaterThanOrEqual(PoliticaAtualizacao.padrao.intervaloDados, 30)
    }

    /// FRA-580: a leitura reaproveitada vale vários ciclos, mas não para sempre.
    func testIdadeMaximaDaLeitura() {
        let p = PoliticaAtualizacao.padrao
        XCTAssertGreaterThan(p.idadeMaximaLeitura, p.intervaloDados)
        XCTAssertEqual(PoliticaAtualizacao(idadeMaximaLeitura: 0).idadeMaximaLeitura, 1)
    }

    func testAnimacaoSoExpandido() {
        XCTAssertFalse(PoliticaAtualizacao.padrao.animarPonto(expandido: false))
        XCTAssertTrue(PoliticaAtualizacao.padrao.animarPonto(expandido: true))
    }

    func testDadosAntigosAoAbrirPainel() {
        let p = PoliticaAtualizacao.padrao
        let agora = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(p.dadosAntigos(atualizadoEm: nil, agora: agora), "nunca lido = antigo")
        XCTAssertFalse(p.dadosAntigos(atualizadoEm: agora, agora: agora))
        XCTAssertFalse(p.dadosAntigos(atualizadoEm: agora.addingTimeInterval(-4.9), agora: agora))
        XCTAssertTrue(p.dadosAntigos(atualizadoEm: agora.addingTimeInterval(-5), agora: agora))
        XCTAssertTrue(p.dadosAntigos(atualizadoEm: agora.addingTimeInterval(-p.intervaloDados), agora: agora))
    }

    func testIdadeAntigaAbaixoDoTimer() {
        // Se a idade passasse do intervalo do timer, abrir o painel nunca releria.
        XCTAssertLessThan(PoliticaAtualizacao.padrao.idadeAntiga, PoliticaAtualizacao.padrao.intervaloDados)
    }

    // FRA-582: com os mesmos dados, o painel só remonta depois de `validadePainel`.
    func testPainelValeDentroDaValidade() {
        let montado = data("2026-10-16T18:00:00")
        let validade = PoliticaAtualizacao.validadePainel
        XCTAssertTrue(PoliticaAtualizacao.painelVale(montadoEm: montado, agora: montado))
        XCTAssertTrue(PoliticaAtualizacao.painelVale(montadoEm: montado, agora: montado.addingTimeInterval(validade - 1)))
        XCTAssertFalse(PoliticaAtualizacao.painelVale(montadoEm: montado, agora: montado.addingTimeInterval(validade)))
        XCTAssertFalse(PoliticaAtualizacao.painelVale(montadoEm: montado, agora: montado.addingTimeInterval(-1)),
                       "relógio que voltou remonta")
        XCTAssertGreaterThanOrEqual(validade, PoliticaAtualizacao.intervaloMinimo)
    }

    // FRA-582: mesmos dados e mesma hora dão o mesmo snapshot, então `!=` não notifica as views à toa.
    func testMontadorEstavelComMesmosDados() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:20", dryRun: false, habilitadas: LanesPainel.ordem)
        entrada.habilitadas = Set(LanesPainel.ordem)
        let execs = [ex("FRA-399-opencode-20261016-120000", custo: 3.5)]
        let agora = data("2026-10-16T18:00:00")
        let a = MontadorPainel.montar(entrada: entrada, execucoes: execs, agora: agora,
                                      calendario: calendarioFixo(), taxaUsdBrl: 5)
        let b = MontadorPainel.montar(entrada: entrada, execucoes: execs, agora: agora,
                                      calendario: calendarioFixo(), taxaUsdBrl: 5)
        XCTAssertEqual(a, b)
    }
}
