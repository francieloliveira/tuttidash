import XCTest
@testable import GastoCore

final class AjustesTests: XCTestCase {
    private func campo(_ k: String) -> CampoAjuste {
        CatalogoAjustes.abas().flatMap(\.campos).first { $0.chave == k }!
    }

    func testPadroesSemArquivo() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        XCTAssertEqual(m.texto(campo("preflight.max_load")), "16")
        XCTAssertEqual(m.texto(campo("lanes.proof_default_suites")), "")
        XCTAssertEqual(m.texto(campo("lane_view.pensamento")), "true")
        XCTAssertEqual(m.texto(campo("lane_view.diff_linhas")), "14")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.arquivo.path))
    }

    func testCredenciaisUmaLinhaPorAgente() {
        let chaves = CatalogoAjustes.abas().flatMap(\.campos).map(\.chave)
        for k in ["opencode_db", "copilot_token"] {
            XCTAssertTrue(chaves.contains(k), k)
        }
        // Sem fonte registrada de fora, nenhum campo de credencial de login (FRA-565).
        if FontesUso.todas.count == FontesUso.publicas.count {
            for k in ["claude_cred", "claude_keychain", "grok_auth", "cursor_db", "codex_auth", "gemini_auth", "opencode_auth"] {
                XCTAssertFalse(chaves.contains(k), k)
            }
        }
    }

    func testAbaBotsERevisao() throws {
        let chaves = CatalogoAjustes.abas().flatMap(\.campos).map(\.chave)
        for k in ["revisores.pr.agente", "revisores.pr.independente", "revisores.pr.reserva",
                  "watch.reconferir_needs_max_s", "triagem_local.ativo", "triagem_local.limiar"] {
            XCTAssertTrue(chaves.contains(k), k)
        }
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        XCTAssertEqual(m.texto(campo("revisores.pr.agente")), "claude")
        XCTAssertNotNil(m.validar(campo("revisores.pr.agente"), "cursor"), "sem `revisao` no manifesto, não revisa")
        XCTAssertNil(m.validar(campo("triagem_local.limiar"), "0.85"))
        XCTAssertNotNil(m.validar(campo("triagem_local.limiar"), "1.5"))
    }

    func testRevisoresVemDoCatalogo() {
        let sozinho = CatalogoAgentes.ModeloAgente.Revisao(papel: "sozinho", auto: true, modelos: ["a", "b"],
                                                            modeloPadrao: "a", esforcos: ["high"], esforcoPadrao: "high")
        let segunda = CatalogoAgentes.ModeloAgente.Revisao(papel: "segunda_opiniao", auto: false, modelos: [],
                                                            modeloPadrao: "padrao", esforcos: [], esforcoPadrao: "")
        let lidos = CatalogoAgentes.carregar(caminhos: [URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../../agents.d").standardizedFileURL])
        XCTAssertNotNil(lidos.first { $0.nome == "grok" }?.revisao, "o manifesto do repo traz `revisao`")
        XCTAssertNil(lidos.first { $0.nome == "cursor" }?.revisao)
        var x = lidos.first { $0.nome == "claude" }!
        x.nome = "x"; x.revisao = sozinho
        var y = x
        y.nome = "y"; y.revisao = segunda
        let campos = CatalogoAjustes.camposRevisao(agentes: [x, y])
        let chaves = campos.map(\.chave)
        XCTAssertTrue(chaves.contains("revisores.pr.x.esforco"))
        XCTAssertFalse(chaves.contains("revisores.pr.y.esforco"), "sem esforços no manifesto, sem campo")
        XCTAssertEqual(campos.first { $0.chave == "revisores.pr.y.papel" }?.padrao, "segunda_opiniao")
        XCTAssertEqual(campos.first { $0.chave == "revisores.pr.agente" }?.tipo, .escolha(["x", "y"]))
    }

    func testValidacao() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        XCTAssertNotNil(m.validar(campo("preflight.max_load"), "0"))
        XCTAssertNotNil(m.validar(campo("preflight.max_load"), "abc"))
        XCTAssertNil(m.validar(campo("preflight.max_load"), "20"))
        XCTAssertNotNil(m.validar(campo("preflight.jobs"), "2.5"))
        XCTAssertNotNil(m.validar(campo("painel.tmux"), "/nao/existe/tmux"))
        XCTAssertNil(m.validar(campo("preflight.external_nvme"), ""))
        XCTAssertNotNil(m.validar(campo("lanes.effort_default"), "enorme"))
        XCTAssertThrowsError(try m.definir(campo("aviso_pct"), "200"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.arquivo.path))
    }

    func testGravaVersaoEPreservaOutrasChaves() throws {
        let t = try PastaTemp()
        try t.escrever(".transcentia/tools/config.json", #"{"teto_semanal_usd":28}"#)
        let m = ModeloAjustes(home: t.url)
        try m.definir(campo("lanes.budget_usd.medio"), "9,5")
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.versao, 1); XCTAssertEqual(c.tetoSemanalUSD, 28)
        XCTAssertEqual(ModeloAjustes(home: t.url).texto(campo("lanes.budget_usd.medio")), "9.5")
    }

    /// Ida e volta: muda pelo modelo e o `cfg` (tools/cfg) devolve o valor.
    func testIdaEVoltaComCfg() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        try m.definir(campo("preflight.max_load"), "22")
        try m.definir(campo("preflight.skip_preflight_first"), "false")
        try m.definir(campo("lanes.proof_default_suites"), "A, B")
        func cfg(_ k: String) throws -> String {
            let p = Process()
            p.executableURL = Fixtures.raizRepo.appendingPathComponent("tools/cfg")
            p.arguments = ["get", k]
            p.environment = ["HOME": t.url.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try cfg("preflight.max_load"), "22")
        XCTAssertEqual(try cfg("preflight.skip_preflight_first"), "false")
        XCTAssertEqual(try cfg("lanes.proof_default_suites"), #"["A", "B"]"#)
        XCTAssertEqual(try cfg("version"), "1")
    }

    func testCofreKeychain() throws {
        let c = Cofre(servico: "app.tuttidash.mac.testes-\(UUID().uuidString)")
        defer { c.apagar(conta: "x") }
        XCTAssertNil(c.ler(conta: "x"))
        try c.salvar("segredo-1", conta: "x"); XCTAssertEqual(c.ler(conta: "x"), "segredo-1")
        try c.salvar("segredo-2", conta: "x"); XCTAssertEqual(c.ler(conta: "x"), "segredo-2")
        XCTAssertTrue(c.apagar(conta: "x")); XCTAssertNil(c.ler(conta: "x"))
    }
}
