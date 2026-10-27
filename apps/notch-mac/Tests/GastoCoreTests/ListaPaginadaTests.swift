import XCTest
@testable import GastoCore

/// FRA-555 / FRA-556: o corte da tabela é o mesmo de Custos, Entregas e Histórico de Testes.
final class ListaPaginadaTests: XCTestCase {
    func testCortaEncostaEUsaORotuloVazio() {
        let vazio = ListaPaginada.cortar([String](), numero: 4, vazio: "0 entregas")
        XCTAssertEqual(vazio.total, 0)
        XCTAssertEqual(vazio.pagina, 1)
        XCTAssertEqual(vazio.paginas, 1)
        XCTAssertTrue(vazio.itens.isEmpty)
        XCTAssertEqual(vazio.intervalo, "0 entregas")
        XCTAssertFalse(vazio.temAnterior)
        XCTAssertFalse(vazio.temProxima)

        let letras = ["a", "b", "c", "d", "e"]
        let p2 = ListaPaginada.cortar(letras, numero: 2, tamanho: 2, vazio: "0 entregas")
        XCTAssertEqual(p2.itens, ["c", "d"])
        XCTAssertEqual(p2.intervalo, "3 a 4 de 5")
        XCTAssertEqual(p2.paginas, 3)
        XCTAssertTrue(p2.temAnterior)
        XCTAssertTrue(p2.temProxima)

        let alem = ListaPaginada.cortar(letras, numero: 99, tamanho: 2, vazio: "0 entregas")
        XCTAssertEqual(alem.pagina, 3)
        XCTAssertEqual(alem.itens, ["e"])
        XCTAssertEqual(alem.intervalo, "5 de 5")

        let tamanhoZero = ListaPaginada.cortar(letras, numero: 1, tamanho: 0, vazio: "0 entregas")
        XCTAssertEqual(tamanhoZero.tamanho, 1)
        XCTAssertEqual(tamanhoZero.itens, ["a"])
        XCTAssertTrue(tamanhoZero.temProxima)
        XCTAssertEqual(ListaPaginada<String>.tamanhoPadrao, 25)
    }

    func testResumoSeparaHojeSemanaEQuemNaoTemData() {
        let cal = calendarioFixo()
        let agora = data("2026-10-16T18:00:00")
        let lista = [
            entrega("FRA-1", quando: "2026-10-16 09:00:00", calendario: cal),
            entrega("FRA-2", quando: "2026-10-15 23:59:00", calendario: cal),
            entrega("FRA-3", quando: "2026-10-12 08:00:00", calendario: cal),
            entrega("FRA-4", quando: "2026-10-11 18:00:00", calendario: cal),
            entrega("FRA-5", quando: nil, calendario: cal),
        ]
        let r = ResumoEntregas.contar(lista, agora: agora, calendario: cal)
        XCTAssertEqual(r.hoje, 1)
        XCTAssertEqual(r.semana, 3)
        XCTAssertEqual(r.registro, 5)
        XCTAssertEqual(ResumoEntregas.contar([], agora: agora, calendario: cal), .vazio)
    }

    func testTamanhoPadraoEOdeCustos() {
        XCTAssertEqual(ListaPaginada<String>.tamanhoPadrao, 25)
        XCTAssertEqual(ListaBuilds.tamanhoPagina, ListaPaginada<CardCaro>.tamanhoPadrao)
    }

    func testHistoricoDeOitentaCaiEmQuatroPaginasSemReordenar() {
        let itens = (0..<80).map { "FRA-\($0)" }
        let p1 = ListaPaginada.cortar(itens, numero: 1, vazio: "0 provas")
        XCTAssertEqual(p1.itens, Array(itens.prefix(25)))
        XCTAssertEqual(p1.intervalo, "1 a 25 de 80")
        XCTAssertEqual(p1.paginas, 4)
        XCTAssertFalse(p1.temAnterior)
        XCTAssertTrue(p1.temProxima)

        let p4 = ListaPaginada.cortar(itens, numero: 99, vazio: "0 provas")
        XCTAssertEqual(p4.pagina, 4)
        XCTAssertEqual(p4.itens, Array(itens.suffix(5)))
        XCTAssertEqual(p4.intervalo, "76 a 80 de 80")
        XCTAssertTrue(p4.temAnterior)
        XCTAssertFalse(p4.temProxima)
    }

    func testRepeteCardENaoDescarta() {
        let itens = ["FRA-404", "FRA-404", "FRA-401"]
        XCTAssertEqual(ListaPaginada.cortar(itens, numero: 1, vazio: "0 provas").itens, itens)
    }

    func testUmItemETamanhoInvalido() {
        let um = ListaPaginada.cortar(["FRA-1"], numero: -2, vazio: "0 provas")
        XCTAssertEqual(um.pagina, 1)
        XCTAssertEqual(um.intervalo, "1 de 1")
        XCTAssertFalse(um.temAnterior)
        XCTAssertFalse(um.temProxima)

        let tamanhoZero = ListaPaginada.cortar(["FRA-1", "FRA-2"], numero: 1, tamanho: 0, vazio: "0 provas")
        XCTAssertEqual(tamanhoZero.tamanho, 1)
        XCTAssertEqual(tamanhoZero.itens, ["FRA-1"])
        XCTAssertTrue(tamanhoZero.temProxima)
        XCTAssertEqual(tamanhoZero.intervalo, "1 de 2")
    }

    func testListaBuildsDelegaOCorte() {
        let cards = (1...3).map { n in
            CardCaro(card: "FRA-\(n)", lane: "grok", descricao: nil, custoUSD: nil, duracaoMs: 0,
                     tentativas: 1, motivo: n == 1 ? "falha" : nil, destaque: n == 1, ultimoInicio: nil)
        }
        let viaBuilds = ListaBuilds.pagina(cards, numero: 2, tamanho: 2)
        let viaLista = ListaPaginada.cortar(cards, numero: 2, tamanho: 2, vazio: "0 builds")
        XCTAssertEqual(viaBuilds.itens.map(\.card), viaLista.itens.map(\.card))
        XCTAssertEqual(viaBuilds.itens.map(\.card), ["FRA-3"])
        XCTAssertEqual(viaBuilds.pagina, viaLista.pagina)
        XCTAssertEqual(viaBuilds.paginas, viaLista.paginas)
        XCTAssertEqual(viaBuilds.tamanho, viaLista.tamanho)
        XCTAssertEqual(viaBuilds.total, viaLista.total)
        XCTAssertEqual(viaBuilds.intervalo, "3 de 3")
        XCTAssertEqual(viaBuilds.intervalo, viaLista.intervalo)
    }

    private func entrega(_ card: String, quando: String?, calendario: Calendar) -> EntregaPainel {
        EntregaPainel(card: card, titulo: nil, lane: "claude", quando: quando ?? "",
                      segundos: nil, pr: nil,
                      quandoData: quando.flatMap { Datas.lerLocal($0, calendario: calendario) })
    }
}
