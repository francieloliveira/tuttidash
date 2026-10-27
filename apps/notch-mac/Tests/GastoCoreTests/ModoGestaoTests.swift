import XCTest
@testable import GastoCore

final class ModoGestaoTests: XCTestCase {
    func testTextoDesconhecidoViraAuto() {
        XCTAssertEqual(ModoForcado(texto: nil), .auto)
        XCTAssertEqual(ModoForcado(texto: "xyz"), .auto)
        XCTAssertEqual(ModoForcado(texto: " Vigia "), .vigia)
        XCTAssertEqual(ModoForcado(texto: "grokbot"), .grokbot)
    }

    func testEscolherGravaConfigERodaChave() throws {
        let t = try PastaTemp()
        var rodou: [URL] = []
        let g = GestaoLanes(modelo: ModeloAjustes(home: t.url)) { rodou.append($0); return 0 }
        XCTAssertEqual(g.modo, .auto)
        try g.escolher(.vigia)
        XCTAssertEqual(rodou, [g.script])
        XCTAssertEqual(ModeloAjustes(home: t.url).valorTexto(ModoForcado.chave), "vigia")
        XCTAssertEqual(GestaoLanes(modelo: ModeloAjustes(home: t.url)).modo, .vigia)
        try g.escolher(.grokbot)
        XCTAssertEqual(g.modo, .grokbot); XCTAssertEqual(rodou.count, 2)
    }

    func testLeEstadoDoModoJSON() throws {
        let t = try PastaTemp()
        let g = GestaoLanes(modelo: ModeloAjustes(home: t.url)) { _ in 0 }
        XCTAssertNil(g.estado())
        _ = try t.escrever(".transcentia/bots/modo.json",
                       #"{"modo":"vigia","grokbot_pct":94.0,"medido_em":"2026-10-10 22:56:35-0300","motivo":"x"}"#)
        let e = try XCTUnwrap(g.estado())
        XCTAssertEqual(e.modo, "vigia"); XCTAssertEqual(e.pct, 94)
        XCTAssertEqual(e.resumo, "vigia · 94% · 22:56")
    }
}
