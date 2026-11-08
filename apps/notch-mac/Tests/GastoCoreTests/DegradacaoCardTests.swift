import XCTest
@testable import GastoCore

final class DegradacaoCardTests: XCTestCase {
    private let completo = [
        PecaCard(id: "lane", prioridade: .essencial),
        PecaCard(id: "status", prioridade: .essencial),
        PecaCard(id: "detalhe", prioridade: .secundaria,
                 minimo: EspacoCard(largura: 0, altura: 46)),
        PecaCard(id: "build", prioridade: .detalhe,
                 minimo: EspacoCard(largura: 0, altura: 50)),
    ]

    func testEspacoFolgadoMostraConteudoCompleto() {
        XCTAssertEqual(
            DegradacaoCard.visiveis(completo, em: EspacoCard(largura: 300, altura: 60)),
            ["lane", "status", "detalhe", "build"])
        XCTAssertFalse(DegradacaoCard.degradado(completo, em: EspacoCard(largura: 300, altura: 60)))
    }

    func testEspacoApertadoTiraSecundarioAntesDoEssencial() {
        XCTAssertEqual(
            DegradacaoCard.visiveis(completo, em: EspacoCard(largura: 300, altura: 40)),
            ["lane", "status"])
        XCTAssertTrue(DegradacaoCard.degradado(completo, em: EspacoCard(largura: 300, altura: 40)))
    }

    func testEspacoIntermediarioMantemOQueAindaCabe() {
        XCTAssertEqual(
            DegradacaoCard.visiveis(completo, em: EspacoCard(largura: 300, altura: 47)),
            ["lane", "status", "detalhe"])
    }

    func testVoltarAEspacoRestauraOConteudoOmitido() {
        let apertado = DegradacaoCard.visiveis(completo, em: EspacoCard(largura: 300, altura: 40))
        let folgado = DegradacaoCard.visiveis(completo, em: EspacoCard(largura: 300, altura: 60))
        XCTAssertEqual(apertado, ["lane", "status"])
        XCTAssertEqual(folgado, completo.map(\.id))
    }

    func testDecisaoDependeDoEspacoDoCardENaoDaJanela() {
        let cardApertado = EspacoCard(largura: 250, altura: 40)
        let cardFolgado = EspacoCard(largura: 250, altura: 60)
        XCTAssertEqual(DegradacaoCard.visiveis(completo, em: cardApertado), ["lane", "status"])
        XCTAssertEqual(DegradacaoCard.visiveis(completo, em: cardFolgado), completo.map(\.id))
    }

    func testEssencialFicaMesmoSemEspaco() {
        let pecas = [
            PecaCard(id: "lane", prioridade: .essencial,
                     minimo: EspacoCard(largura: 100, altura: 40)),
            PecaCard(id: "status", prioridade: .essencial,
                     minimo: EspacoCard(largura: 100, altura: 40)),
        ]
        XCTAssertEqual(DegradacaoCard.visiveis(pecas, em: .zero), ["lane"])
    }

    func testRespeitaLarguraEMinimoDeCadaPeca() {
        let pecas = [
            PecaCard(id: "valor", prioridade: .essencial),
            PecaCard(id: "delta", prioridade: .secundaria,
                     minimo: EspacoCard(largura: 220, altura: 0)),
            PecaCard(id: "grafico", prioridade: .detalhe,
                     minimo: EspacoCard(largura: 300, altura: 0)),
        ]
        XCTAssertEqual(
            DegradacaoCard.visiveis(pecas, em: EspacoCard(largura: 260, altura: 80)),
            ["valor", "delta"])
        XCTAssertEqual(
            DegradacaoCard.visiveis(pecas, em: EspacoCard(largura: 320, altura: 80)),
            ["valor", "delta", "grafico"])
    }

    func testOrdemDePrioridadeNaoDependeDaOrdemDeEntrada() {
        let pecas = [
            PecaCard(id: "grafico", prioridade: .detalhe),
            PecaCard(id: "valor", prioridade: .essencial),
            PecaCard(id: "delta", prioridade: .secundaria),
        ]
        XCTAssertEqual(
            DegradacaoCard.visiveis(pecas, em: EspacoCard(largura: 300, altura: 80)),
            ["valor", "delta", "grafico"])
    }

    func testAtalhoPorAlturaUsaIgnoraLargura() {
        XCTAssertEqual(DegradacaoCard.visiveis(completo, altura: 40), ["lane", "status"])
        XCTAssertEqual(DegradacaoCard.visiveis(completo, altura: 60), completo.map(\.id))
    }
}
