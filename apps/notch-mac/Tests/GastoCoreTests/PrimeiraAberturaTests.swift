import XCTest
@testable import GastoCore

final class PrimeiraAberturaTests: XCTestCase {
    func testSoSemConfigESemMarcador() throws {
        let t = try PastaTemp()
        XCTAssertTrue(PrimeiraAbertura.precisa(home: t.url, ambiente: [:]))
        XCTAssertFalse(PrimeiraAbertura.precisa(home: t.url, ambiente: [Configuracao.envConfig: "/x.json"]))
        try t.escrever(Legado.configLegada, "{}")
        XCTAssertFalse(PrimeiraAbertura.precisa(home: t.url, ambiente: [:]))
    }

    func testConcluirGravaConfigEMarcador() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        try m.definirValor("contas", [ContaUso(id: "claude", tipo: "claude", rotulo: "Claude").dict])
        try PrimeiraAbertura.concluir(m)
        XCTAssertFalse(PrimeiraAbertura.precisa(home: t.url, ambiente: [:]))
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.contas.map(\.id), ["claude"]); XCTAssertEqual(c.versao, 1)
    }

    func testContasPadraoSemNomesDeProduto() {
        let c = Configuracao.resolver(ambiente: [:], home: URL(fileURLWithPath: "/nao/existe"))
        // ContaUso.padrao exclui agentes optIn (gemini, copilot); Agentes.ordem inclui o catálogo inteiro.
        XCTAssertEqual(c.contas.map(\.tipo), ContaUso.padrao.map(\.tipo))
        XCTAssertFalse(c.contas.contains { Agentes.def($0.tipo)?.optIn == true })
        XCTAssertNil(ContaUso(dict: ["id": "x", "tipo": "desconhecido"]))
    }

}
