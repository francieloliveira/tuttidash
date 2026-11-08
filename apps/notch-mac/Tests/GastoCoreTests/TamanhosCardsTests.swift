import XCTest
@testable import GastoCore

/// FRA-653: o tamanho dos cards fica gravado por pessoa e só vale na tela larga.
/// Celular e tablet ignoram a escolha de desktop; uma pessoa não mexe na outra.
final class TamanhosCardsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suites.removeAll()
        super.tearDown()
    }

    private func novoDefaults() -> UserDefaults {
        let suite = "fra653-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        suites.append(suite)
        return defaults
    }

    private func armazem(_ defaults: UserDefaults) -> ArmazemTamanhosCards {
        ArmazemTamanhosCards(defaults: defaults)
    }

    func testTelaLargaReabreComOsTamanhosGravadosDaPessoa() {
        let defaults = novoDefaults()
        var escolhidos = TamanhosCards()
        escolhidos.escolher(5, para: .lanes)
        escolhidos.escolher(3, para: .testes)
        armazem(defaults).gravar(escolhidos, para: "ana")

        // Outro armazém sobre o mesmo disco simula fechar e reabrir o dashboard.
        let reaberto = armazem(defaults).ler(pessoa: "ana", em: .telaLarga)
        XCTAssertEqual(reaberto.escolhido(.lanes), 5)
        XCTAssertEqual(reaberto.escolhido(.testes), 3)
        XCTAssertEqual(reaberto.span(.lanes, em: .telaLarga), 5)
        XCTAssertEqual(reaberto.span(.testes, em: .telaLarga), 3)
        XCTAssertEqual(reaberto.span(.builds, em: .telaLarga), BlocoPainel.builds.span.maximo)
    }

    func testCelularETabletNaoAplicamOsTamanhosGravados() {
        let defaults = novoDefaults()
        var escolhidos = TamanhosCards()
        escolhidos.escolher(5, para: .lanes)
        escolhidos.escolher(3, para: .testes)
        armazem(defaults).gravar(escolhidos, para: "ana")

        for tela in [ClasseTelaDashboard.celular, .tablet] {
            let lido = armazem(defaults).ler(pessoa: "ana", em: tela)
            XCTAssertTrue(lido.vazio, "\(tela) não carrega a escolha de desktop")
            XCTAssertEqual(lido.span(.lanes, em: tela), BlocoPainel.lanes.span.maximo, "\(tela)")
            XCTAssertEqual(lido.span(.testes, em: tela), BlocoPainel.testes.span.maximo, "\(tela)")
        }
    }

    func testGravacaoDeUmaPessoaNaoMudaOlayoutDeOutra() {
        let defaults = novoDefaults()
        let loja = armazem(defaults)
        var ana = TamanhosCards()
        ana.escolher(4, para: .lanes)
        var bia = TamanhosCards()
        bia.escolher(6, para: .lanes)

        loja.gravar(ana, para: "ana")
        loja.gravar(bia, para: "bia")

        XCTAssertEqual(loja.ler(pessoa: "ana", em: .telaLarga).span(.lanes, em: .telaLarga), 4)
        XCTAssertEqual(loja.ler(pessoa: "bia", em: .telaLarga).span(.lanes, em: .telaLarga), 6)

        // Gravar de novo numa pessoa não altera a outra.
        ana.escolher(5, para: .lanes)
        loja.gravar(ana, para: "ana")
        XCTAssertEqual(loja.ler(pessoa: "ana", em: .telaLarga).span(.lanes, em: .telaLarga), 5)
        XCTAssertEqual(loja.ler(pessoa: "bia", em: .telaLarga).span(.lanes, em: .telaLarga), 6)
    }

    func testPessoaSemIdentificadorNaoLeNemGrava() {
        let defaults = novoDefaults()
        let loja = armazem(defaults)
        var escolhidos = TamanhosCards()
        escolhidos.escolher(5, para: .lanes)

        XCTAssertNil(ArmazemTamanhosCards.chave(pessoa: "   "))
        loja.gravar(escolhidos, para: "   ")

        XCTAssertTrue(loja.ler(pessoa: "   ", em: .telaLarga).vazio)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(ArmazemTamanhosCards.prefixoChave)
        })
    }

    func testEscolhaForaDaFaixaFicaPresaNoLimiteDoCard() {
        var tamanhos = TamanhosCards()
        tamanhos.escolher(0, para: .lanes)
        XCTAssertEqual(tamanhos.escolhido(.lanes), BlocoPainel.lanes.span.minimo)

        tamanhos.escolher(99, para: .lanes)
        XCTAssertEqual(tamanhos.escolhido(.lanes), BlocoPainel.lanes.span.maximo)

        for bloco in BlocoPainel.allCases {
            tamanhos.escolher(-10, para: bloco)
            XCTAssertEqual(tamanhos.span(bloco, em: .telaLarga), bloco.span.minimo, "\(bloco)")
            tamanhos.escolher(10_000, para: bloco)
            XCTAssertEqual(tamanhos.span(bloco, em: .telaLarga), bloco.span.maximo, "\(bloco)")
        }
    }

    func testDadoCorrompidoVoltaAoPadrao() {
        let defaults = novoDefaults()
        let chave = ArmazemTamanhosCards.chave(pessoa: "ana")!
        defaults.set(Data("isto não é json".utf8), forKey: chave)

        let lido = armazem(defaults).ler(pessoa: "ana", em: .telaLarga)
        XCTAssertTrue(lido.vazio)
        XCTAssertEqual(lido.span(.lanes, em: .telaLarga), BlocoPainel.lanes.span.maximo)
    }

    func testBlocoDesconhecidoNaGravacaoEhIgnorado() {
        let defaults = novoDefaults()
        let chave = ArmazemTamanhosCards.chave(pessoa: "ana")!
        defaults.set(Data(#"{"lanes":5,"card_que_nao_existe":4}"#.utf8), forKey: chave)

        let lido = armazem(defaults).ler(pessoa: "ana", em: .telaLarga)
        XCTAssertEqual(lido.span(.lanes, em: .telaLarga), 5)
        XCTAssertNil(lido.escolhido(.builds))
    }

    func testApagarUmaPessoaNaoTocaNasOutras() {
        let defaults = novoDefaults()
        let loja = armazem(defaults)
        var ana = TamanhosCards()
        ana.escolher(5, para: .lanes)
        var bia = TamanhosCards()
        bia.escolher(6, para: .lanes)
        loja.gravar(ana, para: "ana")
        loja.gravar(bia, para: "bia")

        loja.apagar(pessoa: "ana")

        XCTAssertTrue(loja.ler(pessoa: "ana", em: .telaLarga).vazio)
        XCTAssertEqual(loja.ler(pessoa: "bia", em: .telaLarga).span(.lanes, em: .telaLarga), 6)
    }

    func testClasseDeTelaPelosLimitesDeLargura() {
        XCTAssertEqual(ClasseTelaDashboard(largura: 0), .celular)
        XCTAssertEqual(ClasseTelaDashboard(largura: 599), .celular)
        XCTAssertEqual(ClasseTelaDashboard(largura: 600), .tablet)
        XCTAssertEqual(ClasseTelaDashboard(largura: 1023), .tablet)
        XCTAssertEqual(ClasseTelaDashboard(largura: 1024), .telaLarga)
        XCTAssertEqual(ClasseTelaDashboard(largura: 1600), .telaLarga)

        XCTAssertFalse(ClasseTelaDashboard.celular.usaTamanhosGravados)
        XCTAssertFalse(ClasseTelaDashboard.tablet.usaTamanhosGravados)
        XCTAssertTrue(ClasseTelaDashboard.telaLarga.usaTamanhosGravados)
    }

    func testSemEscolhaCadaCardUsaOMaximoDeclarado() {
        let tamanhos = TamanhosCards()
        for bloco in BlocoPainel.allCases {
            let span = tamanhos.span(bloco, em: .telaLarga)
            XCTAssertEqual(span, bloco.span.maximo, "\(bloco)")
            XCTAssertTrue(bloco.span.aceita(span), "\(bloco)")
            XCTAssertNil(tamanhos.escolhido(bloco), "\(bloco)")
        }
    }

    func testSpansDaTelaTrazemTodosOsCardsNaOrdemDoPainel() {
        var tamanhos = TamanhosCards()
        tamanhos.escolher(5, para: .lanes)
        let spans = tamanhos.spans(em: .telaLarga)
        XCTAssertEqual(spans.map { $0.bloco }, BlocoPainel.allCases)
        XCTAssertEqual(spans.first { $0.bloco == .lanes }?.span, 5)
    }
}
