import XCTest
@testable import GastoCore

final class NorteRascunhoTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("norte-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func escrever(_ caminho: String, _ texto: String) throws {
        let url = repo.appendingPathComponent(caminho)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Leitura

    func testLeituraTrazReadmeManifestoArvoreETestes() throws {
        try escrever("README.md", "# App\nControla gastos.")
        try escrever("Package.swift", "// swift-tools-version:5.9")
        try escrever("Sources/App/main.swift", "print(1)")
        try escrever("Tests/AppTests/AppTests.swift", "")
        try escrever("node_modules/lixo/index.js", "x")
        try escrever(".git/HEAD", "ref")
        let t = NorteRascunho.lerRepositorio(repo)
        XCTAssertTrue(t.contains("### README.md\n# App\nControla gastos."))
        XCTAssertTrue(t.contains("### Package.swift"))
        XCTAssertTrue(t.contains("Sources/\n  App/"))
        XCTAssertTrue(t.contains("Tests/AppTests/: AppTests.swift"))
        XCTAssertFalse(t.contains("node_modules"))
        XCTAssertFalse(t.contains(".git"))
    }

    func testLeituraEDeterministicaERespeitaOTeto() throws {
        try escrever("README.md", String(repeating: "texto longo ", count: 5_000))
        for i in 0..<30 { try escrever("pasta\(i)/a.txt", "") }
        let a = NorteRascunho.lerRepositorio(repo, teto: 4_000)
        let b = NorteRascunho.lerRepositorio(repo, teto: 4_000)
        XCTAssertEqual(a, b)
        XCTAssertLessThanOrEqual(a.count, 4_000)
        XCTAssertTrue(a.contains("[…cortado]"))
    }

    func testLeituraNaoSegueLinkParaForaDoRepo() throws {
        let fora = FileManager.default.temporaryDirectory.appendingPathComponent("fora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fora, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fora) }
        try "SEGREDO".write(to: fora.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("README.md"),
                                                   withDestinationURL: fora.appendingPathComponent("README.md"))
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("atalho"), withDestinationURL: fora)
        let t = NorteRascunho.lerRepositorio(repo)
        XCTAssertFalse(t.contains("SEGREDO"))
        XCTAssertFalse(t.contains("atalho"))
    }

    func testManifestoEmSubpastaEntra() throws {
        try escrever("apps/app-mac/Package.swift", "// pacote do app")
        try escrever("package.json", "{}")
        XCTAssertEqual(NorteRascunho.caminhosDeManifesto(repo), ["package.json", "apps/app-mac/Package.swift"])
        XCTAssertTrue(NorteRascunho.lerRepositorio(repo).contains("### apps/app-mac/Package.swift\n// pacote do app"))
    }

    func testRepositorioVazioNaoQuebra() {
        let t = NorteRascunho.lerRepositorio(repo)
        XCTAssertTrue(t.hasPrefix("### Árvore (2 níveis)"))
    }

    // MARK: - Prompt

    func testPromptTrazMaterialRespostasEFormato() {
        let p = NorteRascunho.prompt(nome: "App", leitura: "### README.md\nx", respostas: "")
        XCTAssertTrue(p.contains("Projeto: App"))
        XCTAssertTrue(p.contains("### README.md\nx"))
        XCTAssertTrue(p.contains("(nenhuma ainda)"))
        XCTAssertTrue(p.contains("NORTE:"))
        XCTAssertTrue(p.contains("PERGUNTAS:"))
        let comResposta = NorteRascunho.prompt(nome: "App", leitura: "", respostas: "Privacidade vence velocidade.")
        XCTAssertTrue(comResposta.contains("Privacidade vence velocidade."))
        XCTAssertTrue(NorteRascunho.sistema.contains("Não invente"))
        XCTAssertTrue(NorteRascunho.sistema.contains(NorteRascunho.aDefinir))
    }

    func testChamadaDoNorteNaoRetomaNaoAbreFerramentaEPensaMais() throws {
        let c = try XCTUnwrap(BrainstormCLI.chamada(cli: "claude", prompt: "p", sessao: "abc-123",
                                                    saidaCodex: nil, papel: .norte))
        XCTAssertFalse(c.retomando)
        XCTAssertFalse(c.argumentos.contains("--resume"))
        XCTAssertEqual(c.argumentos[c.argumentos.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(c.argumentos[c.argumentos.firstIndex(of: "--max-turns")! + 1], "1")
        XCTAssertEqual(c.argumentos[c.argumentos.firstIndex(of: "--effort")! + 1], "medium")
        let sistema = c.argumentos[c.argumentos.firstIndex(of: "--append-system-prompt")! + 1]
        XCTAssertEqual(sistema, NorteRascunho.sistema)
        // O chat continua como era.
        let chat = try XCTUnwrap(BrainstormCLI.chamada(cli: "claude", prompt: "p", sessao: nil, saidaCodex: nil))
        XCTAssertEqual(chat.argumentos[chat.argumentos.firstIndex(of: "--effort")! + 1], "low")
    }

    // MARK: - Resposta

    func testLeRespostaCompleta() throws {
        let bruto = """
        NORTE:
        ## 1. Objetivo
        Painel para quem roda agentes em lanes.
        ## 2. Restrições inegociáveis
        - R1: nada pessoal no repositório público.
        ## 3. Desempate
        1. Segurança vence velocidade.
        ## 4. O que nunca se faz
        - Merge sem prova verde.
        ## 5. Glossário
        - lane: fila de um agente.
        PERGUNTAS:
        - Quem é o público?
        - Quem é o público?
        """
        let r = try XCTUnwrap(NorteRascunho.ler(bruto))
        XCTAssertEqual(r.corpos[0], "Painel para quem roda agentes em lanes.")
        XCTAssertEqual(r.corpos[1], "- R1: nada pessoal no repositório público.")
        XCTAssertEqual(r.corpos[4], "- lane: fila de um agente.")
        XCTAssertEqual(r.perguntas, ["Quem é o público?"])
        XCTAssertEqual(r.pendentes, [])
    }

    func testSecaoFaltandoViraADefinirETitulosPorNome() throws {
        let bruto = """
        ```markdown
        ## Objetivo
        Um app.
        ## Restrições
        (a definir pelo dono)
        ```
        """
        let r = try XCTUnwrap(NorteRascunho.ler(bruto))
        XCTAssertEqual(r.corpos[0], "Um app.")
        XCTAssertEqual(r.pendentes, ["Restrições inegociáveis", "Desempate", "O que nunca se faz", "Glossário"])
    }

    func testMarcadorEmNegritoOuComoCabecalho() throws {
        for marcador in ["**PERGUNTAS:**", "## Perguntas", "PERGUNTAS", "### Perguntas ao dono"] {
            let r = try XCTUnwrap(NorteRascunho.ler("**NORTE:**\n## 5. Glossário\n- lane: fila\n\(marcador)\n- Quem usa?"))
            XCTAssertEqual(r.perguntas, ["Quem usa?"], marcador)
            XCTAssertEqual(r.corpos[4], "- lane: fila", marcador)
        }
    }

    func testLinhaRepetidaEmLacoEntraUmaVez() throws {
        let laco = Array(repeating: "- **Git Hooks**: comandos.", count: 12).joined(separator: "\n")
        let r = try XCTUnwrap(NorteRascunho.ler("## 5. Glossário\n- lane: fila\n" + laco))
        XCTAssertEqual(r.corpos[4], "- lane: fila\n- **Git Hooks**: comandos.")
    }

    func testRespostaSemSecaoNenhumaENil() {
        XCTAssertNil(NorteRascunho.ler("Não consegui ler o repositório."))
        XCTAssertNil(NorteRascunho.ler(""))
    }

    func testPerguntasNoMaximoCinco() throws {
        let itens = (1...8).map { "- p\($0)" }.joined(separator: "\n")
        let r = try XCTUnwrap(NorteRascunho.ler("## 1. Objetivo\nx\nPERGUNTAS:\n" + itens))
        XCTAssertEqual(r.perguntas, ["p1", "p2", "p3", "p4", "p5"])
    }

    func testMarkdownDoCaminho() throws {
        let r = try XCTUnwrap(NorteRascunho.ler("## 1. Objetivo\nUm app."))
        let md = r.markdown(nome: "App")
        XCTAssertTrue(md.hasPrefix("# Norte — App\n"))
        XCTAssertTrue(md.contains("Só o dono altera este arquivo."))
        XCTAssertTrue(md.contains("## §1 Objetivo\n\nUm app."))
        XCTAssertTrue(md.contains("## §5 Glossário\n\n\(NorteRascunho.aDefinir)"))
        XCTAssertTrue(md.hasSuffix("\n"))
        XCTAssertEqual(NorteRascunho.caminhoPadrao, "docs/produto/caminho.md")
    }
}
