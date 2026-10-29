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
}
