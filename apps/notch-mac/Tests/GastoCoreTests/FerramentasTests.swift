import XCTest
@testable import GastoCore

final class FerramentasTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/teste")

    func testBaseTemOEssencialESoTmuxEOpcional() {
        let b = Ferramentas.base()
        XCTAssertEqual(b.map(\.id), ["brew", "apple", "gh", "tmux"])
        XCTAssertEqual(b.filter(\.opcional).map(\.id), ["tmux"])
        XCTAssertEqual(b.first { $0.id == "gh" }?.entrar, "gh auth login")
        XCTAssertTrue(b.first { $0.id == "gh" }!.precisaBrew)
        XCTAssertFalse(b.first { $0.id == "brew" }!.precisaBrew)
    }

    func testAcharProcuraNasPastasDosInstaladores() {
        let grok = "/Users/teste/.local/bin/grok"
        XCTAssertEqual(Ferramentas.achar("grok", home: home, existe: { $0 == grok }), grok)
        XCTAssertEqual(Ferramentas.achar("gh", home: home, existe: { $0 == "/usr/local/bin/gh" }), "/usr/local/bin/gh")
        XCTAssertNil(Ferramentas.achar("gh", home: home, existe: { _ in false }))
        XCTAssertTrue(Ferramentas.path(home: home).hasPrefix("/Users/teste/.local/bin:/opt/homebrew/bin"))
    }

    /// git e python3: o atalho de /usr/bin não conta; vale o `xcode-select -p`.
    func testConferirUsaXcodeSelectEGhAuthStatus() {
        let existe: (String) -> Bool = { ["/usr/bin/git", "/opt/homebrew/bin/gh"].contains($0) }
        var chamadas: [[String]] = []
        let semApple = Ferramentas.conferir(Ferramentas.base(), home: home, existe: existe,
                                            rodar: { chamadas.append($0); return $0.contains("-p") ? 2 : 1 })
        XCTAssertNil(semApple.first { $0.id == "apple" }?.encontrada)
        XCTAssertEqual(semApple.first { $0.id == "gh" }?.conectada, false)
        XCTAssertTrue(chamadas.contains(["/opt/homebrew/bin/gh", "auth", "status"]))
        let tudo = Ferramentas.conferir(Ferramentas.base(), home: home, existe: existe, rodar: { _ in 0 })
        XCTAssertNotNil(tudo.first { $0.id == "apple" }?.encontrada)
        XCTAssertEqual(tudo.first { $0.id == "gh" }?.conectada, true)
        XCTAssertNil(tudo.first { $0.id == "brew" }?.encontrada)
        XCTAssertNil(tudo.first { $0.id == "tmux" }?.conectada, "sem conferência de login, fica nil")
    }

    func testAgentesVemDoManifestoSemRepetirExecutavel() throws {
        let t = try PastaTemp()
        func m(_ nome: String, _ ordem: Int, cli: String?, instalar: String) throws {
            try """
            {"schema": 1, "nome": "\(nome)", "rotulo": "\(nome.uppercased())", "cli": \(cli.map { "\"\($0)\"" } ?? "null"),
             "ordem": \(ordem), "uso": {"tipo": "\(nome)"}\(instalar)}
            """.write(to: t.url.appendingPathComponent("\(nome).json"), atomically: true, encoding: .utf8)
        }
        let bloco = #", "instalar": {"comando": "brew install x", "entrar": "x", "dica_entrar": "siga", "docs": "https://ex.com/docs"}"#
        try m("um", 2, cli: "x", instalar: bloco)
        try m("dois", 1, cli: "x", instalar: bloco)
        try m("tres", 3, cli: "y", instalar: "")
        try m("quatro", 4, cli: nil, instalar: bloco)
        try m("cinco", 5, cli: "z", instalar: #", "instalar": {"comando": "  "}"#)
        let ag = try CatalogoAgentes.ler(diretorio: t.url)
        let f = Ferramentas.agentes(ag)
        XCTAssertEqual(f.map(\.nome), ["DOIS"], "um só por executável; sem cli, sem comando ou comando vazio não entram")
        XCTAssertEqual(f.first?.instalar, "brew install x"); XCTAssertEqual(f.first?.entrar, "x")
        XCTAssertEqual(f.first?.dicaEntrar, "siga"); XCTAssertEqual(f.first?.docs?.absoluteString, "https://ex.com/docs")
    }

    /// Os manifestos do repositório: todo agente de lane tem como instalar, com link oficial.
    func testManifestosDoRepoTemInstalar() throws {
        let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agents.d")
        let ag = try CatalogoAgentes.ler(diretorio: raiz)
        for a in ag where a.cli != nil && a.painel {
            let i = try XCTUnwrap(a.instalar, a.nome)
            XCTAssertFalse(i.entrar.isEmpty, a.nome)
            XCTAssertTrue(i.docs.hasPrefix("https://"), a.nome)
        }
    }

    func testRoteiroMostraOComandoEEsperaOEnter() {
        let cmd = #"curl -fsSL https://x/i.sh | bash; echo 'aspas'"#
        let r = Ferramentas.roteiro(titulo: "Instalar X", comando: cmd, dica: "Entre pelo navegador",
                                    docs: URL(string: "https://x/docs"), home: home, oficiais: [])
        let linhas = r.split(separator: "\n").map(String.init)
        XCTAssertEqual(linhas.first, "#!/bin/bash")
        let iRead = try! XCTUnwrap(linhas.firstIndex { $0.hasPrefix("read -r -p") })
        XCTAssertFalse(linhas.suffix(from: iRead).contains(cmd), "injeção não vira linha de shell")
        XCTAssertTrue(linhas.suffix(from: iRead).contains("exit 1"))
        XCTAssertTrue(r.contains(#"printf '\n    %s\n\n' 'curl -fsSL https://x/i.sh | bash; echo '\''aspas'\'''"#))
        XCTAssertTrue(r.contains("https://x/docs")); XCTAssertTrue(r.contains("Entre pelo navegador"))
        XCTAssertTrue(r.contains("/Users/teste/.local/bin"))
    }

    /// Argv citado. O instalador do Homebrew continua shell. Pipeline só se estiver na lista oficial.
    func testRoteiroCitaArgvEVetaShell() throws {
        let brew = Ferramentas.roteiro(titulo: "Brew", comando: "brew install gh", home: home, oficiais: [])
        let linhasBrew = brew.split(separator: "\n").map(String.init)
        let iRead = try XCTUnwrap(linhasBrew.firstIndex { $0.hasPrefix("read -r -p") })
        XCTAssertTrue(linhasBrew.suffix(from: iRead).contains("'brew' 'install' 'gh'"))
        let homebrew = Ferramentas.instaladorHomebrew
        let cru = Ferramentas.roteiro(titulo: "HB", comando: homebrew, home: home, oficiais: [])
        XCTAssertTrue(cru.split(separator: "\n").map(String.init).contains(homebrew))
        let curl = "curl -fsSL https://claude.ai/install.sh | bash"
        let oficial = Ferramentas.roteiro(titulo: "C", comando: curl, home: home, oficiais: [curl])
        XCTAssertTrue(oficial.split(separator: "\n").map(String.init).contains(curl))
        let falso = Ferramentas.roteiro(titulo: "C", comando: curl + "; touch /tmp/pwn", home: home, oficiais: [curl + "; touch /tmp/pwn"])
        XCTAssertTrue(falso.contains("exit 1"))
        XCTAssertFalse(falso.split(separator: "\n").map(String.init).contains(curl + "; touch /tmp/pwn"))
        let aberto = Ferramentas.roteiro(titulo: "D", comando: "open -a 'DeepSeek Harness'", home: home, oficiais: [])
        XCTAssertTrue(aberto.contains("'open' '-a' 'DeepSeek Harness'"))
    }

    /// O roteiro é bash válido (`bash -n`).
    func testRoteiroEBashValido() throws {
        let t = try PastaTemp()
        let arq = t.url.appendingPathComponent("r.command")
        try Ferramentas.roteiro(titulo: "T'x", comando: Ferramentas.instaladorHomebrew,
                                dica: "a 'b'", docs: nil, home: home).write(to: arq, atomically: true, encoding: .utf8)
        XCTAssertEqual(Ferramentas.codigo(["/bin/bash", "-n", arq.path]), 0)
        try Ferramentas.roteiro(titulo: "X", comando: "x; touch /tmp/pwn", home: home, oficiais: [])
            .write(to: arq, atomically: true, encoding: .utf8)
        XCTAssertEqual(Ferramentas.codigo(["/bin/bash", "-n", arq.path]), 0)
    }

    func testLoginPorArgvNaoAceitaCliNemContaInjetados() throws {
        XCTAssertNil(LoginConta.argv(tipo: "grok", cli: "x; touch /tmp/pwn", home: home, existe: { _ in true }))
        XCTAssertNil(LoginConta.argv(tipo: "grok", cli: "grok", home: home, existe: { _ in false }))
        let bin = "/Users/teste/.local/bin/opencode"
        XCTAssertEqual(LoginConta.argv(tipo: "opencode", cli: "opencode", home: home, existe: { $0 == bin }),
                       [bin, "auth", "login"])
        XCTAssertEqual(LoginConta.argv(tipo: "grok", cli: "grok", home: home, existe: { $0 == "/Users/teste/.local/bin/grok" }),
                       ["/Users/teste/.local/bin/grok"])
        XCTAssertEqual(LoginConta.sanitizarConta("../../x"), "x")
        let pasta = try PastaTemp()
        let a = try LoginConta.gravar(argv: [bin, "auth", "login"], conta: "../../x", em: pasta.url)
        let b = try LoginConta.gravar(argv: [bin, "auth", "login"], conta: "../../x", em: pasta.url)
        XCTAssertNotEqual(a.lastPathComponent, b.lastPathComponent)
        XCTAssertEqual(a.deletingLastPathComponent().standardizedFileURL.path, pasta.url.standardizedFileURL.path)
        XCTAssertTrue(a.lastPathComponent.hasPrefix("tuttidash-login-x-"))
        XCTAssertTrue(a.lastPathComponent.hasSuffix(".command"))
        XCTAssertFalse(a.lastPathComponent.contains(".."))
        XCTAssertFalse(a.lastPathComponent.contains("/"))
        let modo = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(modo?.uint16Value, 0o700)
        let texto = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(texto.hasPrefix("#!/bin/bash\n"))
        XCTAssertEqual(texto, "#!/bin/bash\nexec '\(bin)' 'auth' 'login'\n")
        XCTAssertFalse(texto.contains("zsh"))
        XCTAssertFalse(texto.contains("touch"))
    }
}
