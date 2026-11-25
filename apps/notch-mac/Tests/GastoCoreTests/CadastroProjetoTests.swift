import XCTest
@testable import GastoCore

final class CadastroProjetoTests: XCTestCase {
    let a = "aaaaaaaa-0000-4000-8000-000000000001", b = "aaaaaaaa-0000-4000-8000-000000000002"

    func testProjetoNovoSoNasceLigadoQuandoNenhumEstaLigado() {
        XCTAssertTrue(ProjetosConfig.novo(existentes: []).ativo)
        XCTAssertTrue(ProjetosConfig.novo(existentes: [ProjetoCadastro(projetoID: a, ativo: false, repo: "~/a")]).ativo)
        XCTAssertFalse(ProjetosConfig.novo(existentes: [ProjetoCadastro(projetoID: a, repo: "~/a")]).ativo)
        let n = ProjetosConfig.novo(existentes: [])
        XCTAssertEqual(n.projetoID, ""); XCTAssertEqual(n.nome, "")
        XCTAssertEqual(n.problema(), "Escolha o projeto do Linear.")
    }

    func testPrincipalSoComMaisDeUmLigado() {
        let um = [ProjetoCadastro(projetoID: a, repo: "~/a"), ProjetoCadastro(projetoID: b, ativo: false, repo: "~/b")]
        XCTAssertFalse(ProjetosConfig.mostrarPrincipal(um))
        let dois = [ProjetoCadastro(projetoID: a, repo: "~/a"), ProjetoCadastro(projetoID: b, padrao: true, repo: "~/b")]
        XCTAssertTrue(ProjetosConfig.mostrarPrincipal(dois))
        XCTAssertEqual(ProjetosConfig.padrao(dois)?.projetoID, b)
    }

    /// O contexto de uma tela (Brainstorm) é o projeto escolhido nela, mesmo parado;
    /// sem escolha válida, o principal. A escolha não move o que o dispatcher trabalha.
    func testContextoDaTelaSegueAEscolhaSemTrocarOPrincipal() {
        let lista = [ProjetoCadastro(projetoID: a, repo: "~/a"),
                     ProjetoCadastro(projetoID: b, padrao: true, repo: "~/b"),
                     ProjetoCadastro(projetoID: "aaaaaaaa-0000-4000-8000-000000000003",
                                     ativo: false, repo: "~/c")]
        let parado = "aaaaaaaa-0000-4000-8000-000000000003"
        XCTAssertEqual(ProjetosConfig.contexto(lista, escolhido: "")?.projetoID, b)
        XCTAssertEqual(ProjetosConfig.contexto(lista, escolhido: a)?.projetoID, a)
        // Parado continua valendo: o Brainstorm discute a ideia antes de o projeto voltar à fila.
        XCTAssertEqual(ProjetosConfig.contexto(lista, escolhido: parado)?.projetoID, parado)
        // Id que saiu do cadastro (ou espaço) cai no principal, em vez de ficar sem contexto.
        XCTAssertEqual(ProjetosConfig.contexto(lista, escolhido: "sumiu")?.projetoID, b)
        XCTAssertEqual(ProjetosConfig.contexto(lista, escolhido: "  ")?.projetoID, b)
        XCTAssertNil(ProjetosConfig.contexto([], escolhido: a))
        XCTAssertEqual(ProjetosConfig.padrao(lista)?.projetoID, b)
    }

    /// FRA-711: o slug é o que a etiqueta `repo:<slug>` carrega no card. Tem de bater com
    /// o `_repositorios` do `projetos.py`: sem slug vira `repo<N>`, repetido fica o primeiro.
    func testRepositoriosEspelhamOsSlugsDoDispatcher() {
        let lidos = RepositorioCadastro.ler([
            ["repo": "/a/app"],
            ["repo": "/b/web", "slug": "web"],
            ["repo": "/c/app", "slug": "web"],
            ["repo": "", "slug": "vazio"],
            ["repo": "/d/api", "slug": "  api  principal "],
        ])
        XCTAssertEqual(lidos.map(\.slug), ["repo1", "web", "api principal"], "slug repetido e item sem pasta saem")
        XCTAssertEqual(lidos.map(\.repo), ["/a/app", "/b/web", "/d/api"])
        XCTAssertEqual(lidos[1].nomeDaEtiqueta, "repo:web")

        let projeto = ProjetoCadastro(projetoID: a, repo: "/a/app", repos: lidos)
        XCTAssertEqual(projeto.repositorio("web")?.repo, "/b/web")
        XCTAssertEqual(projeto.repoEfetivo("web"), "/b/web")
        XCTAssertEqual(projeto.repoEfetivo(""), "/a/app", "sem escolha: o principal")
        XCTAssertEqual(projeto.repoEfetivo("nao-existe"), "/a/app")
        XCTAssertNil(projeto.repositorio("api principal"), "slug com espaço não vira etiqueta")
        XCTAssertEqual(RepositorioCadastro.ler(nil), [])
    }

    func testSlugPrecisaServirDeEtiqueta() {
        XCTAssertTrue(RepositorioCadastro.slugValido("web-2_x"))
        XCTAssertFalse(RepositorioCadastro.slugValido(""))
        XCTAssertFalse(RepositorioCadastro.slugValido("com espaco"))
        XCTAssertFalse(RepositorioCadastro.slugValido("com:dois"))
        XCTAssertEqual(RepositorioCadastro.slugNormalizado("  a   b  "), "a b")
        XCTAssertEqual(RepositorioCadastro.slugNormalizado(String(repeating: "x", count: 80)).count, 60)
    }

    /// O contexto do Brainstorm é projeto + repositório escolhido, e o repositório de
    /// outro projeto não vale: o card iria para a pasta errada.
    func testContextoDoBrainstormJuntaProjetoERepositorio() {
        let projeto = ProjetoCadastro(projetoID: a, nome: "App", repo: "/a/app",
                                      norte: "docs/produto/caminho.md",
                                      repos: [RepositorioCadastro(slug: "app", repo: "/a/app"),
                                              RepositorioCadastro(slug: "web", repo: "/a/web")])
        let outro = ProjetoCadastro(projetoID: b, repo: "/b/x",
                                    repos: [RepositorioCadastro(slug: "api", repo: "/b/api")])

        let semEscolha = ContextoBrainstorm(projeto: projeto)
        XCTAssertEqual(semEscolha.repo, "/a/app")
        XCTAssertEqual(semEscolha.slug, "")
        XCTAssertEqual(semEscolha.etiquetaDeRepo, "", "sem escolha o card sai sem etiqueta")
        XCTAssertEqual(semEscolha.norte, "docs/produto/caminho.md")
        XCTAssertTrue(semEscolha.temEscolhaDeRepositorio)

        let comEscolha = ContextoBrainstorm(projeto: projeto, repositorio: projeto.repos[1])
        XCTAssertEqual(comEscolha.repo, "/a/web")
        XCTAssertEqual(comEscolha.slug, "web")
        XCTAssertEqual(comEscolha.etiquetaDeRepo, "repo:web")

        let alheio = ContextoBrainstorm(projeto: projeto, repositorio: outro.repos[0])
        XCTAssertNil(alheio.repositorio, "repositório de outro projeto fica de fora")
        XCTAssertEqual(alheio.repo, "/a/app")

        let umSo = ContextoBrainstorm(projeto: ProjetoCadastro(projetoID: a, repo: "/a/app",
                                                               repos: [RepositorioCadastro(slug: "app", repo: "/a/app")]))
        XCTAssertFalse(umSo.temEscolhaDeRepositorio, "com um repositório só não há o que escolher")
        XCTAssertEqual(ContextoBrainstorm(projeto: nil).repo, "")
    }

    func testMotivosEmLinguagemSimples() {
        XCTAssertEqual(ProjetoCadastro(projetoID: a, repo: "").problema(), "Escolha a pasta do projeto neste Mac.")
        XCTAssertEqual(ProjetoCadastro(projetoID: a, repo: "~/a", prova: "swift test").problema(),
                       "A prova precisa ter {suite} no lugar do teste.")
        XCTAssertNil(ProjetoCadastro(projetoID: a, repo: "~/a", prova: "swift test --filter {suite}").problema())
    }

    func testSugestaoDaProvaPelosArquivos() {
        let pasta = URL(fileURLWithPath: "/p")
        func s(_ raiz: [String], scripts: [String] = []) -> [String] {
            SugestaoProva.para(pasta: pasta, listar: { $0.lastPathComponent == "scripts" ? scripts : raiz }).map(\.comando)
        }
        XCTAssertEqual(s(["Package.swift", "Sources"]), ["swift test --filter {suite}"])
        XCTAssertEqual(s(["App.xcodeproj"]), ["xcodebuild test -project App.xcodeproj -scheme App -only-testing:{suite}"])
        XCTAssertEqual(s(["App.xcodeproj", "App.xcworkspace"]).first,
                       "xcodebuild test -workspace App.xcworkspace -scheme App -only-testing:{suite}")
        XCTAssertEqual(s(["package.json"]), ["npm test -- {suite}"])
        XCTAssertEqual(s(["pyproject.toml"]), ["python3 -m unittest {suite}"])
        XCTAssertEqual(s(["tests", "conftest.py"]), ["python3 -m pytest {suite}"])
        XCTAssertEqual(s(["Cargo.toml", "go.mod"]), ["cargo test {suite}", "go test ./... -run {suite}"])
        XCTAssertEqual(s(["README.md"]), [])
        XCTAssertEqual(s(["App.xcodeproj"], scripts: ["safe_xcodebuild.sh", "testar.sh", "release.sh"]).first,
                       "./scripts/testar.sh {suite}", "script de teste do projeto vem primeiro")
        XCTAssertTrue(SugestaoProva.exemplos.allSatisfy { $0.comando.contains("{suite}") })
        XCTAssertTrue(s(["Package.swift", "package.json", "pyproject.toml"]).allSatisfy { $0.contains("{suite}") })
    }

    /// As sugestões passam na validação do cadastro.
    func testSugestoesSaoValidas() {
        for e in SugestaoProva.exemplos {
            XCTAssertNil(ProjetoCadastro(projetoID: a, repo: "~/a", prova: e.comando).problema(), e.comando)
        }
    }
}
