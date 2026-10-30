import XCTest
@testable import GastoCore

/// FRA-524: Ajustes na janela principal, 8 sub-seções e as opções que antes só viviam no arquivo.
final class SecoesAjustesTests: XCTestCase {
    private func cfg(_ k: String, home: URL) throws -> String {
        let p = Process()
        p.executableURL = Fixtures.raizRepo.appendingPathComponent("tools/cfg")
        p.arguments = ["get", k]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FRA-531: 6 seções para quem usa o app, o técnico em «Avançado».
    func testSeisSecoesEmPortugues() {
        XCTAssertEqual(CatalogoAjustes.secoes().map(\.nome), ["Geral", "Lanes", "Contas", "Revisão", "Automação", "Avançado"])
        XCTAssertEqual(CatalogoAjustes.secoes().map(\.id), IdSecaoAjustes.allCases)
    }

    /// Toda opção da janela antiga continua alcançável, exceto as aposentadas (saíram de propósito).
    /// Nenhuma chave aparece duas vezes.
    func testTodaOpcaoAntigaTemLugarNovo() {
        let novas = CatalogoAjustes.secoes().flatMap(\.campos).map(\.chave)
        XCTAssertEqual(Set(novas).count, novas.count, "chave repetida entre seções")
        let alcancaveis = CatalogoAjustes.chavesAlcancaveis()
        let aposentadas = CatalogoAjustes.chavesAposentadas
        for k in aposentadas {
            XCTAssertFalse(alcancaveis.contains(k), "\(k) aposentada ainda aparece nos Ajustes")
            XCTAssertFalse(novas.contains(k), "\(k) aposentada ainda está numa seção")
        }
        for k in CatalogoAjustes.abas().flatMap(\.campos).map(\.chave) where !aposentadas.contains(k) {
            XCTAssertTrue(alcancaveis.contains(k), "\(k) sumiu dos Ajustes")
        }
        for k in CatalogoAjustes.camposNovos().map(\.chave) { XCTAssertTrue(alcancaveis.contains(k), "\(k) sem seção") }
        XCTAssertTrue(alcancaveis.contains(ModoForcado.chave), "quem cuida das lanes sumiu")
    }

    /// FRA-534: «Tela» saiu. A pílula é item da barra de menus e acompanha o menu.
    func testGeralTelaAposentada() {
        XCTAssertEqual(CatalogoAjustes.chavesAposentadas, ["geral.tela"])
        let geral = CatalogoAjustes.secoes().first { $0.id == .geral }!
        XCTAssertFalse(geral.campos.contains { $0.chave == "geral.tela" })
        XCTAssertTrue(geral.campos.contains { $0.chave == "geral.abrir_no_login" })
        XCTAssertFalse(CatalogoAjustes.abas().flatMap(\.campos).contains { $0.chave == "geral.tela" })
        // Continua no cfg (compatibilidade); o app não a lê para posicionar a pílula.
        XCTAssertEqual(CatalogoAjustes.buscar("Tela").filter { $0.campo.chave == "geral.tela" }.count, 0)
    }

    /// Os blocos próprios (lanes ligadas, modelos, projetos, contas, Linear, agentes, manifestos...) continuam lá.
    func testTodoBlocoTemLugar() {
        let blocos = CatalogoAjustes.secoes().flatMap(\.blocos)
        for b: BlocoAjustes in [.lanesHabilitadas, .modeloLanes, .projetos, .contas, .quemCuida, .agentesSegundoPlano,
                                .jobsAgendados, .linear, .linearLeitura, .manifestos, .ferramentas] {
            XCTAssertEqual(blocos.filter { $0 == b }.count, 1, "\(b)")
        }
    }

    /// O técnico fica em «Avançado»: tempos, intervalos, caminhos, SKIP_PREFLIGHT e manifestos.
    func testTecnicoSoEmAvancado() {
        let secoes = CatalogoAjustes.secoes()
        let avancado = secoes.first { $0.id == .avancado }!
        XCTAssertTrue(avancado.mostraChaves)
        XCTAssertTrue(avancado.grupos.allSatisfy(\.recolhido))
        for s in secoes where s.id != .avancado {
            XCTAssertFalse(s.mostraChaves)
            XCTAssertLessThanOrEqual(s.grupos.count, 4, "\(s.nome) começa com coisa demais")
            for c in s.campos {
                XCTAssertFalse(c.chave.hasSuffix("_s"), "\(c.chave) é intervalo e está em \(s.nome)")
                for t in ["timeout", "intervalo", "SKIP_PREFLIGHT", "preflight.", "painel.", "_dir", "keychain", "_cred", "_auth", "_db"] {
                    XCTAssertFalse(c.chave.contains(t) && c.chave != "uso_contas", "\(c.chave) é técnico e está em \(s.nome)")
                }
            }
        }
        XCTAssertTrue(avancado.blocos.contains(.manifestos))
        XCTAssertTrue(avancado.campos.contains { $0.chave == "agendas.env.dispatcher.SKIP_PREFLIGHT" })
    }

    func testSecaoAntigaApontaParaUmaNova() {
        for antiga in ["lanes", "contas", "revisao", "agentes", "agendas", "maquinas", "integracoes", "painel"] {
            XCTAssertNotNil(CatalogoAjustes.secaoNovaDaAntiga[antiga], antiga)
        }
        XCTAssertEqual(CatalogoAjustes.secaoNovaDaAntiga["agentes"], .automacao)
    }

    func testBuscaIgnoraAcentoEMaiuscula() {
        XCTAssertTrue(CatalogoAjustes.buscar("TETO").contains { $0.campo.chave == "teto_semanal_usd" })
        XCTAssertTrue(CatalogoAjustes.buscar("raciocinio").contains { $0.campo.chave == "lane_view.pensamento" })
        XCTAssertTrue(CatalogoAjustes.buscar("skip_preflight").contains { $0.secao == .avancado })
        XCTAssertTrue(CatalogoAjustes.buscar("   ").isEmpty)
        XCTAssertTrue(CatalogoAjustes.buscar("zzzz-nada").isEmpty)
    }

    func testNuncaExpoeEnabledNemPause() {
        for c in CatalogoAjustes.secoes().flatMap(\.campos) {
            XCTAssertFalse(c.chave.lowercased().contains("enabled"), c.chave)
            XCTAssertFalse(c.chave.uppercased().contains("PAUSE"), c.chave)
        }
    }

    func testPadroesDasOpcoesNovas() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        for c in CatalogoAjustes.camposNovos() { XCTAssertEqual(m.texto(c), c.padrao, c.chave) }
    }

    /// Grava cada opção nova e o `cfg` (o mesmo leitor do dispatcher e do vigia) devolve o valor.
    func testGravaCadaOpcaoNovaEOCfgLe() throws {
        let t = try PastaTemp()
        try t.escrever("Library/Application Support/TuttiDash/config.json", #"{"version":1,"chave_desconhecida":{"x":1}}"#)
        let m = ModeloAjustes(home: t.url)
        var esperado: [String: String] = [:]
        for c in CatalogoAjustes.camposNovos() {
            let v: String
            switch c.tipo {
            case let .numero(mn, _, inteiro): v = inteiro ? String(Int(mn) + 1) : "1.5"
            case let .escolha(ops): v = ops.last!
            case .caminho: v = "/tmp/fra524-saida.tsv"
            default: v = "FRA-999"
            }
            try m.definir(c, v)
            esperado[c.chave] = v
        }
        let relido = ModeloAjustes(home: t.url)
        for c in CatalogoAjustes.camposNovos() {
            XCTAssertEqual(relido.texto(c), esperado[c.chave], c.chave)
            XCTAssertEqual(try cfg(c.chave, home: t.url), esperado[c.chave], "cfg \(c.chave)")
        }
        XCTAssertEqual(try cfg("chave_desconhecida.x", home: t.url), "1", "chave desconhecida apagada")
    }

    func testFaixasDasOpcoesNovas() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        for c in CatalogoAjustes.camposNovos() {
            switch c.tipo {
            case let .numero(mn, mx, _):
                XCTAssertNotNil(m.validar(c, Formatar.n(mn - 1)), "\(c.chave) aceitou abaixo do mínimo")
                XCTAssertNotNil(m.validar(c, Formatar.n(mx + 1)), "\(c.chave) aceitou acima do máximo")
                XCTAssertNil(m.validar(c, c.padrao), "\(c.chave) recusou o padrão")
                XCTAssertNotNil(c.faixa)
            case .escolha:
                XCTAssertNotNil(m.validar(c, "inventado"), c.chave)
                XCTAssertNil(m.validar(c, c.padrao), c.chave)
            default:
                XCTAssertNil(m.validar(c, c.padrao), c.chave)
            }
        }
        XCTAssertThrowsError(try m.definir(CatalogoAjustes.campo("watch.max_tarefas_por_lane"), "50"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.arquivo.path))
    }

    func testRestaurarPadraoTiraSoAsChavesDoGrupo() throws {
        let t = try PastaTemp()
        try t.escrever("Library/Application Support/TuttiDash/config.json",
                       #"{"version":1,"watch":{"max_runs_per_tick":3,"outra":7},"lanes":{"enabled":["claude"]}}"#)
        let m = ModeloAjustes(home: t.url)
        let c = CatalogoAjustes.campo("watch.max_runs_per_tick")
        XCTAssertEqual(m.texto(c), "3")
        try m.restaurar([c])
        XCTAssertEqual(ModeloAjustes(home: t.url).texto(c), "1")
        XCTAssertEqual(try cfg("watch.outra", home: t.url), "7")
        XCTAssertEqual(try cfg("lanes.enabled", home: t.url), #"["claude"]"#, "enabled não pode ser tocado")
    }

    func testRevisaoCamposSimplificados() {
        let campos = CatalogoAjustes.camposRevisao()
        let chaves = campos.map(\.chave)
        XCTAssertTrue(chaves.contains("revisores.pr.lane"))
        XCTAssertTrue(chaves.contains("revisores.pr.independente"))
        XCTAssertTrue(chaves.contains("revisores.pr.reserva"))
        XCTAssertFalse(chaves.contains { $0.hasSuffix(".modelo") })
        XCTAssertFalse(chaves.contains { $0.hasSuffix(".esforco") })
        XCTAssertFalse(chaves.contains { $0.hasSuffix(".papel") })
        // Padrão: a primeira lane com revisão (claude no catálogo do repo)
        XCTAssertEqual(campos.first { $0.chave == "revisores.pr.lane" }?.padrao, "claude")
    }
}
