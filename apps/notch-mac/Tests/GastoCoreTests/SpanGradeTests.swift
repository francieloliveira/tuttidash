import XCTest
@testable import GastoCore

/// FRA-651: span discreto com mínimo, máximo e encaixe.
/// Cada card declara o que aceita, o efetivo fica no intervalo e um pedido entre
/// células da grade é rejeitado em vez de arredondado.
final class SpanGradeTests: XCTestCase {
    func testCadaCardDeclaraMinimoEMaximo() {
        for bloco in BlocoPainel.allCases {
            let span = bloco.span
            XCTAssertGreaterThanOrEqual(span.minimo, 1, "\(bloco)")
            XCTAssertGreaterThanOrEqual(span.maximo, span.minimo, "\(bloco)")
            XCTAssertLessThanOrEqual(span.maximo, 12, "\(bloco): a grade do dashboard tem 12 colunas")
        }
        XCTAssertEqual(BlocoPainel.alertas.span.faixa, 12...12)
    }

    func testEfetivoNuncaFicaAbaixoDoMinimoNemAcimaDoMaximo() {
        let span = SpanGrade(minimo: 3, maximo: 6)!
        for pedido in -20...20 {
            let efetivo = span.efetivo(pedido)
            XCTAssertGreaterThanOrEqual(efetivo, 3, "pedido \(pedido)")
            XCTAssertLessThanOrEqual(efetivo, 6, "pedido \(pedido)")
        }
        XCTAssertEqual(span.efetivo(1), 3)
        XCTAssertEqual(span.efetivo(4), 4)
        XCTAssertEqual(span.efetivo(9), 6)
    }

    func testSpanEfetivoDeCadaCardRespeitaADeclaracao() {
        for bloco in BlocoPainel.allCases {
            let span = bloco.span
            for pedido in [-5, 0, 1, 3, 4, 6, 8, 12, 40] {
                XCTAssertTrue(span.aceita(span.efetivo(pedido)), "\(bloco) com pedido \(pedido)")
            }
        }
    }

    func testValorEscolhidoCoincideComCelulasInteiras() {
        let span = SpanGrade(minimo: 2, maximo: 5)!
        XCTAssertEqual(span.encaixe(2.0), 2)
        XCTAssertEqual(span.encaixe(4.0), 4)
        XCTAssertEqual(span.encaixe(9.0), 5)
    }

    func testSpanIntermediarioQueNaoFechaNaGradeEhRejeitado() {
        let span = SpanGrade(minimo: 2, maximo: 6)!
        XCTAssertNil(span.encaixe(2.5))
        XCTAssertNil(span.encaixe(3.0001))
        XCTAssertNil(span.encaixe(0.5))
        XCTAssertNil(span.encaixe(-1.0))
        XCTAssertNil(span.encaixe(.nan))
        XCTAssertNil(span.encaixe(.infinity))
    }

    func testDeclaracaoInvalidaEhRejeitada() {
        XCTAssertNil(SpanGrade(minimo: 0, maximo: 4))
        XCTAssertNil(SpanGrade(minimo: 5, maximo: 4))
        XCTAssertNotNil(SpanGrade(minimo: 1, maximo: 1))
    }
}
