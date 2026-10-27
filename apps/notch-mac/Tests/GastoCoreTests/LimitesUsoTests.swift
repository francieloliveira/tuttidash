import XCTest
import SQLite3
@testable import GastoCore

/// Transporte falso: nenhuma chamada de rede nos testes. Guarda as URLs e os cabeçalhos pedidos.
/// O `ColetorUso` é um actor e chama em série, então não precisa de trava aqui.
/// Marca se uma closure `@Sendable` foi chamada.
final class Lido: @unchecked Sendable {
    private let trava = NSLock()
    private var chamado = false
    func marcar() { trava.lock(); chamado = true; trava.unlock() }
    var foi: Bool { trava.lock(); defer { trava.unlock() }; return chamado }
}

final class TransporteFalso: TransporteHTTP, @unchecked Sendable {
    private var respostas: [String: [Result<RespostaHTTP, URLError>]]
    private(set) var chamadas: [(url: URL, metodo: String, cabecalhos: [String: String], corpo: Data?)] = []

    /// `respostas` por host; cada chamada consome a primeira da fila (a última repete).
    init(_ respostas: [String: [Result<RespostaHTTP, URLError>]]) {
        self.respostas = respostas
    }

    convenience init(json: [String: String], status: Int = 200) {
        self.init(json.mapValues { [.success(RespostaHTTP(status: status, corpo: Data($0.utf8)))] })
    }

    func enviar(_ url: URL, metodo: String, cabecalhos: [String: String], corpo: Data?) async throws -> RespostaHTTP {
        chamadas.append((url, metodo, cabecalhos, corpo))
        let host = url.host ?? ""
        var fila = respostas[host] ?? []
        let item = fila.first
        if fila.count > 1 { fila.removeFirst(); respostas[host] = fila }
        switch item {
        case .success(let r): return r
        case .failure(let e): throw e
        case nil: throw URLError(.unsupportedURL)
        }
    }

    var hosts: [String] { chamadas.map { $0.url.host ?? "" } }
    func cabecalhos(_ host: String) -> [String: String]? {
        chamadas.first { $0.url.host == host }?.cabecalhos
    }
}


final class LimitesUsoTests: XCTestCase {

    // MARK: ISO 8601 com fuso

    func testISO8601() throws {
        let z = try XCTUnwrap(Datas.lerISO8601("2026-10-06T04:06:57.612354Z"))
        XCTAssertEqual(z.timeIntervalSince1970, 1791259617, accuracy: 0.5)
        // mesma hora escrita com +00:00 e com -0300
        XCTAssertEqual(Datas.lerISO8601("2026-10-06T04:06:57+00:00"), z)
        XCTAssertEqual(Datas.lerISO8601("2026-10-06T01:06:57-03:00"), z)
        XCTAssertEqual(Datas.lerISO8601("2026-10-06T01:06:57-0300"), z)
        XCTAssertEqual(Datas.lerISO8601("2026-10-06T06:06:57+02"), z)
        XCTAssertEqual(Datas.lerISO8601(" 2026-10-06t04:06:57.1Z "), z)
    }

    func testISO8601Invalido() {
        XCTAssertNil(Datas.lerISO8601("2026-10-06T04:06:57"))     // sem fuso: não assume nada
        XCTAssertNil(Datas.lerISO8601("2026-10-06"))
        XCTAssertNil(Datas.lerISO8601("2026-13-40T04:06:57Z"))    // data impossível
        XCTAssertNil(Datas.lerISO8601("ontem"))
        XCTAssertNil(Datas.lerISO8601(""))
        XCTAssertNil(Datas.lerISO8601("2026-10-06T04Z"))          // sem minutos
    }

    // MARK: Níveis (80% amarelo, 95% vermelho)

    func testNivelUso() {
        XCTAssertEqual(Uso.nivel(0), .ok)
        XCTAssertEqual(Uso.nivel(79.9), .ok)
        XCTAssertEqual(Uso.nivel(80), .atencao)
        XCTAssertEqual(Uso.nivel(94.9), .atencao)
        XCTAssertEqual(Uso.nivel(95), .critico)
        XCTAssertEqual(Uso.nivel(140), .critico)
    }

    func testJanelaCriticaEAlerta() {
        let u = UsoConta(conta: "claude", rotulo: "Claude Code", fonte: "f", janelas: [
            JanelaUso(chave: "five_hour", rotulo: "5 h", pct: 73),
            JanelaUso(chave: "seven_day", rotulo: "semana", pct: 93),
            JanelaUso(chave: "seven_day_sonnet", rotulo: "semana · sonnet", pct: 1),
        ])
        // manda a mais apertada, não a primeira (o bug clássico de só olhar five_hour)
        XCTAssertEqual(u.critica?.chave, "seven_day")
        XCTAssertEqual(u.pct, 93)
        XCTAssertEqual(u.nivel, .atencao)
        XCTAssertTrue(u.alerta)
        XCTAssertEqual(u.critica?.faltaPct, 7)

        let folgado = UsoConta(conta: "grok", rotulo: "Grok CLI", fonte: "f",
                               janelas: [JanelaUso(chave: "credito", rotulo: "créditos", pct: 12)])
        XCTAssertFalse(folgado.alerta)
        // empate fica com a primeira janela
        let empate = UsoConta(conta: "x", rotulo: "x", fonte: "f", janelas: [
            JanelaUso(chave: "a", rotulo: "a", pct: 50), JanelaUso(chave: "b", rotulo: "b", pct: 50)])
        XCTAssertEqual(empate.critica?.chave, "a")
        // sem janela: sem dado, sem alerta, sem número
        let vazio = UsoConta(conta: "grok", rotulo: "Grok CLI", fonte: "f", motivo: "sem credencial")
        XCTAssertFalse(vazio.temDado)
        XCTAssertNil(vazio.pct)
        XCTAssertFalse(vazio.alerta)
    }

    func testPassaDe100() {
        let j = JanelaUso(chave: "seven_day", rotulo: "semana", pct: 112)
        XCTAssertEqual(j.faltaPct, 0)
        XCTAssertEqual(j.nivel, .critico)
    }

    // MARK: Sessão do OpenCode (opencode.db local)

    /// `opencode.db` de mentira, com a mesma tabela do OpenCode (`credential`).
    @discardableResult
    func criarBancoOpenCode(_ url: URL, valor: String?) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw URLError(.cannotCreateFile) }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT, value TEXT, connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL)",
                     nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO credential VALUES ('c0','outro','x','{}',NULL,NULL,0,0,0)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, parent_id TEXT, fork_session_id TEXT, fork_boundary TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, path TEXT, title TEXT, version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER, summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT, metadata TEXT, cost REAL DEFAULT 0 NOT NULL, tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL, tokens_reasoning INTEGER DEFAULT 0 NOT NULL, tokens_cache_read INTEGER DEFAULT 0 NOT NULL, tokens_cache_write INTEGER DEFAULT 0 NOT NULL, revert TEXT, permission TEXT, agent TEXT, model TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_idle INTEGER, time_viewed INTEGER, idle_outcome TEXT, time_compacting INTEGER, time_archived INTEGER, time_suspended INTEGER, resume_attempts INTEGER DEFAULT 0 NOT NULL)",
                     nil, nil, nil)
        guard let valor else { return url }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO credential VALUES ('c1','opencode','Personal',?1,NULL,NULL,1,0,0)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let transitorio = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, valor, -1, transitorio)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw URLError(.cannotWriteToFile) }
        return url
    }


    func testParserUsoOpenCodeSession() throws {
        let temp = try PastaTemp()
        let banco = temp.url.appendingPathComponent("opencode.db")

        // Cria o banco com a tabela session_v2 (o helper só cria credential)
        try criarBancoOpenCode(banco, valor: "{}")
        try inserirSessao(banco: banco, id: "ses_1", modelo: "nemotron-3.5-super-vl-free",
                          input: 453003, output: 101, reasoning: 85, cacheRead: 0, cacheWrite: 0)

        // nemotron-3.5-super-vl-free tem limite de 1.048.576 tokens (1M)
        // total = 453003 + 101 + 85 + 0 + 0 = 453189
        // pct = 453189 / 1048576 * 100 = 43.2%
        guard case .success(let js) = ParserUsoOpenCodeSession.ler(banco: banco) else {
            return XCTFail("devia ler a sessão do opencode.db")
        }
        XCTAssertEqual(js.count, 1)
        XCTAssertEqual(js[0].chave, "contexto_sessao")
        XCTAssertEqual(js[0].rotulo, "contexto sessão")
        XCTAssertEqual(Int(js[0].pct), 43)   // 453189/1048576*100 = 43.2%
        XCTAssertNil(js[0].resetEm)          // sem reset definido para sessão

        // sessão vazia (sem tokens) = sem janelas
        let bancoVazio = temp.url.appendingPathComponent("opencode_vazio.db")
        try criarBancoOpenCode(bancoVazio, valor: "{}")
        XCTAssertEqual(ParserUsoOpenCodeSession.ler(banco: bancoVazio), .failure(.semJanelas))

        // banco não existe = sem credencial
        XCTAssertEqual(ParserUsoOpenCodeSession.ler(banco: temp.url.appendingPathComponent("nao_existe.db")),
                       .failure(.semCredencial("opencode")))

        // modelo não mapeado usa limite padrão (128k)
        let bancoDesconhecido = temp.url.appendingPathComponent("opencode_desconhecido.db")
        try criarBancoOpenCode(bancoDesconhecido, valor: "{}")
        try inserirSessao(banco: bancoDesconhecido, id: "ses_d", modelo: "modelo-desconhecido-xyz",
                          input: 64000, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0)
        guard case .success(let js2) = ParserUsoOpenCodeSession.ler(banco: bancoDesconhecido) else {
            return XCTFail("devia ler sessão com modelo desconhecido")
        }
        // 64000 / 128000 * 100 = 50%
        XCTAssertEqual(Int(js2[0].pct), 50)

        _ = temp
    }

    /// Insere uma sessão na tabela session_v2 do banco de teste.
    private func inserirSessao(banco: URL, id: String, modelo: String, input: Int, output: Int,
                               reasoning: Int, cacheRead: Int, cacheWrite: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(banco.path, &db) == SQLITE_OK else { throw URLError(.cannotCreateFile) }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO session_v2 (id, project_id, workspace_id, slug, directory, path, title, version, summary_additions, summary_deletions, summary_files, summary_diffs, metadata, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, revert, permission, agent, model, time_created, time_updated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let trans = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, trans)
        sqlite3_bind_text(stmt, 2, "p", -1, trans)
        sqlite3_bind_text(stmt, 3, "w", -1, trans)
        sqlite3_bind_text(stmt, 4, "s", -1, trans)
        sqlite3_bind_text(stmt, 5, "/d", -1, trans)
        sqlite3_bind_text(stmt, 6, "/d", -1, trans)
        sqlite3_bind_text(stmt, 7, "Sessão", -1, trans)
        sqlite3_bind_text(stmt, 8, "2.0.29", -1, trans)
        sqlite3_bind_int(stmt, 9, 0)
        sqlite3_bind_int(stmt, 10, 0)
        sqlite3_bind_int(stmt, 11, 0)
        sqlite3_bind_text(stmt, 12, "", -1, trans)
        sqlite3_bind_text(stmt, 13, "{}", -1, trans)
        sqlite3_bind_double(stmt, 14, 0.0)
        sqlite3_bind_int64(stmt, 15, Int64(input))
        sqlite3_bind_int64(stmt, 16, Int64(output))
        sqlite3_bind_int64(stmt, 17, Int64(reasoning))
        sqlite3_bind_int64(stmt, 18, Int64(cacheRead))
        sqlite3_bind_int64(stmt, 19, Int64(cacheWrite))
        sqlite3_bind_text(stmt, 20, nil, -1, trans)
        sqlite3_bind_text(stmt, 21, "", -1, trans)
        sqlite3_bind_text(stmt, 22, "", -1, trans)
        sqlite3_bind_text(stmt, 23, modelo, -1, trans)
        sqlite3_bind_int64(stmt, 24, 1792080594885)
        sqlite3_bind_int64(stmt, 25, 1792096388705)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw URLError(.cannotWriteToFile) }
    }


    // MARK: Config

    func testConfigCaminhosEChave() throws {
        let temp = try PastaTemp()
        let padrao = Configuracao.resolver(ambiente: [:], home: temp.url)
        XCTAssertEqual(padrao.opencodeDb, temp.url.appendingPathComponent(".local/share/opencode/opencode.db"))
        XCTAssertTrue(padrao.usoContas)
        let outroBanco = Configuracao.resolver(ambiente: ["TRANSCENTIA_OPENCODE_DB": "~/o.db"], home: temp.url)
        XCTAssertEqual(outroBanco.opencodeDb, temp.url.appendingPathComponent("o.db"))

        let casos: [(String, Bool)] = [("0", false), ("false", false), ("nao", false), ("off", false),
                                       ("1", true), ("true", true), ("sim", true)]
        for (texto, esperado) in casos {
            let r = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USO_CONTAS": texto], home: temp.url)
            XCTAssertEqual(r.usoContas, esperado, texto)
            XCTAssertNil(r.erro, texto)
        }
        // valor sem sentido: fica no padrão e avisa
        let ruim = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USO_CONTAS": "talvez"], home: temp.url)
        XCTAssertTrue(ruim.usoContas)
        XCTAssertNotNil(ruim.erro)
    }

    /// Chaves que o GastoCore não conhece ficam em `extras`, para as fontes registradas de fora.
    func testConfigGuardaExtrasParaAsFontes() throws {
        let temp = try PastaTemp()
        let cfg = try temp.escrever(".transcentia/tools/config.json",
                                     #"{"uso_contas": false, "minha_cred": "~/x/auth.json", "ler_extra": true}"#)
        let r = Configuracao.resolver(ambiente: [Configuracao.envConfig: cfg.path, "MINHA_ENV": "~/y.json"], home: temp.url)
        XCTAssertNil(r.erro)
        XCTAssertFalse(r.usoContas)
        XCTAssertEqual(r.caminhoExtra("minha_cred", padrao: "~/z.json"), temp.url.appendingPathComponent("x/auth.json"))
        XCTAssertEqual(r.caminhoExtra("minha_cred", env: "MINHA_ENV", padrao: "~/z.json"), temp.url.appendingPathComponent("y.json"))
        XCTAssertEqual(r.caminhoExtra("ausente", padrao: "~/z.json"), temp.url.appendingPathComponent("z.json"))
        XCTAssertTrue(r.booleanoExtra("ler_extra", padrao: false))
        XCTAssertFalse(r.booleanoExtra("ausente", padrao: false))
    }

    // MARK: Fontes de uso (FRA-565)

    /// Fonte de mentira: token de um arquivo e resposta `{"pct": n}`.
    private struct FonteFalsa: FonteUso {
        let tipo = "falsa"
        var expira: Date? = nil
        func alvo(_ ctx: ContextoUso) -> AlvoUso {
            let expira = self.expira
            return AlvoUso(conta: tipo, rotulo: "Falsa", fonte: "exemplo.test/uso",
                           url: URL(string: "https://exemplo.test/uso")!, vencido: .tokenExpirado("falsa"),
                           cabecalhos: { t in ["Authorization": "Bearer \(t.valor)"] },
                           token: { .success(TokenConta(valor: "tok", expiraEm: expira)) },
                           lerResposta: { dados in
                               guard let obj = JV.objeto(dados), let pct = JV.numero(obj["pct"]) else {
                                   return .failure(.respostaIlegivel)
                               }
                               return .success([JanelaUso(chave: "dia", rotulo: "Dia", pct: pct)])
                           })
        }
    }

    private func cfgFalsa() throws -> (Configuracao, PastaTemp) {
        let temp = try PastaTemp()
        var cfg = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USO_CONTAS": "1"], home: temp.url)
        cfg.contas = [ContaUso(id: "falsa-1", tipo: "falsa", rotulo: "Falsa 1")]
        return (cfg, temp)
    }

    func testFontesPublicasSaoSoAsOficiaisOuLocais() {
        XCTAssertEqual(Set(FontesUso.publicas.map(\.tipo)), ["copilot", "opencode_sessao"])
    }

    func testColetorUsaAFonteDoTipoDaConta() async throws {
        let (cfg, temp) = try cfgFalsa()
        let t = TransporteFalso(json: ["exemplo.test": #"{"pct": 42}"#])
        let usos = await ColetorUso(transporte: t, fontes: [FonteFalsa()]).coletar(config: cfg)
        XCTAssertEqual(usos.map(\.conta), ["falsa-1"])
        XCTAssertEqual(usos[0].rotulo, "Falsa 1")
        XCTAssertEqual(usos[0].janelas.first?.pct, 42)
        XCTAssertEqual(t.cabecalhos("exemplo.test")?["Authorization"], "Bearer tok")
        _ = temp
    }

    func testTipoSemFonteFicaDeFora() async throws {
        let (cfg, temp) = try cfgFalsa()
        let t = TransporteFalso([:])
        let usos = await ColetorUso(transporte: t, fontes: []).coletar(config: cfg)
        XCTAssertTrue(usos.isEmpty)
        XCTAssertTrue(t.chamadas.isEmpty)
        _ = temp
    }

    func testTokenVencidoNaoChamaARede() async throws {
        let (cfg, temp) = try cfgFalsa()
        let t = TransporteFalso([:])
        let usos = await ColetorUso(transporte: t, fontes: [FonteFalsa(expira: Date(timeIntervalSince1970: 1))])
            .coletar(config: cfg)
        XCTAssertFalse(usos[0].temDado)
        XCTAssertEqual(usos[0].motivo, ErroUso.tokenExpirado("falsa").mensagem)
        XCTAssertTrue(t.chamadas.isEmpty)
        _ = temp
    }

    func testRecusadoELimitadoFreiam() async throws {
        let (cfg, temp) = try cfgFalsa()
        let t = TransporteFalso(["exemplo.test": [.success(RespostaHTTP(status: 401, corpo: Data()))]])
        let usos = await ColetorUso(transporte: t, fontes: [FonteFalsa()]).coletar(config: cfg)
        XCTAssertEqual(usos[0].motivo, ErroUso.naoAutorizado.mensagem)

        let t429 = TransporteFalso(["exemplo.test": [.success(RespostaHTTP(status: 429, corpo: Data())),
                                                     .success(RespostaHTTP(status: 200, corpo: Data(#"{"pct": 1}"#.utf8)))]])
        let coletor = ColetorUso(transporte: t429, fontes: [FonteFalsa()])
        let agora = Date(timeIntervalSince1970: 1_791_000_000)
        let primeiro = await coletor.coletar(config: cfg, agora: agora)
        XCTAssertEqual(primeiro[0].motivo, ErroUso.limitado.mensagem)
        _ = await coletor.coletar(config: cfg, agora: agora.addingTimeInterval(ColetorUso.intervaloMinimo + 1))
        XCTAssertEqual(t429.chamadas.count, 1, "depois de um 429 espera bem mais que o intervalo mínimo")
        _ = temp
    }

    func testDesligadoNaoChamaNada() async throws {
        var (cfg, temp) = try cfgFalsa()
        cfg.usoContas = false
        let t = TransporteFalso(json: ["exemplo.test": #"{"pct": 1}"#])
        let usos = await ColetorUso(transporte: t, fontes: [FonteFalsa()]).coletar(config: cfg)
        XCTAssertTrue(usos.isEmpty)
        XCTAssertTrue(t.chamadas.isEmpty)
        _ = temp
    }

    // MARK: Formatação

    func testFormatoPct() {
        XCTAssertEqual(Formato.pct(0), "0%")
        XCTAssertEqual(Formato.pct(0.4), "<1%")
        XCTAssertEqual(Formato.pct(33.4), "33%")
        XCTAssertEqual(Formato.pct(94.6), "95%")
        XCTAssertEqual(Formato.pct(112), "112%")
    }

    func testFormatoFaltamEQuando() {
        let cal = calendarioFixo()
        let agora = data("2026-10-06T18:30:00")
        XCTAssertEqual(Formato.faltam(agora.addingTimeInterval(-10), agora: agora), "agora")
        XCTAssertEqual(Formato.faltam(agora.addingTimeInterval(30), agora: agora), "em 1 min")
        XCTAssertEqual(Formato.faltam(agora.addingTimeInterval(48 * 60), agora: agora), "em 48 min")
        XCTAssertEqual(Formato.faltam(agora.addingTimeInterval(2 * 3600 + 5 * 60), agora: agora), "em 2h05")
        XCTAssertEqual(Formato.faltam(agora.addingTimeInterval(3 * 86400), agora: agora), "em 3 d")

        XCTAssertEqual(Formato.quando(data("2026-10-06T23:05:00"), agora: agora, calendario: cal), "23:05")
        XCTAssertEqual(Formato.quando(data("2026-10-07T03:00:00"), agora: agora, calendario: cal), "qua 03:00")
    }
}