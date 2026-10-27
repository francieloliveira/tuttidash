import XCTest
@testable import GastoCore

private final class Caixa: @unchecked Sendable { var rodou = false }

final class SubprocessoTests: XCTestCase {
    func testSaidaEntradaECodigo() {
        XCTAssertEqual(Subprocesso.rodar("/bin/echo", ["oi"]).texto, "oi\n")
        XCTAssertEqual(Subprocesso.rodar("/bin/cat", [], entrada: "linha").texto, "linha")
        XCTAssertEqual(Subprocesso.rodar("/bin/sh", ["-c", "exit 3"]).codigo, 3)
        XCTAssertEqual(Subprocesso.rodar("/nao/existe", []).codigo, -1)
        XCTAssertEqual(Subprocesso.rodar("/usr/bin/env", [], ambiente: ["X": "1"]).texto, "X=1\n")
    }

    /// O app fechava ao abrir o menu (FRA-579): o `waitUntilExit` girava o run loop no meio de
    /// um redesenho. Esperar não pode processar nada da thread em que se espera.
    func testEsperaSemGirarORunLoop() {
        let c = Caixa()
        RunLoop.current.perform { c.rodou = true }
        _ = Subprocesso.rodar("/bin/sleep", ["0.2"])
        XCTAssertFalse(c.rodou, "o bloco agendado rodou durante a espera")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(c.rodou)
    }
}
