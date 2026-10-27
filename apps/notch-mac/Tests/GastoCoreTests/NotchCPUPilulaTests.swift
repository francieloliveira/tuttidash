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

    func testAnimacaoSoExpandido() {
        XCTAssertFalse(PoliticaAtualizacao.padrao.animarPonto(expandido: false))
        XCTAssertTrue(PoliticaAtualizacao.padrao.animarPonto(expandido: true))
    }
}

final class GeometriaPilulaTests: XCTestCase {
    let g = GeometriaPilula.padrao

    func testConteudoCurtoMantemLarguraAntiga() {
        XCTAssertEqual(g.largura(temNotch: true, larguraNotch: 196, esquerda: 70, direita: 80), 196 + 2 * 102)
    }

    func testCresceSimetricoComConteudoLongo() {
        // «⚠ grok bot 89%» ao lado de card · lane: antes cortava na borda
        let lado = g.lado(esquerda: 80, direita: 200)
        XCTAssertGreaterThanOrEqual(lado, 200)
        XCTAssertEqual(g.largura(temNotch: true, larguraNotch: 196, esquerda: 80, direita: 200), 196 + 2 * lado)
    }

    /// Texto mais longo possível: US$ 999.99 +? | ● FRA-9999 · claude +1 ⚠ grok bot · semana 100%.
    func testTextoMaisLongoPossivelNuncaCorta() {
        let esquerda = 17 + 7 + 72 + 2 + 14.0       // anel + US$ 3 dígitos + «+?»
        let porNivel: [NivelAviso: Double] = [
            .completo: 14 + 8 + 66 + 8 + 50 + 8 + 18 + 8 + 160,
            .semJanela: 14 + 8 + 66 + 8 + 50 + 8 + 18 + 8 + 110,
            .soPct: 14 + 8 + 66 + 8 + 50 + 8 + 18 + 8 + 56,
        ]
        let n = g.melhorNivel(esquerda: esquerda, direitaPorNivel: porNivel)
        XCTAssertEqual(n, .soPct)  // só cabe encurtado: «⚠ 100%»
        let d = porNivel[n]!
        let lado = g.lado(esquerda: esquerda, direita: d)
        // tudo cabe: o lado sempre comporta o conteúdo + respiro
        XCTAssertGreaterThanOrEqual(lado, d + g.respiro)
        XCTAssertGreaterThanOrEqual(lado, esquerda + g.respiro)
        XCTAssertLessThanOrEqual(lado, g.ladoMaximo)
    }

    func testEncurtaPassoAPassoAteCaber() {
        XCTAssertEqual(g.nivelAviso(atual: .completo, esquerda: 80, direita: 400), .semJanela)
        XCTAssertEqual(g.nivelAviso(atual: .semJanela, esquerda: 80, direita: 400), .soPct)
        XCTAssertEqual(g.nivelAviso(atual: .soPct, esquerda: 80, direita: 400), .soPct)
        XCTAssertEqual(g.nivelAviso(atual: .completo, esquerda: 80, direita: 100), .completo)
    }

    func testMesmoNoNivelMaisCurtoCresceSemCortar() {
        let lado = g.lado(esquerda: 80, direita: 400)
        XCTAssertGreaterThanOrEqual(lado, 400 + g.respiro)
    }
}
