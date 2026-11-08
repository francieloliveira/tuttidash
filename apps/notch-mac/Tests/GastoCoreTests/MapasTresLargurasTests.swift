import XCTest
@testable import GastoCore

/// FRA-650: cada largura (celular, tablet, tela larga) tem o próprio mapa do que
/// permanece, do que empilha e do que some. O que some não ocupa espaço, o que
/// empilha troca de eixo sem comprimir o vizinho e a troca de largura troca o
/// mapa inteiro, sem misturar regras de outra largura.
final class MapasTresLargurasTests: XCTestCase {
    private let todos = BlocoPainel.allCases
    private let visiveisCelular: [BlocoPainel] = [
        .alertas, .lanes, .testes, .builds, .dispatcher, .entregas,
    ]

    // MARK: Mapas distintos por largura

    func testCadaLarguraTemOSeuMapa() {
        let celular = MapasTresLarguras.mapa(em: .celular)
        let tablet = MapasTresLarguras.mapa(em: .tablet)
        let desktop = MapasTresLarguras.mapa(em: .telaLarga)

        XCTAssertEqual(celular.colunas, 1)
        XCTAssertEqual(tablet.colunas, 6)
        XCTAssertEqual(desktop.colunas, 12)

        XCTAssertEqual(celular.ocultos, Set([BlocoPainel.log, .custos]))
        XCTAssertEqual(tablet.ocultos, Set([BlocoPainel.log]))
        XCTAssertTrue(desktop.ocultos.isEmpty)

        XCTAssertFalse(celular.usaTamanhosGravados)
        XCTAssertFalse(tablet.usaTamanhosGravados)
        XCTAssertTrue(desktop.usaTamanhosGravados)

        XCTAssertNotEqual(celular, tablet)
        XCTAssertNotEqual(tablet, desktop)
        XCTAssertNotEqual(desktop, celular)
    }

    func testTabelasDosMapasCabemNaGradeDeclarada() {
        let mapas = [MapasTresLarguras.celular, MapasTresLarguras.tablet,
                     MapasTresLarguras.desktop]
        for mapa in mapas {
            XCTAssertGreaterThanOrEqual(mapa.colunas, 1, "\(mapa.tela)")
            for (bloco, span) in mapa.spans {
                XCTAssertGreaterThanOrEqual(span, 1, "\(bloco) em \(mapa.tela)")
                XCTAssertLessThanOrEqual(span, mapa.colunas, "\(bloco) em \(mapa.tela)")
            }
            for bloco in BlocoPainel.allCases {
                let span = mapa.span(bloco)
                XCTAssertTrue((1...mapa.colunas).contains(span), "\(bloco) em \(mapa.tela)")
            }
        }
    }

    // MARK: O que some deixa de ocupar espaço

    func testPapelDeclaradoDistingueOQueSomeEmCadaLargura() {
        let celular = MapasTresLarguras.celular
        let tablet = MapasTresLarguras.tablet
        let desktop = MapasTresLarguras.desktop

        XCTAssertEqual(celular.papel(.custos), .some)
        XCTAssertEqual(celular.papel(.log), .some)
        XCTAssertEqual(celular.papel(.lanes), .permanece)

        XCTAssertEqual(tablet.papel(.log), .some)
        XCTAssertEqual(tablet.papel(.custos), .permanece)

        XCTAssertEqual(desktop.papel(.log), .permanece)
        XCTAssertEqual(desktop.papel(.custos), .permanece)
    }

    func testOQueSomeNoCelularNaoOcupaEspaco() {
        let quadros = MapasTresLarguras.molduras(todos, em: .celular)

        XCTAssertEqual(quadros.map(\.bloco), visiveisCelular)
        XCTAssertEqual(quadros.map(\.fileira), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(quadros.map(\.span), [1, 1, 1, 1, 1, 1])
        for quadro in quadros {
            XCTAssertNotEqual(quadro.bloco, .log)
            XCTAssertNotEqual(quadro.bloco, .custos)
        }
    }

    func testOQueSomeNoTabletNaoAbreBuracoNemEmpurraFileira() {
        let quadros = MapasTresLarguras.molduras(todos, em: .tablet)

        XCTAssertEqual(quadros.map(\.bloco), [
            .alertas, .lanes, .testes, .builds, .dispatcher, .entregas, .custos,
        ])
        // Fileiras contíguas: o log sumiu sem deixar fileira vazia no meio.
        XCTAssertEqual(quadros.map(\.fileira), [0, 1, 1, 2, 2, 2, 3])
        for quadro in quadros {
            XCTAssertNotEqual(quadro.bloco, .log)
        }
    }

    // MARK: O que empilha troca de eixo

    func testEmpilharTrocaDeEixoSemComprimirOVizinho() {
        var escolhidos = TamanhosCards()
        escolhidos.escolher(6, para: .lanes) // 6 + 4 não cabem juntos: builds desce
        let quadros = MapasTresLarguras.molduras(todos, em: .telaLarga, tamanhos: escolhidos)

        let lanes = quadros.first { $0.bloco == .lanes }!
        let testes = quadros.first { $0.bloco == .testes }!
        let builds = quadros.first { $0.bloco == .builds }!

        XCTAssertEqual(lanes.span, 6)
        XCTAssertEqual(testes.span, 4, "o vizinho não foi comprimido")
        XCTAssertEqual(builds.span, 4, "o span inteiro desceu junto")
        XCTAssertEqual(builds.papel, .empilha)
        XCTAssertEqual(builds.fileira, lanes.fileira + 1)
        XCTAssertEqual(builds.coluna, 0)

        // Cada fileira fecha dentro da grade, sem sobrepor.
        for (fileira, grupo) in Dictionary(grouping: quadros, by: { $0.fileira }) {
            XCTAssertLessThanOrEqual(grupo.map(\.span).reduce(0, +),
                                     MapasTresLarguras.colunasDesktop,
                                     "fileira \(fileira)")
        }
    }

    func testCadaFileiraNuncaPassaDaGradeEmNenhumaLargura() {
        for tela in ClasseTelaDashboard.allCases {
            let mapa = MapasTresLarguras.mapa(em: tela)
            let quadros = MapasTresLarguras.molduras(todos, em: tela)
            for (fileira, grupo) in Dictionary(grouping: quadros, by: { $0.fileira }) {
                XCTAssertLessThanOrEqual(grupo.map(\.span).reduce(0, +), mapa.colunas,
                                         "\(tela) fileira \(fileira)")
            }
        }
    }

    // MARK: Mudar a largura troca o mapa inteiro

    func testMudarALarguraTrocaOMapaInteiroSemMisturarRegras() {
        var escolhidos = TamanhosCards()
        escolhidos.escolher(4, para: .lanes)

        let desktop = MapasTresLarguras.molduras(todos, em: .telaLarga, tamanhos: escolhidos)
        let tablet = MapasTresLarguras.molduras(todos, em: .tablet, tamanhos: escolhidos)
        let celular = MapasTresLarguras.molduras(todos, em: .celular, tamanhos: escolhidos)

        // A escolha de desktop só vale na tela larga (FRA-653): tablet e celular
        // não leem o tamanho gravado.
        XCTAssertEqual(desktop.first { $0.bloco == .lanes }?.span, 4)
        XCTAssertEqual(tablet.first { $0.bloco == .lanes }?.span, 3)
        XCTAssertEqual(celular.first { $0.bloco == .lanes }?.span, 1)

        // Com ou sem escolha gravada, o mapa do tablet e o do celular são os mesmos.
        XCTAssertEqual(tablet, MapasTresLarguras.molduras(todos, em: .tablet))
        XCTAssertEqual(celular, MapasTresLarguras.molduras(todos, em: .celular))
        XCTAssertNotEqual(desktop, MapasTresLarguras.molduras(todos, em: .telaLarga))
    }

    // MARK: Mapas do app

    func testDesktopSemEscolhaUsaOMaximoDeclaradoPorCard() {
        let quadros = MapasTresLarguras.molduras(todos, em: .telaLarga)
        let porBloco = Dictionary(uniqueKeysWithValues: quadros.map { ($0.bloco, $0) })

        XCTAssertEqual(porBloco[.alertas]?.papel, .permanece)
        XCTAssertEqual(porBloco[.alertas]?.span, 12)
        XCTAssertEqual(porBloco[.lanes]?.span, 6)
        XCTAssertEqual(porBloco[.testes]?.span, 4)
        XCTAssertEqual(porBloco[.custos]?.span, 12)
        XCTAssertEqual(porBloco[.log]?.span, 12)
        XCTAssertEqual(porBloco[.builds]?.papel, .empilha)
        XCTAssertEqual(porBloco[.custos]?.papel, .empilha)
        XCTAssertEqual(porBloco[.log]?.papel, .empilha)

        XCTAssertEqual(quadros.map(\.fileira), [0, 1, 1, 2, 2, 2, 3, 4])
    }

    func testTabletEmpilhaNaGradeDeSeisComSpanProprio() {
        let quadros = MapasTresLarguras.molduras(todos, em: .tablet)
        let resumo = quadros.map { "\($0.bloco.rawValue)@\($0.fileira):\($0.coluna)x\($0.span)" }
        XCTAssertEqual(resumo, [
            "alertas@0:0x6",
            "lanes@1:0x3", "testes@1:3x2",
            "builds@2:0x2", "dispatcher@2:2x2", "entregas@2:4x2",
            "custos@3:0x6",
        ])
    }

    func testCelularEmpilhaTudoEmUmaColuna() {
        let quadros = MapasTresLarguras.molduras(todos, em: .celular)
        let resumo = quadros.map { "\($0.bloco.rawValue)@\($0.fileira):\($0.coluna)x\($0.span)" }
        XCTAssertEqual(resumo, [
            "alertas@0:0x1", "lanes@1:0x1", "testes@2:0x1",
            "builds@3:0x1", "dispatcher@4:0x1", "entregas@5:0x1",
        ])
        XCTAssertEqual(quadros.first?.papel, .permanece)
        for quadro in quadros.dropFirst() {
            XCTAssertEqual(quadro.papel, .empilha, "\(quadro.bloco)")
        }
    }

    // MARK: Ordem e casos vazios

    func testMoldurasRespeitamAOrdemRecebida() {
        let embaralhados: [BlocoPainel] = [.custos, .lanes, .alertas]
        let quadros = MapasTresLarguras.molduras(embaralhados, em: .telaLarga)
        XCTAssertEqual(quadros.map(\.bloco), embaralhados)
    }

    func testSemBlocosNaoHaQuadros() {
        XCTAssertTrue(MapasTresLarguras.molduras([], em: .telaLarga).isEmpty)
        XCTAssertTrue(MapasTresLarguras.molduras([], em: .tablet).isEmpty)
        XCTAssertTrue(MapasTresLarguras.molduras([], em: .celular).isEmpty)
    }

    func testMapaOcultoRecebidoDiretoTambemSome() {
        let quadros = MapasTresLarguras.molduras(todos, mapa: MapasTresLarguras.celular)
        XCTAssertEqual(quadros.map(\.bloco), visiveisCelular)
    }
}
