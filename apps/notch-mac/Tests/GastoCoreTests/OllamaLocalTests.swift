import XCTest
@testable import GastoCore

final class OllamaLocalTests: XCTestCase {
    func testEstado() {
        XCTAssertEqual(OllamaLocal.estado(instalado: false, modelos: nil, escolhido: "x"), .naoInstalado)
        XCTAssertEqual(OllamaLocal.estado(instalado: true, modelos: nil, escolhido: "x"), .parado)
        XCTAssertEqual(OllamaLocal.estado(instalado: true, modelos: [], escolhido: ""), .semModelo)
        XCTAssertEqual(OllamaLocal.estado(instalado: true, modelos: ["gemma4:12b"], escolhido: ""), .pronto("gemma4:12b"))
        XCTAssertEqual(OllamaLocal.estado(instalado: true, modelos: ["gemma4:12b"], escolhido: "qwen2.5-coder:14b"),
                       .naoBaixado("qwen2.5-coder:14b"))
        XCTAssertEqual(OllamaLocal.estado(instalado: true, modelos: ["gemma4:latest"], escolhido: "gemma4"), .pronto("gemma4"))
        // Servidor respondendo vale mesmo sem achar o binário (instalação em outro caminho).
        XCTAssertEqual(OllamaLocal.estado(instalado: false, modelos: ["a:1"], escolhido: "a:1"), .pronto("a:1"))
    }

    func testLerModelos() {
        let corpo = #"{"models":[{"name":"gemma4:12b","size":1},{"name":"phi3:mini"},{"x":1}]}"#
        XCTAssertEqual(OllamaLocal.lerModelos(Data(corpo.utf8)), ["gemma4:12b", "phi3:mini"])
        XCTAssertNil(OllamaLocal.lerModelos(Data("nada".utf8)))
    }

    func testLerLinhaPull() {
        let p = OllamaLocal.lerLinhaPull(#"{"status":"pulling ac9b","digest":"x","total":200,"completed":50}"#)
        XCTAssertEqual(p?.fracao, 0.25)
        XCTAssertEqual(OllamaLocal.lerLinhaPull(#"{"status":"verifying sha256 digest"}"#)?.fracao, nil)
        XCTAssertEqual(OllamaLocal.lerLinhaPull(#"{"status":"success"}"#)?.fim, true)
        XCTAssertEqual(OllamaLocal.lerLinhaPull(#"{"error":"pull model manifest: file does not exist"}"#)?.erro,
                       "pull model manifest: file does not exist")
        XCTAssertNil(OllamaLocal.lerLinhaPull("lixo"))
    }

    func testInstaladoProcuraNosCaminhosConhecidos() {
        XCTAssertTrue(OllamaLocal.instalado { $0 == "/opt/homebrew/bin/ollama" })
        XCTAssertFalse(OllamaLocal.instalado { _ in false })
    }
}
