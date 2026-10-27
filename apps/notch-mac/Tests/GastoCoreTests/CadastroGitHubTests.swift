import XCTest
@testable import GastoCore

/// Chaveiro em memória: os testes não tocam o item real dos scripts.
final class ChaveiroFalso: ChaveiroScripts, @unchecked Sendable {
    var itens: [String: (conta: String, segredo: String)] = [:]
    var falhar = false
    func ler(servico: String) -> String? { itens[servico]?.segredo }
    func gravar(_ segredo: String, servico: String, conta: String) throws {
        if falhar { throw ErroLinear.resposta("falhou") }
        itens[servico] = (conta, segredo)
    }
    func apagar(servico: String) { itens[servico] = nil }
}

final class TokenUnicoTests: XCTestCase {
    func cofre() -> Cofre { Cofre(servico: "com.transcentia.testes.app-\(UUID().uuidString)") }

    func testSalvarGravaSoNoItemDosScripts() throws {
        let ch = ChaveiroFalso(), cf = cofre()
        let tk = TokenLinear(cofre: cf, servico: "svc-teste", chaveiro: ch)
        defer { tk.apagar() }
        try cf.salvar("velho", conta: TokenLinear.conta)
        try tk.salvar(" novo \n")
        XCTAssertEqual(ch.itens["svc-teste"]?.segredo, "novo")
        XCTAssertNil(cf.ler(conta: TokenLinear.conta), "o item antigo do app some")
        XCTAssertEqual(tk.ler(), "novo")
    }

    func testLerMigraOItemAntigo() throws {
        let ch = ChaveiroFalso(), cf = cofre()
        let tk = TokenLinear(cofre: cf, servico: "svc-teste", chaveiro: ch)
        defer { tk.apagar() }
        XCTAssertNil(tk.ler())
        try cf.salvar("antigo", conta: TokenLinear.conta)
        XCTAssertEqual(tk.ler(), "antigo")
        XCTAssertEqual(ch.itens["svc-teste"]?.segredo, "antigo")
        XCTAssertNil(cf.ler(conta: TokenLinear.conta))
    }

    func testItemAntigoIgualSaiItemAntigoDiferenteFica() throws {
        let ch = ChaveiroFalso(), cf = cofre()
        let tk = TokenLinear(cofre: cf, servico: "svc-teste", chaveiro: ch)
        defer { tk.apagar() }
        try ch.gravar("t", servico: "svc-teste", conta: "x")
        try cf.salvar("outro", conta: TokenLinear.conta)
        XCTAssertEqual(tk.ler(), "t")
        XCTAssertEqual(cf.ler(conta: TokenLinear.conta), "outro", "valor diferente: não apaga")
        try cf.salvar("t", conta: TokenLinear.conta)
        XCTAssertEqual(tk.ler(), "t")
        XCTAssertNil(cf.ler(conta: TokenLinear.conta))
    }

    func testMigracaoQueFalhaNaoPerdeOToken() throws {
        let ch = ChaveiroFalso(), cf = cofre()
        ch.falhar = true
        let tk = TokenLinear(cofre: cf, servico: "svc-teste", chaveiro: ch)
        defer { tk.apagar() }
        try cf.salvar("antigo", conta: TokenLinear.conta)
        XCTAssertEqual(tk.ler(), "antigo")
        XCTAssertEqual(cf.ler(conta: TokenLinear.conta), "antigo", "sem gravar o novo, o antigo fica")
    }

    func testApagarLimpaOsDois() throws {
        let ch = ChaveiroFalso(), cf = cofre()
        let tk = TokenLinear(cofre: cf, servico: "svc-teste", chaveiro: ch)
        try tk.salvar("x"); try cf.salvar("y", conta: TokenLinear.conta)
        tk.apagar()
        XCTAssertNil(ch.itens["svc-teste"]); XCTAssertNil(cf.ler(conta: TokenLinear.conta))
    }
}

final class RepositorioGitHubTests: XCTestCase {
    func testNormalizaLinksEDonoRepo() {
        for v in ["https://github.com/Dono/App", "https://github.com/dono/app.git", "git@github.com:dono/app.git",
                  "ssh://git@github.com/dono/app", "github.com/dono/app/", " dono/app "] {
            XCTAssertEqual(RepositorioGitHub.normalizar(v), "dono/app", v)
        }
        for v in ["", "dono", "dono/app/tree/main", "https://gitlab.com/dono/app", "dono /app"] {
            XCTAssertNil(RepositorioGitHub.normalizar(v), v)
        }
        XCTAssertEqual(RepositorioGitHub.link("dono/app")?.absoluteString, "https://github.com/dono/app")
    }

    func testOrigemLidaDoGitConfig() {
        let cfg = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = https://github.com/outro/app.git
        [remote "origin"]
        \turl = git@github.com:dono/app.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        XCTAssertEqual(RepositorioGitHub.origem(da: URL(fileURLWithPath: "/x"), ler: { _ in cfg }), "git@github.com:dono/app.git")
        XCTAssertNil(RepositorioGitHub.origem(da: URL(fileURLWithPath: "/x"), ler: { _ in nil }))
        XCTAssertNil(RepositorioGitHub.origem(da: URL(fileURLWithPath: "/x"), ler: { _ in "[core]\n" }))
    }

    func testPastaLocalAchaPeloOrigin() {
        let raiz = URL(fileURLWithPath: "/home/dev")
        let a = raiz.appendingPathComponent("a"), b = raiz.appendingPathComponent("b")
        let origens = [a.path: "https://github.com/dono/outro", b.path: "git@github.com:Dono/App.git"]
        let achou = RepositorioGitHub.pastaLocal(para: "dono/app", raizes: [raiz], listar: { _ in [b, a] },
                                                 origem: { origens[$0.path] })
        XCTAssertEqual(achou, b)
        XCTAssertNil(RepositorioGitHub.pastaLocal(para: "dono/nada", raizes: [raiz], listar: { _ in [a, b] },
                                                  origem: { origens[$0.path] }))
        XCTAssertEqual(RepositorioGitHub.destinoDoClone("dono/app", home: raiz)?.path, "/home/dev/Developer/app")
    }

    func testListaJuntaContaEOrganizacoes() {
        let rodar: ([String]) -> Data? = { args in
            switch args.prefix(3).joined(separator: " ") {
            case "repo list --limit": return Data(#"[{"nameWithOwner":"eu/b"},{"nameWithOwner":"eu/a"}]"#.utf8)
            case "org list": return Data("time\n".utf8)
            case "repo list time": return Data(#"[{"nameWithOwner":"time/c"},{"nameWithOwner":"eu/a"}]"#.utf8)
            default: return nil
            }
        }
        XCTAssertEqual(try RepositorioGitHub.listar(rodar: rodar).get(), ["eu/a", "eu/b", "time/c"])
        if case .success = RepositorioGitHub.listar(rodar: { _ in nil }) { XCTFail("sem gh não lista") }
        XCTAssertEqual(RepositorioGitHub.lerLista(Data("nada".utf8)), [])
    }

    func testProjetosDoLinearComTime() {
        let d: [String: Any] = ["projects": ["nodes": [
            ["id": "p2", "name": "Web", "url": "https://linear.app/x/project/web", "teams": ["nodes": [["id": "t1", "name": "Produto"]]]],
            ["id": "p1", "name": "App", "teams": ["nodes": []]],
            ["name": "sem id"]]]]
        let ps = ServicoLinear.projetos(d)
        XCTAssertEqual(ps.map(\.id), ["p1", "p2"])
        XCTAssertEqual(ps[1].timeID, "t1"); XCTAssertEqual(ps[1].url, "https://linear.app/x/project/web")
        XCTAssertEqual(ps[0].timeID, "")
    }

    func testCadastroGuardaOGitHub() {
        var d: [String: Any] = [:]
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: "aaaaaaaa-0000-4000-8000-000000000001", repo: "~/a", github: "https://github.com/Dono/App.git"),
                               ProjetoCadastro(projetoID: "aaaaaaaa-0000-4000-8000-000000000002", repo: "~/b")], em: &d)
        let lista = d["projetos"] as? [[String: Any]]
        XCTAssertEqual(lista?[0]["github"] as? String, "dono/app")
        XCTAssertNil(lista?[1]["github"])
        XCTAssertEqual(ProjetosConfig.ler(d).first?.github, "dono/app")
        XCTAssertNotNil(ProjetoCadastro(projetoID: "aaaaaaaa-0000-4000-8000-000000000003", repo: "~/c", github: "não é repo").problema())
    }
}
