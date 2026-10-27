import XCTest
@testable import GastoCore

/// Lista completa de cards da tela Custos: mesma agregação do ranking, sem o corte por custo.
final class ListaBuildsTests: XCTestCase {
    private let agora = data("2026-10-16T18:00:00")

    private func card(_ id: String, custo: Double? = nil, inicio: String? = nil) -> CardCaro {
        CardCaro(card: id, lane: "claude", descricao: nil, custoUSD: custo, duracaoMs: 0,
                 tentativas: 1, motivo: nil, destaque: false,
                 ultimoInicio: inicio.flatMap { Datas.lerLocal($0, calendario: calendarioFixo()) })
    }

    func testTamanhoDePaginaCabeNaTela() {
        XCTAssertGreaterThanOrEqual(ListaBuilds.tamanhoPagina, 20)
        XCTAssertLessThanOrEqual(ListaBuilds.tamanhoPagina, 50)
        XCTAssertEqual(ListaBuilds.tamanhoPagina, ListaPaginada<CardCaro>.tamanhoPadrao)
    }

    func testPaginaDelegaParaListaPaginada() {
        let cards = (1...3).map { card("FRA-\($0)") }
        let pagina = ListaBuilds.pagina(cards, numero: 2, tamanho: 2)
        let fatia = ListaPaginada.cortar(cards, numero: 2, tamanho: 2, vazio: "0 builds")
        XCTAssertEqual(pagina.itens, fatia.itens)
        XCTAssertEqual(pagina.intervalo, fatia.intervalo)
        XCTAssertEqual(pagina.pagina, fatia.pagina)
        XCTAssertEqual(pagina.paginas, fatia.paginas)
        XCTAssertEqual(pagina.total, fatia.total)
        XCTAssertEqual(pagina.tamanho, fatia.tamanho)
    }

    func testRecenciaIgnoraOCustoEDeixaSemDataNoFim() {
        let ordem = ListaBuilds.porRecencia([
            card("FRA-2", custo: 1, inicio: "2026-10-16 10:00:00"),
            card("FRA-9", custo: 50, inicio: nil),
            card("FRA-3", custo: 0, inicio: "2026-10-15 09:00:00"),
            card("FRA-1", custo: 99, inicio: "2026-10-16 10:00:00"),
        ]).map(\.card)
        XCTAssertEqual(ordem, ["FRA-1", "FRA-2", "FRA-3", "FRA-9"])
    }

    func testPaginaCortaEncostaEContaOIntervalo() {
        let vazio = ListaBuilds.pagina([], numero: 4)
        XCTAssertEqual(vazio.total, 0)
        XCTAssertEqual(vazio.pagina, 1)
        XCTAssertEqual(vazio.paginas, 1)
        XCTAssertTrue(vazio.itens.isEmpty)
        XCTAssertEqual(vazio.intervalo, "0 builds")
        XCTAssertFalse(vazio.temAnterior)
        XCTAssertFalse(vazio.temProxima)

        let cards = (1...3).map { card("FRA-\($0)") }
        let unica = ListaBuilds.pagina(cards, numero: 1)
        XCTAssertEqual(unica.itens.count, 3)
        XCTAssertEqual(unica.intervalo, "1 a 3 de 3")
        XCTAssertEqual(unica.paginas, 1)
        XCTAssertFalse(unica.temAnterior)
        XCTAssertFalse(unica.temProxima)

        let um = ListaBuilds.pagina([cards[0]], numero: -2)
        XCTAssertEqual(um.pagina, 1)
        XCTAssertEqual(um.intervalo, "1 de 1")

        let p2 = ListaBuilds.pagina(cards, numero: 2, tamanho: 2)
        XCTAssertEqual(p2.itens.map(\.card), ["FRA-3"])
        XCTAssertEqual(p2.intervalo, "3 de 3")
        XCTAssertEqual(p2.paginas, 2)
        XCTAssertTrue(p2.temAnterior)
        XCTAssertFalse(p2.temProxima)

        let alem = ListaBuilds.pagina(cards, numero: 99, tamanho: 2)
        XCTAssertEqual(alem.pagina, 2)
        XCTAssertEqual(alem.itens.map(\.card), ["FRA-3"])

        let tamanhoZero = ListaBuilds.pagina(cards, numero: 1, tamanho: 0)
        XCTAssertEqual(tamanhoZero.tamanho, 1)
        XCTAssertEqual(tamanhoZero.itens.map(\.card), ["FRA-1"])
        XCTAssertTrue(tamanhoZero.temProxima)
    }

    func testSemanaListaQuemORankingCortaEMantemOCusto() {
        var entrada = EntradaPainel.vazia
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
        let semana = montar(entrada, execs).custos.periodos[.semana]!
        XCTAssertEqual(semana.top.map(\.card), ["FRA-399", "FRA-401", "FRA-395", "FRA-187", "FRA-406"])
        XCTAssertEqual(semana.builds.map(\.card), ["FRA-399", "FRA-408", "FRA-406", "FRA-187", "FRA-395", "FRA-401"])
        XCTAssertFalse(semana.top.contains { $0.card == "FRA-408" })
        XCTAssertEqual(semana.builds.first { $0.card == "FRA-399" }?.custoUSD ?? 0, 22, accuracy: 0.001)
        XCTAssertEqual(semana.builds.first { $0.card == "FRA-399" }?.descricao, "testes de tela")
        XCTAssertEqual(semana.builds.first { $0.card == "FRA-399" }?.motivo, "falha repetida")
        XCTAssertEqual(semana.top.first?.custoUSD ?? 0, 22, accuracy: 0.001)
        let pagina = ListaBuilds.pagina(semana.builds, numero: 2, tamanho: 2)
        XCTAssertEqual(pagina.itens.map(\.card), ["FRA-406", "FRA-187"])
        XCTAssertEqual(pagina.intervalo, "3 a 4 de 6")
    }

    func testMesEAnoUsamORecorteDoRanking() {
        let execs = [
            ex("FRA-1-claude-20261001-100000", custo: 2),
            ex("FRA-2-codex-20261014-100000", custo: 3),
            ex("FRA-3-claude-20260915-100000", custo: 7),
            ex("FRA-4-grok-20261015-100000", custo: nil),
        ]
        let custos = montar(.vazia, execs).custos
        let mes = custos.periodos[.mes]!
        XCTAssertEqual(mes.total ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(mes.top.map(\.card), ["FRA-2", "FRA-1", "FRA-4"])
        XCTAssertEqual(mes.builds.map(\.card), ["FRA-4", "FRA-2", "FRA-1"])
        XCTAssertNil(mes.builds.first { $0.card == "FRA-4" }?.custoUSD)
        XCTAssertFalse(mes.builds.contains { $0.card == "FRA-3" })
        let ano = custos.periodos[.ano]!
        XCTAssertEqual(ano.total ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(ano.builds.map(\.card), ["FRA-4", "FRA-2", "FRA-1", "FRA-3"])
        XCTAssertEqual(ano.top.first?.card, "FRA-3")
        let semana = custos.periodos[.semana]!
        XCTAssertEqual(semana.builds.map(\.card), ["FRA-4", "FRA-2"])
        XCTAssertEqual(semana.top.map(\.card), ["FRA-2", "FRA-4"])
    }

    private func montar(_ entrada: EntradaPainel, _ execs: [Execucao]) -> SnapshotPainel {
        MontadorPainel.montar(entrada: entrada, execucoes: execs, agora: agora, calendario: calendarioFixo())
    }
}
