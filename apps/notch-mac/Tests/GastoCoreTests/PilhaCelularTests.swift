import XCTest
@testable import GastoCore

/// FRA-654: a pilha do celular tem ordem fixa, uma coluna e altura de card presa à
/// faixa do próprio card. O tamanho gravado no desktop não entra nessa conta.
final class PilhaCelularTests: XCTestCase {
    private let ordemFixa: [BlocoPainel] = [
        .alertas, .lanes, .testes, .builds, .dispatcher, .entregas, .custos, .log,
    ]

    func testOrdemSegueAPrioridadeFixaMesmoComEntradaForaDeOrdem() {
        let entrada: [BlocoPainel] = [
            .custos, .builds, .log, .alertas, .entregas, .lanes, .dispatcher, .testes,
        ]
        XCTAssertEqual(PilhaCelular.ordem(entrada), ordemFixa)
        XCTAssertEqual(PilhaCelular.ordem(Array(ordemFixa.reversed())), ordemFixa)
    }

    func testPrioridadeDeCadaCardEhUnicaENaoDependeDoTamanhoGravado() {
        let prioridades = ordemFixa.map(PilhaCelular.prioridade)
        XCTAssertEqual(prioridades, Array(0..<ordemFixa.count))
        for bloco in BlocoPainel.allCases {
            XCTAssertEqual(PilhaCelular.span(bloco), 1, "\(bloco)")
            XCTAssertEqual(PilhaCelular.span(bloco, tamanhoGravado: 12), 1, "\(bloco)")
        }
    }

    func testTamanhoGravadoNaTelaLargaNaoAlteraNenhumQuadroDaPilha() {
        let semGravacao = PilhaCelular.molduras(largura: 390)
        let comGravacao = PilhaCelular.molduras(
            largura: 390,
            tamanhosGravados: ["alertas": 12, "lanes": 6, "testes": 4,
                               "builds": 3, "custos": 12])

        XCTAssertEqual(comGravacao, semGravacao)
        for quadro in comGravacao {
            XCTAssertEqual(quadro.largura, 390 - 2 * PilhaCelular.margem, "\(quadro.bloco)")
            XCTAssertEqual(quadro.x, PilhaCelular.margem, "\(quadro.bloco)")
        }
    }

    func testCardGrandeNaoEmpurraNemSobrepoeOVizinho() {
        let quadros = PilhaCelular.molduras(largura: 390) { bloco in
            bloco == .lanes ? 10_000 : 700
        }
        let faixaLanes = PilhaCelular.altura(.lanes)

        XCTAssertEqual(quadros.count, ordemFixa.count)
        for quadro in quadros {
            XCTAssertLessThanOrEqual(quadro.altura, PilhaCelular.altura(quadro.bloco).maxima,
                                     "\(quadro.bloco)")
            XCTAssertGreaterThanOrEqual(quadro.altura, PilhaCelular.altura(quadro.bloco).minima,
                                        "\(quadro.bloco)")
        }
        XCTAssertEqual(quadros[1].altura, faixaLanes.maxima, accuracy: 0.0001)

        for (anterior, seguinte) in zip(quadros, quadros.dropFirst()) {
            XCTAssertEqual(seguinte.y, anterior.fim + PilhaCelular.espacamento,
                           accuracy: 0.0001, "\(anterior.bloco) -> \(seguinte.bloco)")
            XCTAssertGreaterThanOrEqual(seguinte.y, anterior.fim, "\(anterior.bloco)")
        }
    }

    func testCardPequenoNaoAbreBuracoEntreVizinhos() {
        let quadros = PilhaCelular.molduras(largura: 390) { _ in 0 }

        for (anterior, seguinte) in zip(quadros, quadros.dropFirst()) {
            XCTAssertEqual(seguinte.y, anterior.fim + PilhaCelular.espacamento,
                           accuracy: 0.0001, "\(anterior.bloco) -> \(seguinte.bloco)")
            XCTAssertEqual(anterior.altura, PilhaCelular.altura(anterior.bloco).minima,
                           accuracy: 0.0001, "\(anterior.bloco)")
        }
    }

    func testPilhaTemUmaColunaCheiaEmQualquerLarguraDeCelular() {
        for largura in [320.0, 360.0, 390.0, 430.0] {
            let quadros = PilhaCelular.molduras(largura: largura)
            XCTAssertEqual(quadros.count, BlocoPainel.allCases.count, "largura \(largura)")
            for (indice, quadro) in quadros.enumerated() {
                XCTAssertEqual(quadro.ordem, indice, "\(quadro.bloco)")
                XCTAssertEqual(quadro.x, PilhaCelular.margem, "\(quadro.bloco)")
                XCTAssertEqual(quadro.largura, largura - 2 * PilhaCelular.margem,
                               accuracy: 0.0001, "\(quadro.bloco)")
                XCTAssertEqual(quadro.largura, max(0, largura - 2 * PilhaCelular.margem),
                               accuracy: 0.0001, "\(quadro.bloco)")
            }
        }
    }

    func testCadaBlocoApareceUmaVezNaOrdemFixa() {
        let quadros = PilhaCelular.molduras(largura: 390)
        XCTAssertEqual(quadros.map(\.bloco), ordemFixa)
        XCTAssertEqual(Set(quadros.map { $0.bloco.rawValue }).count, BlocoPainel.allCases.count)
    }

    func testAlturaPadraoFicaDentroDaFaixaDeCadaCard() {
        for bloco in BlocoPainel.allCases {
            let faixa = PilhaCelular.altura(bloco)
            XCTAssertGreaterThanOrEqual(faixa.padrao, faixa.minima, "\(bloco)")
            XCTAssertLessThanOrEqual(faixa.padrao, faixa.maxima, "\(bloco)")
            XCTAssertEqual(faixa.ajustada(faixa.padrao), faixa.padrao, "\(bloco)")
        }
    }

    func testConteudoInvalidoVoltaParaAAlturaPadrao() {
        let faixa = PilhaCelular.altura(.lanes)
        XCTAssertEqual(faixa.ajustada(.nan), faixa.padrao)
        XCTAssertEqual(faixa.ajustada(.infinity), faixa.padrao)
        XCTAssertEqual(faixa.ajustada(-10_000), faixa.minima)
        XCTAssertEqual(faixa.ajustada(10_000), faixa.maxima)
    }

    func testPilhaSemBlocosNaoTemQuadro() {
        XCTAssertTrue(PilhaCelular.molduras(largura: 390, blocos: []).isEmpty)
        XCTAssertTrue(PilhaCelular.ordem([]).isEmpty)
    }
}
