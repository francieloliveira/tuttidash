import XCTest
@testable import GastoCore

/// Cliente falso: nenhuma chamada de rede nos testes.
final class ClienteFalso: ClienteLinear, @unchecked Sendable {
    var respostas: [String: Any] = [:]
    var erro: Error?
    var consultas: [String] = []
    func consultar(_ query: String, token: String) async throws -> [String: Any] {
        consultas.append(query)
        if let erro { throw erro }
        if token == "ruim" { return try ServicoLinear.interpretar(status: 401, corpo: nil) }
        return respostas
    }
}

final class LinearTests: XCTestCase {
    func testConectarDevolveWorkspaceETimes() async throws {
        let f = ClienteFalso()
        f.respostas = ["organization": ["urlKey": "acme"],
                       "teams": ["nodes": [["id": "t2", "name": "Zeta"], ["id": "t1", "name": "Alfa"]]]]
        let (w, times) = try await ServicoLinear(cliente: f).conectar(token: "ok")
        XCTAssertEqual(w, "https://linear.app/acme")
        XCTAssertEqual(times.map(\.nome), ["Alfa", "Zeta"])
        XCTAssertFalse(f.consultas.joined().contains("mutation"))
    }

    func testOpcoesDoTime() async throws {
        let f = ClienteFalso()
        f.respostas = ["team": ["projects": ["nodes": [["id": "p", "name": "App"]]],
                                "states": ["nodes": [["id": "s1", "name": "In Progress"]]],
                                "labels": ["nodes": [["id": "l1", "name": "needs:dono"]]]]]
        let o = try await ServicoLinear(cliente: f).opcoes(time: "t1", token: "ok")
        XCTAssertEqual(o.projetos.first?.id, "p"); XCTAssertEqual(o.estados.first?.nome, "In Progress")
        XCTAssertEqual(o.rotulos.first?.nome, "needs:dono")
    }

    func testTokenInvalidoEVazio() async {
        let s = ServicoLinear(cliente: ClienteFalso())
        do { _ = try await s.conectar(token: "ruim"); XCTFail() } catch { XCTAssertEqual(error as? ErroLinear, .tokenInvalido) }
        do { _ = try await s.conectar(token: "  "); XCTFail() } catch { XCTAssertEqual(error as? ErroLinear, .semToken) }
        XCTAssertNotNil(ErroLinear.tokenInvalido.errorDescription)
    }

    func testInterpretarErros() {
        let auth: [String: Any] = ["errors": [["message": "x", "extensions": ["code": "AUTHENTICATION_ERROR"]]]]
        XCTAssertThrowsError(try ServicoLinear.interpretar(status: 200, corpo: auth)) { XCTAssertEqual($0 as? ErroLinear, .tokenInvalido) }
        XCTAssertThrowsError(try ServicoLinear.interpretar(status: 200, corpo: ["errors": [["message": "boom"]]])) {
            XCTAssertEqual($0 as? ErroLinear, .resposta("boom"))
        }
        XCTAssertThrowsError(try ServicoLinear.interpretar(status: 500, corpo: nil))
        XCTAssertEqual(try ServicoLinear.interpretar(status: 200, corpo: ["data": ["a": 1]])["a"] as? Int, 1)
    }

    func testRespostaSemOrganizacaoNaoQuebra() async {
        let f = ClienteFalso(); f.respostas = ["teams": ["nodes": []]]
        do { _ = try await ServicoLinear(cliente: f).conectar(token: "ok"); XCTFail() }
        catch { XCTAssertEqual(error as? ErroLinear, .resposta("organization.urlKey")) }
    }

    func testTokenNoKeychainComFallback() throws {
        let sufixo = UUID().uuidString
        let antigo = Cofre(servico: "com.transcentia.testes.antigo-\(sufixo)")
        let tk = TokenLinear(cofre: Cofre(servico: "com.transcentia.testes.novo-\(sufixo)"), servicoAntigo: antigo.servico)
        defer { tk.apagar(); antigo.apagar(conta: "alguem") }
        XCTAssertNil(tk.ler()); XCTAssertNil(tk.lerAntigo())
        try antigo.salvar("velho", conta: "alguem")
        XCTAssertEqual(tk.lerAntigo(), "velho")
        try tk.salvar(" novo \n"); XCTAssertEqual(tk.ler(), "novo")
    }

    func testEscolhasVaoParaConfigEVoltam() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        try m.definirValor("linear.owner_label", "needs:dono")
        try m.definirValor("linear.workspace_url", "https://linear.app/acme")
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.rotuloDono, "needs:dono"); XCTAssertEqual(c.workspaceLinear, "https://linear.app/acme")
        XCTAssertNil(Configuracao.resolver(ambiente: [:], home: try PastaTemp().url).rotuloDono)
    }
}
