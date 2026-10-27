import Foundation
import XCTest
@testable import GastoCore

/// FRA-463: Copilot como conta de uso opt-in. O token só é lido. Sem cota, sem token,
/// licença de organização ou erro de API ficam «sem dado», com motivo, nunca como 0% inventado.
final class UsoCopilotTests: XCTestCase {
    private var agora: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    }

    private var resetNovembro: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    }

    private var repoAgentsD: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agents.d")
    }

    private func conta(usuario: String = "octocat", cota: Int? = 300, arquivo: String = "") -> ContaUso {
        ContaUso(id: "copilot", tipo: "copilot", rotulo: "Copilot",
                 githubUsuario: usuario, cotaPremiumMes: cota, arquivoToken: arquivo)
    }

    private func cfg(_ conta: ContaUso, temp: PastaTemp, arquivoGlobal: URL? = nil) -> Configuracao {
        var cfg = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USO_CONTAS": "1"], home: temp.url)
        cfg.contas = [conta]
        cfg.authCopilot = arquivoGlobal
        return cfg
    }

    // MARK: Catálogo e opt-in

    func testCatalogoDoRepoExpoeCopilotOptIn() throws {
        let lidos = try CatalogoAgentes.ler(diretorio: repoAgentsD)
        let c = try XCTUnwrap(lidos.first { $0.nome == "copilot" })
        XCTAssertEqual(c.uso.tipo, "copilot")
        XCTAssertNil(c.cli)
        XCTAssertFalse(c.painel)
        XCTAssertTrue(c.optIn)
        XCTAssertEqual(c.uso.fonte, "api.github.com/users/{username}/settings/billing/premium_request/usage")
        let emb = try XCTUnwrap(Agentes.embutidos.first { $0.nome == "copilot" })
        XCTAssertTrue(emb.optIn)
        XCTAssertFalse(emb.painel)
        XCTAssertNil(emb.cli)
        XCTAssertFalse(ClarezaCota.recebeCard(emb))
        XCTAssertEqual(ClarezaCota.detalhe(nome: "copilot"), ClarezaCota.detalheCopilot)
        XCTAssertEqual(ClarezaCota.notaCota("copilot"), ClarezaCota.notaCopilot)
        XCTAssertFalse(LanesPainel.ordem.contains("copilot"))
    }

    func testCopilotNaoEntraNoPadraoMasPodeSerAdicionado() {
        XCTAssertTrue(Agentes.todos.contains { $0.nome == "copilot" && $0.optIn && !$0.painel })
        XCTAssertFalse(ContaUso.padrao.contains { $0.id == "copilot" || $0.tipo == "copilot" })
        XCTAssertTrue(ContaUso.todas.contains { $0.tipo == "copilot" })
        XCTAssertTrue(ContaUso.tipos.contains("copilot"))
        XCTAssertTrue(ContasConfig.tiposNovos.contains("copilot"))
        let atuais = ContaUso.padrao.map { ContaCadastro(conta: $0) }
            + [ContaCadastro(conta: ContaUso(id: "gemini", tipo: "gemini", rotulo: "Gemini"))]
        let rascunho = ContasConfig.rascunho(nas: atuais)
        XCTAssertEqual(rascunho.tipo, "copilot", "com padrão + gemini, o tipo livre é copilot")
        let copilot = ContasConfig.aplicarTipo(rascunho, tipo: "copilot", nas: atuais + [rascunho])
        XCTAssertEqual(copilot.tipo, "copilot")
        XCTAssertNil(ContasConfig.problema(copilot, nas: atuais + [copilot]))
    }

    func testCaminhoGlobalSoQuandoConfigurado() throws {
        let temp = try PastaTemp()
        let padrao = Configuracao.resolver(ambiente: [:], home: temp.url)
        XCTAssertNil(padrao.authCopilot)
        let outro = Configuracao.resolver(
            ambiente: ["TRANSCENTIA_COPILOT_TOKEN": "~/copilot-token"], home: temp.url)
        XCTAssertEqual(outro.authCopilot, temp.url.appendingPathComponent("copilot-token"))
    }

    func testConfigNaoGuardaToken() throws {
        var dados: [String: Any] = [
            "contas": [[
                "id": "copilot", "tipo": "copilot", "rotulo": "Copilot",
                "nome": "copilot", "sigla": "CP",
                "githubUsuario": " octocat ", "cotaPremiumMes": 300,
                "arquivoToken": "~/tok", "token": "segredo-nao-gravar",
            ]],
        ]
        let lidas = ContasConfig.ler(dados)
        XCTAssertEqual(lidas.count, 1)
        XCTAssertEqual(lidas[0].githubUsuario, "octocat")
        XCTAssertEqual(lidas[0].cotaTexto, "300")
        XCTAssertEqual(lidas[0].arquivoToken, "~/tok")
        ContasConfig.gravar(lidas, em: &dados)
        let item = try XCTUnwrap((dados["contas"] as? [[String: Any]])?.first)
        XCTAssertNil(item["token"])
        XCTAssertEqual(item["githubUsuario"] as? String, "octocat")
        XCTAssertEqual(item["cotaPremiumMes"] as? Int, 300)
        XCTAssertEqual(item["arquivoToken"] as? String, "~/tok")
        let texto = String(data: try JSONSerialization.data(withJSONObject: dados), encoding: .utf8) ?? ""
        XCTAssertFalse(texto.contains("segredo-nao-gravar"))
    }

    // MARK: Credencial (só leitura)

    func testArquivoTextoEJsonEBearer() {
        let texto = CredenciaisCopilot.ler(Data("  tok-arquivo \n".utf8), caminho: "/t")
        XCTAssertEqual(texto, .success(TokenConta(valor: "tok-arquivo")))
        let json = CredenciaisCopilot.ler(Data(#"{"token":"tok-json","refresh_token":"nao"}"#.utf8), caminho: "/j")
        XCTAssertEqual(json, .success(TokenConta(valor: "tok-json")))
        XCTAssertEqual(CredenciaisCopilot.textoSecreto("Bearer tok-kc"), "tok-kc")
        XCTAssertNil(CredenciaisCopilot.textoSecreto("   "))
        XCTAssertNil(CredenciaisCopilot.textoSecreto("dois tokens"))
        XCTAssertEqual(CredenciaisCopilot.ler(Data(#"{"username":"octocat"}"#.utf8), caminho: "/ruim"),
                       .failure(.credencialIlegivel("/ruim")))
        XCTAssertEqual(CredenciaisCopilot.ler(Data("[]".utf8), caminho: "/lista"),
                       .failure(.credencialIlegivel("/lista")))
    }

    func testKeychainGanhaDoArquivo() {
        let arquivo = CredenciaisCopilot.ler(Data("tok-arquivo".utf8), caminho: "/t")
        XCTAssertEqual(arquivo, .success(TokenConta(valor: "tok-arquivo")))
        var leu = false
        let escolhido = CredenciaisCopilot.resolver(keychain: "tok-kc", arquivoConta: "/t", arquivoGlobal: nil,
                                                    ler: { _ in leu = true; return Data("tok-arquivo".utf8) })
        XCTAssertEqual(escolhido, .success(TokenConta(valor: "tok-kc")))
        XCTAssertFalse(leu)
        XCTAssertEqual(TokenCopilot.conta, "copilot")
        XCTAssertEqual(Cofre.servicoPadrao, "app.tuttidash.mac")
    }

    // MARK: Parser e URL

    func testUserAgentECabecalhosOficiais() throws {
        XCTAssertEqual(ParserUsoCopilot.userAgent, "TuttiDash/\(ParserUsoCopilot.versaoProduto)")
        XCTAssertEqual(ParserUsoCopilot.versaoAPI, "2026-03-10")
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let dados = try Data(contentsOf: plist)
        let obj = try XCTUnwrap(PropertyListSerialization.propertyList(from: dados, format: nil) as? [String: Any])
        XCTAssertEqual(obj["CFBundleName"] as? String, ParserUsoCopilot.nomeProduto)
        XCTAssertEqual(obj["CFBundleShortVersionString"] as? String, ParserUsoCopilot.versaoProduto)
        let h = ParserUsoCopilot.cabecalhos(TokenConta(valor: "tok-teste"))
        XCTAssertEqual(Set(h.keys), ["Authorization", "Accept", "X-GitHub-Api-Version", "User-Agent"])
        XCTAssertEqual(h["Authorization"], "Bearer tok-teste")
        XCTAssertEqual(h["Accept"], "application/vnd.github+json")
        XCTAssertEqual(h["X-GitHub-Api-Version"], "2026-03-10")
        XCTAssertEqual(h["User-Agent"], "TuttiDash/0.2.0")
    }

    func testUrlDoMesPessoal() throws {
        let url = try XCTUnwrap(ParserUsoCopilot.url(usuario: "octocat", agora: agora))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.github.com")
        XCTAssertEqual(url.path, "/users/octocat/settings/billing/premium_request/usage")
        XCTAssertEqual(url.query?.contains("year=2026"), true)
        XCTAssertEqual(url.query?.contains("month=10"), true)
        XCTAssertFalse(url.absoluteString.contains("tok"))
        XCTAssertEqual(ParserUsoCopilot.pedido(usuario: "", cota: 300, agora: agora),
                       .failure(.semUsuarioCopilot))
        XCTAssertEqual(ParserUsoCopilot.pedido(usuario: "octo/cat", cota: 300, agora: agora),
                       .failure(.usuarioCopilotInvalido))
        XCTAssertEqual(ParserUsoCopilot.pedido(usuario: "octocat", cota: nil, agora: agora),
                       .failure(.semCotaInformada))
        XCTAssertEqual(ParserUsoCopilot.pedido(usuario: "octocat", cota: 0, agora: agora),
                       .failure(.semCotaInformada))
        XCTAssertEqual(ErroUso.semCotaInformada.mensagem, "sem cota informada")
    }

    func testParserSomaOMesENaoInventaZero() {
        guard case .success(let js) = ParserUsoCopilot.ler(
            Data(Fixtures.Uso.corpo("copilot.json").utf8), cota: 300, agora: agora) else {
            return XCTFail("150 requisições com cota 300")
        }
        XCTAssertEqual(js.map(\.chave), ["premium"])
        XCTAssertEqual(js[0].rotulo, "mês")
        XCTAssertEqual(js[0].pct, 50, "100 + 50 = 150; 150/300 = 50%")
        XCTAssertEqual(js[0].resetEm, resetNovembro)
        XCTAssertEqual(ParserUsoCopilot.ler(Data("lixo".utf8), cota: 300, agora: agora),
                       .failure(.respostaIlegivel))
        XCTAssertEqual(ParserUsoCopilot.ler(Data(Fixtures.Uso.corpo("copilot.json").utf8), cota: 0, agora: agora),
                       .failure(.semCotaInformada))
        let vazio = #"{"user":"octocat","timePeriod":{"year":2026,"month":10},"usageItems":[]}"#
        XCTAssertEqual(ParserUsoCopilot.ler(Data(vazio.utf8), cota: 300, agora: agora),
                       .failure(.licencaOrganizacao))
        XCTAssertTrue(ErroUso.licencaOrganizacao.mensagem.contains("organização"))
        let org = #"{"organization":"acme","user":"octocat","usageItems":[{"unitType":"requests","grossQuantity":150}]}"#
        XCTAssertEqual(ParserUsoCopilot.ler(Data(org.utf8), cota: 300, agora: agora),
                       .failure(.respostaOrganizacao))
        XCTAssertTrue(ErroUso.respostaOrganizacao.mensagem.contains("organização"))
        let outroMes = #"{"user":"octocat","timePeriod":{"year":2026,"month":9},"usageItems":[{"unitType":"requests","grossQuantity":150}]}"#
        XCTAssertEqual(ParserUsoCopilot.ler(Data(outroMes.utf8), cota: 300, agora: agora),
                       .failure(.relatorioOutroMes))
        let zeroExplicito = #"{"user":"octocat","timePeriod":{"year":2026,"month":10},"usageItems":[{"unitType":"requests","grossQuantity":0}]}"#
        guard case .success(let zero) = ParserUsoCopilot.ler(Data(zeroExplicito.utf8), cota: 300, agora: agora) else {
            return XCTFail("quantidade 0 informada pelo servidor é 0% de verdade")
        }
        XCTAssertEqual(zero[0].pct, 0)
        let misto = #"{"user":"octocat","usageItems":[{"unitType":"requests","grossQuantity":150},{"unitType":"dollars","grossQuantity":9999}]}"#
        guard case .success(let soRequests) = ParserUsoCopilot.ler(Data(misto.utf8), cota: 300, agora: agora) else {
            return XCTFail("dólar não entra na soma")
        }
        XCTAssertEqual(soRequests[0].pct, 50)
        let semQtd = #"{"user":"octocat","usageItems":[{"unitType":"requests","model":"gpt-4o"}]}"#
        XCTAssertEqual(ParserUsoCopilot.ler(Data(semQtd.utf8), cota: 300, agora: agora),
                       .failure(.semQuantidadeCopilot))
    }

    // MARK: Coletor

    func testColetorCaminhoBom() async throws {
        let temp = try PastaTemp()
        let arquivo = try temp.escrever("tok", "tok-arquivo\n")
        let antes = try Data(contentsOf: arquivo)
        let t = TransporteFalso(json: ["api.github.com": Fixtures.Uso.corpo("copilot.json")])
        let lido = Lido()
        let caminhoTok = arquivo.path
        let usos = await ColetorUso(transporte: t, ler: { url in
            // alvosPorTipo também lê o .last-update-result do Claude; só o token do Copilot importa aqui.
            if url.path == caminhoTok { lido.marcar() }
            return try? Data(contentsOf: url)
        }, lerTokenCopilot: { "tok-key" })
            .coletar(config: cfg(conta(arquivo: arquivo.path), temp: temp), agora: agora)
        XCTAssertEqual(usos.map(\.conta), ["copilot"])
        XCTAssertEqual(usos[0].pct, 50)
        XCTAssertEqual(usos[0].critica?.rotulo, "mês")
        XCTAssertNil(usos[0].motivo)
        XCTAssertFalse(lido.foi, "Keychain presente: o arquivo do Copilot não é lido")
        XCTAssertEqual(try Data(contentsOf: arquivo), antes)
        XCTAssertEqual(t.chamadas.count, 1)
        let chamada = try XCTUnwrap(t.chamadas.first)
        XCTAssertEqual(chamada.metodo, "GET")
        XCTAssertNil(chamada.corpo)
        XCTAssertEqual(chamada.url.host, "api.github.com")
        XCTAssertEqual(chamada.url.path, "/users/octocat/settings/billing/premium_request/usage")
        XCTAssertEqual(chamada.url.query?.contains("year=2026"), true)
        XCTAssertEqual(chamada.url.query?.contains("month=10"), true)
        XCTAssertFalse(chamada.url.absoluteString.contains("tok-key"))
        XCTAssertEqual(Set(chamada.cabecalhos.keys),
                       ["Authorization", "Accept", "X-GitHub-Api-Version", "User-Agent"])
        XCTAssertEqual(chamada.cabecalhos["Authorization"], "Bearer tok-key")
        XCTAssertEqual(chamada.cabecalhos["User-Agent"], ParserUsoCopilot.userAgent)
        XCTAssertEqual(chamada.cabecalhos["Accept"], "application/vnd.github+json")
        XCTAssertEqual(chamada.cabecalhos["X-GitHub-Api-Version"], ParserUsoCopilot.versaoAPI)
    }

    func testArquivoQuandoKeychainVazio() async throws {
        let temp = try PastaTemp()
        let arquivo = try temp.escrever("tok", #"{"github_token":"tok-arquivo"}"#)
        let antes = try Data(contentsOf: arquivo)
        let t = TransporteFalso(json: ["api.github.com": Fixtures.Uso.corpo("copilot.json")])
        let usos = await ColetorUso(transporte: t, ler: { try? Data(contentsOf: $0) }, lerTokenCopilot: { nil })
            .coletar(config: cfg(conta(arquivo: arquivo.path), temp: temp), agora: agora)
        XCTAssertEqual(usos[0].pct, 50)
        XCTAssertEqual(t.chamadas.first?.cabecalhos["Authorization"], "Bearer tok-arquivo")
        XCTAssertEqual(try Data(contentsOf: arquivo), antes)
    }

    func testSemTokenSemCotaOuSemUsuarioNaoChamaARede() async throws {
        let temp = try PastaTemp()
        let t = TransporteFalso([:])
        let semToken = await ColetorUso(transporte: t, lerTokenCopilot: { nil })
            .coletar(config: cfg(conta(), temp: temp), agora: agora)
        XCTAssertEqual(semToken[0].motivo, ErroUso.semTokenCopilot.mensagem)
        XCTAssertNil(semToken[0].pct)
        XCTAssertTrue(t.chamadas.isEmpty)

        let semCota = await ColetorUso(transporte: t, lerTokenCopilot: { "tok" })
            .coletar(config: cfg(conta(cota: nil), temp: temp), agora: agora)
        XCTAssertEqual(semCota[0].motivo, "sem cota informada")
        XCTAssertNil(semCota[0].pct)
        XCTAssertTrue(t.chamadas.isEmpty)

        let cotaZero = await ColetorUso(transporte: t, lerTokenCopilot: { "tok" })
            .coletar(config: cfg(conta(cota: 0), temp: temp), agora: agora)
        XCTAssertEqual(cotaZero[0].motivo, "sem cota informada")
        XCTAssertNil(cotaZero[0].pct)

        let semUsuario = await ColetorUso(transporte: t, lerTokenCopilot: { "tok" })
            .coletar(config: cfg(conta(usuario: "  "), temp: temp), agora: agora)
        XCTAssertEqual(semUsuario[0].motivo, ErroUso.semUsuarioCopilot.mensagem)
        XCTAssertTrue(t.chamadas.isEmpty)
    }

    func testRelatorioVazioOuDeOrganizacaoFicaSemDado() async throws {
        let temp = try PastaTemp()
        let vazio = #"{"user":"octocat","timePeriod":{"year":2026,"month":10},"usageItems":[]}"#
        let t = TransporteFalso(json: ["api.github.com": vazio])
        let usos = await ColetorUso(transporte: t, lerTokenCopilot: { "tok" })
            .coletar(config: cfg(conta(), temp: temp), agora: agora)
        XCTAssertNil(usos[0].pct)
        XCTAssertEqual(usos[0].motivo, ErroUso.licencaOrganizacao.mensagem)
        XCTAssertFalse(usos[0].temDado)

        let org = #"{"organization":"acme","usageItems":[{"unitType":"requests","grossQuantity":150}]}"#
        let t2 = TransporteFalso(json: ["api.github.com": org])
        let usosOrg = await ColetorUso(transporte: t2, lerTokenCopilot: { "tok" })
            .coletar(config: cfg(conta(), temp: temp), agora: agora)
        XCTAssertNil(usosOrg[0].pct)
        XCTAssertEqual(usosOrg[0].motivo, ErroUso.respostaOrganizacao.mensagem)
    }

    func testErrosHttpNaoViraramNumero() async throws {
        let temp = try PastaTemp()
        let cfg = cfg(conta(), temp: temp)
        for (status, motivo) in [(401, ErroUso.tokenCopilotRecusado.mensagem),
                                 (403, ErroUso.tokenCopilotRecusado.mensagem),
                                 (404, ErroUso.copilotSemRelatorio.mensagem),
                                 (500, ErroUso.http(500).mensagem)] {
            let t = TransporteFalso(["api.github.com": [.success(RespostaHTTP(status: status, corpo: Data("{}".utf8)))]])
            let usos = await ColetorUso(transporte: t, lerTokenCopilot: { "tok" }).coletar(config: cfg, agora: agora)
            XCTAssertNil(usos[0].pct, "HTTP \(status)")
            XCTAssertEqual(usos[0].motivo, motivo, "HTTP \(status)")
            XCTAssertEqual(t.chamadas.count, 1)
        }
    }

    func testFreioDepoisDe429() async throws {
        let temp = try PastaTemp()
        let cfg = cfg(conta(), temp: temp)
        let t = TransporteFalso(["api.github.com": [.success(RespostaHTTP(status: 429, corpo: Data()))]])
        let coletor = ColetorUso(transporte: t, lerTokenCopilot: { "tok" })
        let primeiro = await coletor.coletar(config: cfg, agora: agora)
        XCTAssertNil(primeiro[0].pct)
        XCTAssertEqual(primeiro[0].motivo, ErroUso.limitado.mensagem)
        XCTAssertEqual(t.chamadas.count, 1)
        let segundo = await coletor.coletar(
            config: cfg, agora: agora.addingTimeInterval(ColetorUso.intervaloMinimo + 30))
        XCTAssertEqual(t.chamadas.count, 1, "15 min depois do 429, sem nova chamada")
        XCTAssertNil(segundo[0].pct)
        let terceiro = await coletor.coletar(
            config: cfg, agora: agora.addingTimeInterval(ColetorUso.esperaLimitado + 1))
        XCTAssertEqual(t.chamadas.count, 2)
        XCTAssertNil(terceiro[0].pct)
    }
}
