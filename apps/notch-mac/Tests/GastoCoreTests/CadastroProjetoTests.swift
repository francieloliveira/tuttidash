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
