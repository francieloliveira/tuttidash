import XCTest
@testable import GastoCore

/// FRA-553: Dock só com o painel aberto. Fechar a janela volta à pílula e não encerra.
/// «Sair» da pílula encerra. O AppKit (JanelaPainel / PresencaApp) só aplica estes resultados.
final class PoliticaDockTests: XCTestCase {
    func testArranqueFicaSoNaPilula() {
        XCTAssertEqual(PoliticaDock.arranque, .accessory)
    }

    func testMostrarPainelPedeDock() {
        XCTAssertEqual(PoliticaDock.aoMostrarPainel(), .regular)
    }

    func testFecharPainelVoltaAPilulaSemEncerrar() {
        let efeito = PoliticaDock.aoFecharPainel()
        XCTAssertEqual(efeito.politica, .accessory)
        XCTAssertEqual(efeito.destino, .permanecer)
    }

    func testSairPelaPilulaEncerra() {
        XCTAssertEqual(PoliticaDock.aoSair(), .encerrar)
    }

    /// Abrir e fechar não é sair: a política volta, o processo fica.
    func testAbrirEFecharNaoEncerra() {
        XCTAssertEqual(PoliticaDock.aoMostrarPainel(), .regular)
        let efeito = PoliticaDock.aoFecharPainel()
        XCTAssertEqual(efeito.politica, PoliticaDock.arranque)
        XCTAssertNotEqual(efeito.destino, PoliticaDock.aoSair())
    }
}
