import Darwin
import XCTest
@testable import GastoCore

final class ProxyDoLinearTests: XCTestCase {
    func testArgumentosNaoLevamOToken() {
        let segredo = "lin_api_segredo_teste"
        let args = ProxyDoLinear.argumentos(script: "/tmp/proxy_linear.py")
        XCTAssertEqual(args, ["/usr/bin/python3", "/tmp/proxy_linear.py", "--servir"])
        XCTAssertFalse(args.contains { $0.contains(segredo) })
        XCTAssertEqual(args.filter { $0 == "--servir" }.count, 1)
    }

    func testPrimeiroScriptLegivel() throws {
        let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pasta) }
        let script = pasta.appendingPathComponent("proxy_linear.py")
        try Data("print(1)\n".utf8).write(to: script)
        let achou = ProxyDoLinear.primeiroLegivel([
            pasta.appendingPathComponent("nao-existe.py"),
            script,
        ])
        XCTAssertEqual(achou, script)
        XCTAssertNil(ProxyDoLinear.primeiroLegivel([pasta.appendingPathComponent("nao-existe.py")]))
    }

    func testCandidatosSaoSoOBundle() {
        let recursos = URL(fileURLWithPath: "/tmp/app/Contents/Resources")
        let lista = ProxyDoLinear.candidatosScript(recursos: recursos)
        XCTAssertEqual(lista.map(\.path), ["/tmp/app/Contents/Resources/proxy_linear.py"])
        XCTAssertFalse(lista.contains { $0.path.contains(".transcentia") })
        XCTAssertTrue(ProxyDoLinear.candidatosScript(recursos: nil).isEmpty)
    }

    func testSoSinalizaSeOsArgsTemOProxy() {
        XCTAssertTrue(ProxyDoLinear.deveSinalizar(args: "/usr/bin/python3 /tmp/x/proxy_linear.py --servir"))
        XCTAssertFalse(ProxyDoLinear.deveSinalizar(args: "/usr/bin/python3 lanes/dispatcher.py"))
        XCTAssertFalse(ProxyDoLinear.deveSinalizar(args: "python3"))
        XCTAssertFalse(ProxyDoLinear.deveSinalizar(args: ""))
    }

    func testPararNaoSinalizaPidQueNaoEOProxy() throws {
        let home = try homeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        defer { if p.isRunning { p.terminate(); p.waitUntilExit() } }
        try plantarPid(home, p.processIdentifier)
        ServicoProxyLinear().parar(home: home)
        XCTAssertTrue(p.isRunning, "pid sem proxy_linear.py nos args não recebe SIGTERM")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProxyDoLinear.arquivoPid(home: home).path))
    }

    func testPararSinalizaOProxyEsperaEApaga() throws {
        let home = try homeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        let pasta = ProxyDoLinear.pasta(home: home)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let script = pasta.appendingPathComponent("proxy_linear.py")
        try Data("while :; do :; done\n".utf8).write(to: script)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        defer { if p.isRunning { p.terminate(); p.waitUntilExit() } }
        try plantarPid(home, p.processIdentifier)
        FileManager.default.createFile(atPath: ProxyDoLinear.socket(home: home).path, contents: Data())
        ServicoProxyLinear().parar(home: home)
        if p.isRunning == false { p.waitUntilExit() }
        XCTAssertFalse(p.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProxyDoLinear.arquivoPid(home: home).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProxyDoLinear.socket(home: home).path))
    }

    func testFalhaNaEscritaDoTokenEncerraOFilho() throws {
        let home = try homeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("dorme.sh")
        try Data("while :; do :; done\n".utf8).write(to: script)
        let tk = try tokenDeTeste("lin_api_teste")
        defer { tk.apagar() }
        let svc = ServicoProxyLinear()
        svc.binario = "/bin/sh"
        svc.escrever = { _, _ in throw CocoaError(.fileWriteUnknown) }
        svc.ligar(tokens: tk, home: home, script: script)
        let pid = svc.pidEncerradoPorFalha
        XCTAssertGreaterThan(pid, 1)
        if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "filho órfão: a falha do write tem de encerrar o processo")
    }

    func testStderrVaiParaOLogSemOToken() throws {
        let home = try homeTemp()
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("fala.sh")
        try Data("echo falha-de-bind >&2\nexec sleep 30\n".utf8).write(to: script)
        let segredo = "lin_api_nao_no_log"
        let tk = try tokenDeTeste(segredo)
        defer { tk.apagar() }
        let svc = ServicoProxyLinear()
        svc.binario = "/bin/sh"
        svc.ligar(tokens: tk, home: home, script: script)
        defer { svc.parar(home: home) }
        let url = ProxyDoLinear.logProxy(home: home)
        let limite = Date().addingTimeInterval(2)
        var log = ""
        while Date() < limite {
            log = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if log.contains("falha-de-bind") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(log.contains("falha-de-bind"))
        XCTAssertFalse(log.contains(segredo))
    }

    private func homeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pxlin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plantarPid(_ home: URL, _ pid: Int32) throws {
        let pasta = ProxyDoLinear.pasta(home: home)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: ProxyDoLinear.arquivoPid(home: home))
    }

    private func tokenDeTeste(_ segredo: String) throws -> TokenLinear {
        let cf = Cofre(servico: "com.transcentia.testes.proxy-\(UUID().uuidString)", migrarLegado: false)
        let tk = TokenLinear(cofre: cf, cofreAntigo: cf, servicoSecurity: "nao-\(UUID().uuidString)", chaveiro: ChaveiroFalso())
        try tk.salvar(segredo)
        return tk
    }
}
