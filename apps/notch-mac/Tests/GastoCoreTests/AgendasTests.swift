import XCTest
@testable import GastoCore

final class SistemaFalso: SistemaAgendas {
    var arquivos: [String: Data] = [:]
    var modos: [String: UInt16] = [:]
    var pastas: Set<String> = []
    var chamadas: [[String]] = []
    var respostaPrint: (Int32, String) = (113, "Could not find service")
    var uid: UInt32 { 501 }
    func escrever(_ dados: Data, em url: URL, modo: UInt16) throws {
        arquivos[url.path] = dados; modos[url.path] = modo
    }
    func criarPasta(_ url: URL) throws { pastas.insert(url.path) }
    func apagar(_ url: URL) throws { arquivos[url.path] = nil }
    func existe(_ url: URL) -> Bool { arquivos[url.path] != nil }
    func ler(_ url: URL) -> Data? { arquivos[url.path] }
    func launchctl(_ args: [String]) -> (Int32, String) {
        chamadas.append(args)
        return args.first == "print" ? respostaPrint : (0, "")
    }
}

final class AgendasTests: XCTestCase {
    let casa = URL(fileURLWithPath: "/tmp/casa-teste")
    static let jobs: [[String: Any]] = [
        ["label": "com.exemplo.dispatcher", "nome": "Exemplo Dispatcher", "chave": "dispatcher", "intervalo_padrao": 60,
         "run_at_load": true, "script": "~/x/dispatcher.py", "argumentos": ["--real"], "log": "~/Library/Logs/Ex/d.log"],
        ["label": "com.exemplo.watch", "nome": "Exemplo Vigia", "chave": "watch", "intervalo_padrao": 180,
         "script": "~/x/watch.py", "log": "~/Library/Logs/Ex/w.log"],
    ]
    func cfg(_ extra: [String: Any] = [:]) -> [String: Any] {
        var a: [String: Any] = ["jobs": Self.jobs]; a.merge(extra) { $1 }; return ["agendas": a]
    }
    var todos: [Trabalho] { Trabalho.lista(config: cfg()) }
    var dispatcher: Trabalho { todos[0] }

    func pad(_ rel: String) -> String {
        URL(fileURLWithPath: "/tmp/casa-teste").appendingPathComponent(rel).standardizedFileURL.path
    }

    func testPlistPorArgvSemShell() throws {
        let g = GerenciadorAgendas(home: casa, sistema: SistemaFalso(), config: cfg())
        for t in todos {
            let dados = try g.plist(t)
            let texto = String(data: dados, encoding: .utf8)!
            XCTAssertNil(texto.range(of: #"/Users/[^/\s<"]+"#, options: .regularExpression), t.label)
            XCTAssertFalse(texto.contains("$HOME"))
            XCTAssertFalse(texto.contains("#!/bin/zsh"))
            XCTAssertFalse(texto.contains("$("))
            let p = try PropertyListSerialization.propertyList(from: dados, format: nil) as! [String: Any]
            let script = pad(t.chave == "dispatcher" ? "x/dispatcher.py" : "x/watch.py")
            XCTAssertEqual(p["ProgramArguments"] as? [String], ["/usr/bin/python3", script] + t.argumentos)
            let log = pad(t.chave == "dispatcher" ? "Library/Logs/Ex/d.log" : "Library/Logs/Ex/w.log")
            XCTAssertEqual(p["StandardOutPath"] as? String, log)
            XCTAssertEqual(p["StandardErrorPath"] as? String, log)
            XCTAssertEqual(p["StartInterval"] as? Int, t.intervaloPadrao)
            XCTAssertNil(p["EnvironmentVariables"])
            XCTAssertFalse(t.label.contains("painel"))
        }
    }

    /// `~/$(touch /tmp/pwn)` e `label=../../evil` não geram script nem arquivo fora do home.
    func testInjecaoNaoExecutaNemGravaFora() throws {
        let s = SistemaFalso()
        let g = GerenciadorAgendas(home: casa, sistema: s, config: ["agendas": ["jobs": [
            ["label": "../../evil", "nome": "x", "chave": "x", "script": "~/$(touch /tmp/pwn)", "log": "/tmp/pwn"],
            ["label": "com.exemplo.mal", "nome": "x", "chave": "x", "script": "~/$(touch /tmp/pwn)",
             "log": "~/Library/Logs/Ex/x.log"],
        ]]])
        XCTAssertTrue(g.trabalhos.isEmpty)
        let comum = { (label: String, script: String, log: String) in
            Trabalho(label: label, nome: "x", chave: "x", intervaloPadrao: 60, runAtLoad: false,
                     interpretador: "/usr/bin/python3", script: script, argumentos: [], log: log)
        }
        for t in [comum("../../evil", "~/x/ok.py", "~/Library/Logs/Ex/x.log"),
                  comum("com.exemplo.mal", "~/$(touch /tmp/pwn)", "~/Library/Logs/Ex/x.log"),
                  comum("com.exemplo.fuga", "~/../../tmp/pwn", "~/Library/Logs/Ex/x.log")] {
            XCTAssertThrowsError(try g.instalar(t))
        }
        XCTAssertTrue(s.arquivos.isEmpty)
        XCTAssertTrue(s.pastas.isEmpty)
        XCTAssertTrue(s.chamadas.isEmpty)
    }

    func testIntervaloEAmbienteDaConfig() throws {
        let g = GerenciadorAgendas(home: casa, sistema: SistemaFalso(),
                                   config: cfg(["dispatcher_s": 90, "env": ["dispatcher": ["SKIP_PREFLIGHT": "1"]]]))
        let p = try PropertyListSerialization.propertyList(from: try g.plist(dispatcher), format: nil) as! [String: Any]
        XCTAssertEqual(p["StartInterval"] as? Int, 90)
        XCTAssertEqual(p["EnvironmentVariables"] as? [String: String], ["SKIP_PREFLIGHT": "1"])
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(p["AssociatedBundleIdentifiers"] as? [String], ["app.tuttidash.mac"])
    }

    func testInstalarRecarregaSoAqueleJob() throws {
        let s = SistemaFalso()
        let g = GerenciadorAgendas(home: casa, sistema: s, config: cfg())
        try g.instalar(dispatcher)
        let plist = try g.plistURL(dispatcher)
        XCTAssertEqual(s.modos[plist.path], GerenciadorAgendas.modoPlist)
        XCTAssertNotNil(s.arquivos[plist.path])
        XCTAssertNil(s.arquivos[try XCTUnwrap(g.lancadorURL(dispatcher)).path])
        let texto = String(data: try XCTUnwrap(s.arquivos[plist.path]), encoding: .utf8)!
        XCTAssertFalse(texto.contains("#!/bin"))
        XCTAssertEqual(s.chamadas, [["bootout", "gui/501/com.exemplo.dispatcher"],
                                    ["bootstrap", "gui/501", plist.path]])
        s.chamadas = []
        try g.intervaloMudou(chave: "agendas.watch_s")      // não instalado pelo app: não mexe
        XCTAssertTrue(s.chamadas.isEmpty)
        g.config = cfg(["dispatcher_s": 120])
        try g.intervaloMudou(chave: "agendas.dispatcher_s")
        XCTAssertEqual(s.chamadas.map(\.first!), ["bootout", "bootstrap"])
        XCTAssertTrue(s.chamadas.allSatisfy { $0.joined().contains("dispatcher") })
    }

    func testDesinstalarApagaSoOQueCriou() throws {
        let s = SistemaFalso()
        let g = GerenciadorAgendas(home: casa, sistema: s, config: cfg())
        let alheio = try g.plistURL(todos[1])
        s.arquivos[alheio.path] = Data("de outro".utf8)          // plist que o app não criou
        try g.instalar(dispatcher)
        try g.remover(todos[1])                         // não gerenciado: fica
        XCTAssertNotNil(s.arquivos[alheio.path])
        try g.desinstalarTudo()
        XCTAssertNil(s.arquivos[try g.plistURL(dispatcher).path])
        XCTAssertNil(s.arquivos[try XCTUnwrap(g.lancadorURL(dispatcher)).path])
        XCTAssertNil(s.arquivos[g.manifestoURL.path]); XCTAssertNotNil(s.arquivos[alheio.path])
    }

    func testSemConfigNenhumJob() {
        XCTAssertTrue(Trabalho.lista(config: [:]).isEmpty)
    }

    func testEstado() {
        let s = SistemaFalso()
        let g = GerenciadorAgendas(home: casa, sistema: s, config: cfg())
        XCTAssertEqual(g.estado(dispatcher), .parado)
        s.respostaPrint = (0, "state = not running\n\tlast exit code = 0\n"); XCTAssertEqual(g.estado(dispatcher), .ativo)
        s.respostaPrint = (0, "state = not running\n\tlast exit code = 1\n")
        if case .erro = g.estado(dispatcher) {} else { XCTFail() }
    }
}

final class StatusAgenteTests: XCTestCase {
    func testRodando() { XCTAssertEqual(StatusAgente.de(print: "x = {\n\tstate = running\n", desativado: false), .rodando) }
    func testAguardando() { XCTAssertEqual(StatusAgente.de(print: "\tstate = not running\n", desativado: false), .aguardando) }
    func testDesligado() { XCTAssertEqual(StatusAgente.de(print: nil, desativado: true), .desligado) }
    func testPrecisaAprovacao() { XCTAssertEqual(StatusAgente.de(print: nil, desativado: false), .precisaAprovacao) }
    func testLigado() {
        XCTAssertTrue(StatusAgente.rodando.ligado); XCTAssertTrue(StatusAgente.aguardando.ligado)
        XCTAssertFalse(StatusAgente.desligado.ligado); XCTAssertFalse(StatusAgente.precisaAprovacao.ligado)
    }
    func testPrintDisabled() {
        let s = "disabled services = {\n\t\"com.transcentia.bots.watch\" => disabled\n\t\"com.x\" => enabled\n}"
        XCTAssertTrue(StatusAgente.desativado("com.transcentia.bots.watch", printDisabled: s))
        XCTAssertFalse(StatusAgente.desativado("com.x", printDisabled: s))
        XCTAssertFalse(StatusAgente.desativado("com.transcentia.lanes.dispatcher", printDisabled: s))
    }
}
