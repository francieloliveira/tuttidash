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

    func testTimesDoWorkspace() async throws {
        let f = ClienteFalso()
        f.respostas = ["teams": ["nodes": [["id": "t2", "name": "Zeta"], ["id": "t1", "name": "Alfa"]]]]
        let times = try await ServicoLinear(cliente: f).times(token: "ok")
        XCTAssertEqual(times.map(\.nome), ["Alfa", "Zeta"])
        XCTAssertTrue(f.consultas.joined().contains("teams(first: 100)"))
    }

    /// Criar projeto no Linear pelo app, com o nome escapado e o time validado.
    func testCriarProjetoNoLinear() async throws {
        let f = ClienteFalso()
        f.respostas = ["projectCreate": ["success": true, "project": [
            "id": "p1", "name": "App \"novo\"\nlinha 2", "url": "https://linear.app/acme/project/app",
            "teams": ["nodes": [["id": "11111111-1111-4111-8111-111111111111", "name": "FRA"]]],
        ]]]
        let p = try await ServicoLinear(cliente: f).criarProjeto(
            nome: "  App \"novo\"\nlinha 2  ", timeID: "11111111-1111-4111-8111-111111111111", token: "ok")
        XCTAssertEqual(p.id, "p1")
        XCTAssertEqual(p.nome, "App \"novo\"\nlinha 2")
        XCTAssertEqual(p.timeNome, "FRA")
        XCTAssertEqual(p.rotulo, "App \"novo\"\nlinha 2 · FRA")
        let q = try XCTUnwrap(f.consultas.last)
        XCTAssertTrue(q.contains("projectCreate"))
        XCTAssertTrue(q.contains("teamIds: [\"11111111-1111-4111-8111-111111111111\"]"))
        // O nome vai como literal do GraphQL: aspas e quebra de linha escapadas, sem sobra de espaço.
        XCTAssertTrue(q.contains(#"name: "App \"novo\"\nlinha 2""#), q)
    }

    func testCriarProjetoRecusaTimeInvalidoSemChamarOLinear() async {
        let f = ClienteFalso()
        let s = ServicoLinear(cliente: f)
        for time in ["", "nao-e-uuid", "t1\"}"] {
            do {
                _ = try await s.criarProjeto(nome: "App", timeID: time, token: "ok")
                XCTFail("aceitou o time \(time)")
            } catch {
                XCTAssertEqual(error as? ErroLinear, .resposta("o time do projeto não foi escolhido"))
            }
        }
        do {
            _ = try await s.criarProjeto(nome: "   ", timeID: "11111111-1111-4111-8111-111111111111", token: "ok")
            XCTFail("aceitou nome vazio")
        } catch {
            XCTAssertEqual(error as? ErroLinear, .resposta("o nome do projeto está vazio"))
        }
        XCTAssertTrue(f.consultas.isEmpty, "nada pode ir ao Linear antes da validação")
    }

    func testCriarProjetoSemSucessoNaoDevolveProjeto() async {
        let f = ClienteFalso()
        f.respostas = ["projectCreate": ["success": false]]
        do {
            _ = try await ServicoLinear(cliente: f).criarProjeto(
                nome: "App", timeID: "11111111-1111-4111-8111-111111111111", token: "ok")
            XCTFail("devolveu projeto sem success")
        } catch {
            XCTAssertEqual(error as? ErroLinear, .resposta("o Linear não devolveu o projeto criado"))
        }
    }

    func testLiteralDoGraphQLEscapa() {
        XCTAssertEqual(LiteralGraphQL.texto("a\"b\\c\nd"), #""a\"b\\c\nd""#)
        XCTAssertEqual(LiteralGraphQL.texto(""), "\"\"")
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
